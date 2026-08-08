import AppKit
import CoreGraphics
import Foundation
import PawvisCore

enum ExecutionOutcome: Equatable {
    /// Executed; `notice` is a short HUD confirmation ("Opening Safari"), nil
    /// for self-evident actions (typing, key presses).
    case done(notice: String?)
    case failed(String)
}

/// Executes parsed voice commands against the system: browser navigation,
/// key chords, app launching/switching, clicks and scrolls at the pointer.
@MainActor
final class CommandExecutor {
    private let typer = TextTyper()
    private let source = CGEventSource(stateID: .hidSystemState)

    /// Bundle ids whose address bar we can drive with ⌘L.
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "org.mozilla.firefox", "com.microsoft.edgemac", "org.chromium.Chromium",
        "company.thebrowser.Browser", "com.brave.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.kagi.kagimacOS",
    ]

    /// Spoken names that don't fuzzy-match their bundle's actual name well.
    private static let appAliases: [String: String] = [
        "chrome": "Google Chrome",
        "code": "Visual Studio Code",
        "vs code": "Visual Studio Code",
        "vscode": "Visual Studio Code",
        "settings": "System Settings",
        "preferences": "System Settings",
        "word": "Microsoft Word",
        "excel": "Microsoft Excel",
    ]

    func execute(_ command: VoiceCommand) async -> ExecutionOutcome {
        switch command {
        case .goTo(let url):
            return await goTo(url: url)
        case .webSearch(let query):
            return await webSearch(query: query)
        case .press(let chord):
            guard TextTyper.canPress(chord) else {
                return .failed("Don't know the key “\(chord.key)”")
            }
            typer.press(chord)
            return .done(notice: nil)
        case .open(let app):
            return await openApp(named: app)
        case .switchTo(let app):
            return switchToApp(named: app)
        case .click(let kind):
            click(kind)
            return .done(notice: nil)
        case .scroll(let direction, let amount):
            scroll(direction: direction, amount: amount)
            return .done(notice: nil)
        case .quit(let app):
            return quitApp(named: app)
        case .stopVoiceControl, .cancelActivity, .resolve:
            // Handled by the controller, not the executor.
            return .done(notice: nil)
        }
    }

    // MARK: - Browser navigation

    private var frontmostBrowser: NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              Self.browserBundleIDs.contains(bundleID) else { return nil }
        return app
    }

    private func goTo(url: String) async -> ExecutionOutcome {
        if frontmostBrowser != nil {
            await driveAddressBar(text: url)
            return .done(notice: "→ \(url)")
        }
        guard let full = URL(string: url.contains("://") ? url : "https://\(url)") else {
            return .failed("Couldn't form a URL from “\(url)”")
        }
        NSWorkspace.shared.open(full)
        return .done(notice: "→ \(url)")
    }

    private func webSearch(query: String) async -> ExecutionOutcome {
        if frontmostBrowser != nil {
            // The address bar searches with the user's own default engine.
            await driveAddressBar(text: query)
            return .done(notice: "Searching: \(query)")
        }
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://www.google.com/search?q=\(escaped)") else {
            return .failed("Couldn't form a search for “\(query)”")
        }
        NSWorkspace.shared.open(url)
        return .done(notice: "Searching: \(query)")
    }

    /// ⌘L (focus address bar) → type → return. Small sleeps let the browser
    /// move focus; typing immediately after ⌘L intermittently drops keys.
    private func driveAddressBar(text: String) async {
        typer.press(KeyChord(key: "l", modifiers: [.command]))
        try? await Task.sleep(for: .milliseconds(150))
        typer.type(text)
        try? await Task.sleep(for: .milliseconds(80))
        typer.press(KeyChord(key: "return"))
    }

    // MARK: - Apps

    private func openApp(named spoken: String) async -> ExecutionOutcome {
        // Already running? Just bring it forward.
        if let running = matchRunningApp(named: spoken) {
            running.activate()
            return .done(notice: "Switched to \(running.localizedName ?? spoken)")
        }
        guard let url = AppCatalog.resolve(spokenName: spoken) else {
            return .failed("No app matching “\(spoken)”")
        }
        let name = url.deletingPathExtension().lastPathComponent
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return .done(notice: "Opening \(name)")
        } catch {
            return .failed("Couldn't open \(name): \(error.localizedDescription)")
        }
    }

    private func switchToApp(named spoken: String) -> ExecutionOutcome {
        guard let app = matchRunningApp(named: spoken) else {
            return .failed("“\(spoken)” isn't running — say “open \(spoken)”")
        }
        app.activate()
        return .done(notice: "Switched to \(app.localizedName ?? spoken)")
    }

    /// Graceful termination (the app may put up its own save dialogs) — the
    /// same request Quit in its menu sends, no fronting or ⌘Q required.
    private func quitApp(named spoken: String?) -> ExecutionOutcome {
        let app: NSRunningApplication?
        if let spoken {
            app = matchRunningApp(named: spoken)
        } else {
            app = NSWorkspace.shared.frontmostApplication
        }
        guard let app, app.activationPolicy == .regular,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return .failed(spoken.map { "“\($0)” isn't running" } ?? "Nothing to quit")
        }
        let name = app.localizedName ?? spoken ?? "app"
        app.terminate()
        return .done(notice: "Quitting \(name)")
    }

    /// Waits for the frontmost app to change (an open/switch settling in)
    /// before the autopilot takes its next snapshot. Returns early on
    /// cancellation; the fixed settle tail still applies either way.
    func waitForFrontmostChange(from pid: pid_t?, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier != pid
    }

    private func matchRunningApp(named spoken: String) -> NSRunningApplication? {
        let query = AppCatalog.fold(Self.appAliases[AppCatalog.fold(spoken)] ?? spoken)
        guard !query.isEmpty else { return nil }
        let candidates = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
        var best: (app: NSRunningApplication, score: Int)?
        for app in candidates {
            guard let name = app.localizedName else { continue }
            let score = AppCatalog.matchScore(query: query, name: name)
            if score > 0, score > (best?.score ?? 0) {
                best = (app, score)
            }
        }
        return best?.app
    }

    /// Type literal text into the focused element (used by the autopilot).
    func type(_ text: String) {
        typer.type(text)
    }

    /// Click a field to focus it, then type into it. The pause matches the
    /// address-bar timing above: typing immediately after a focusing click
    /// intermittently drops the first keys.
    func type(_ text: String, into target: CGPoint) async {
        click(.left, at: target)
        try? await Task.sleep(for: .milliseconds(150))
        typer.type(text)
    }

    // MARK: - Pointer actions

    /// Mouse events posted back-to-back get dropped by the system (see
    /// MouseController); space every down/up pair.
    private func postMouse(_ type: CGEventType, button: CGMouseButton,
                           at point: CGPoint, clickState: Int64) {
        guard let event = CGEvent(
            mouseEventSource: source, mouseType: type,
            mouseCursorPosition: point, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.post(tap: .cghidEventTap)
        usleep(8000)
    }

    private func click(_ kind: ClickKind) {
        let point = CGEvent(source: nil)?.location ?? .zero
        switch kind {
        case .left:
            postMouse(.leftMouseDown, button: .left, at: point, clickState: 1)
            postMouse(.leftMouseUp, button: .left, at: point, clickState: 1)
        case .right:
            postMouse(.rightMouseDown, button: .right, at: point, clickState: 1)
            postMouse(.rightMouseUp, button: .right, at: point, clickState: 1)
        case .double:
            postMouse(.leftMouseDown, button: .left, at: point, clickState: 1)
            postMouse(.leftMouseUp, button: .left, at: point, clickState: 1)
            postMouse(.leftMouseDown, button: .left, at: point, clickState: 2)
            postMouse(.leftMouseUp, button: .left, at: point, clickState: 2)
        }
    }

    /// Click at a specific screen point (used by the visual-context resolver
    /// after locating a target element). Moves the pointer there first so the
    /// user sees where the click landed.
    func click(_ kind: ClickKind, at point: CGPoint) {
        if let move = CGEvent(
            mouseEventSource: source, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left) {
            move.post(tap: .cghidEventTap)
            usleep(30000) // let hover states settle before the click
        }
        switch kind {
        case .left:
            postMouse(.leftMouseDown, button: .left, at: point, clickState: 1)
            postMouse(.leftMouseUp, button: .left, at: point, clickState: 1)
        case .right:
            postMouse(.rightMouseDown, button: .right, at: point, clickState: 1)
            postMouse(.rightMouseUp, button: .right, at: point, clickState: 1)
        case .double:
            postMouse(.leftMouseDown, button: .left, at: point, clickState: 1)
            postMouse(.leftMouseUp, button: .left, at: point, clickState: 1)
            postMouse(.leftMouseDown, button: .left, at: point, clickState: 2)
            postMouse(.leftMouseUp, button: .left, at: point, clickState: 2)
        }
    }

    private func scroll(direction: ScrollDirection, amount: ScrollAmount) {
        let lines: Int32
        switch amount {
        case .nudge: lines = 3
        case .step: lines = 10
        case .page: lines = 40
        }
        var vertical: Int32 = 0
        var horizontal: Int32 = 0
        switch direction {
        case .up: vertical = lines
        case .down: vertical = -lines
        case .left: horizontal = lines
        case .right: horizontal = -lines
        }
        guard let event = CGEvent(
            scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
            wheel1: vertical, wheel2: horizontal, wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }
}

/// Resolves spoken app names to installed application bundles by scanning the
/// standard app directories (~16 ms; no cache needed).
enum AppCatalog {
    /// Lowercased, alphanumerics+spaces only, collapsed.
    static func fold(_ s: String) -> String {
        s.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Score a spoken query (pre-folded) against an app name. 0 = no match.
    static func matchScore(query: String, name: String) -> Int {
        let folded = fold(name)
        guard !folded.isEmpty else { return 0 }
        if folded == query { return 1000 }

        let nameTokens = folded.split(separator: " ").map(String.init)
        let queryTokens = query.split(separator: " ").map(String.init)

        // Every query token is a prefix of some name token, in order:
        // "google chrome" ~ "google chrome", "chrome" ~ "google chrome".
        var ni = 0
        var allPrefix = true
        for qt in queryTokens {
            var found = false
            while ni < nameTokens.count {
                if nameTokens[ni].hasPrefix(qt) { found = true; ni += 1; break }
                ni += 1
            }
            if !found { allPrefix = false; break }
        }
        if allPrefix {
            // Prefer tighter names ("Google Chrome" over "Chrome Remote
            // Desktop Host Uninstaller" for "chrome").
            return 500 - min(nameTokens.count - queryTokens.count, 40) * 10
        }

        // Initialism: "vs code" won't hit this, but "gc" → "Google Chrome".
        let initialism = nameTokens.compactMap(\.first).map(String.init).joined()
        if initialism == query.replacingOccurrences(of: " ", with: "") { return 300 }

        if folded.hasPrefix(query) { return 250 }
        if folded.contains(query) { return 150 }
        return 0
    }

    /// Best-matching installed app for a spoken name, boosting running apps
    /// (the running boost fixes e.g. "chrome" ranking a Chrome uninstaller
    /// above the browser).
    static func resolve(spokenName: String) -> URL? {
        let query = fold(spokenName)
        guard !query.isEmpty else { return nil }

        let runningNames = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.localizedName.map(fold) })

        var best: (url: URL, score: Int)?
        for url in installedApps() {
            let name = url.deletingPathExtension().lastPathComponent
            var score = matchScore(query: query, name: name)
            guard score > 0 else { continue }
            if runningNames.contains(fold(name)) { score += 250 }
            if score > (best?.score ?? 0) {
                best = (url, score)
            }
        }
        return best?.url
    }

    private static func installedApps() -> [URL] {
        let roots = [
            "/Applications", "/System/Applications", "/System/Applications/Utilities",
            NSString("~/Applications").expandingTildeInPath,
        ]
        let fm = FileManager.default
        var apps: [URL] = []
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles) else { continue }
            for entry in entries {
                if entry.pathExtension == "app" {
                    apps.append(entry)
                } else if entry.hasDirectoryPath {
                    // One subfolder level (e.g. /Applications/Utilities).
                    let sub = (try? fm.contentsOfDirectory(
                        at: entry, includingPropertiesForKeys: nil,
                        options: .skipsHiddenFiles)) ?? []
                    apps.append(contentsOf: sub.filter { $0.pathExtension == "app" })
                }
            }
        }
        return apps
    }
}
