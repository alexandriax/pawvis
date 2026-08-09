import AppKit
import ApplicationServices
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

    /// Apple-Intelligence rescue for spoken app names nothing installed
    /// matches (Settings → Voice's visual-context switch gates on-device AI).
    var aiAppNameRescueEnabled = false

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
        case .goTo(let url, let app):
            return await goTo(url: url, app: app)
        case .webSearch(let query, let app):
            return await webSearch(query: query, app: app)
        case .press(let chord):
            guard TextTyper.canPress(chord) else {
                return .failed("Don't know the key “\(chord.key)”")
            }
            typer.press(chord)
            return .done(notice: nil)
        case .open(let app):
            return await openApp(named: app)
        case .switchTo(let app):
            return await switchToApp(named: app)
        case .click(let kind):
            click(kind)
            return .done(notice: nil)
        case .scroll(let direction, let amount):
            scroll(direction: direction, amount: amount)
            return .done(notice: nil)
        case .quit(let app):
            return quitApp(named: app)
        case .mediaKey(let key):
            typer.press(key)
            return .done(notice: nil)
        case .stopVoiceControl, .cancelActivity, .resolve, .sequence:
            // Handled by the controller, not the executor.
            return .done(notice: nil)
        }
    }

    /// Between sequence steps: let the step's effect land, and for app
    /// switches verify focus actually moved — a sequence must never run its
    /// next step against the wrong app. Returns nil when settled, or the
    /// reason the step didn't take.
    func sequenceSettle(after command: VoiceCommand) async -> String? {
        switch command {
        case .open(let app), .switchTo(let app):
            if await waitForFrontmost(appNamed: app, timeout: 3.0) {
                try? await Task.sleep(for: .milliseconds(300))
                return nil
            }
            return "\(app) never came to the front"
        case .goTo, .webSearch:
            try? await Task.sleep(for: .milliseconds(600))
            return nil
        case .press, .mediaKey, .quit:
            try? await Task.sleep(for: .milliseconds(300))
            return nil
        case .click, .scroll:
            try? await Task.sleep(for: .milliseconds(250))
            return nil
        case .stopVoiceControl, .cancelActivity, .resolve, .sequence:
            return nil
        }
    }

    // MARK: - Browser navigation

    private var frontmostBrowser: NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              Self.browserBundleIDs.contains(bundleID) else { return nil }
        return app
    }

    /// Navigate to a URL. With no app named: the frontmost browser's address
    /// bar, else the default browser. With one ("open discord dot com in
    /// Chrome"): hand the URL straight to that app with NSWorkspace — the
    /// system opens a tab whether or not the app is already running, no GUI
    /// driving involved — and fall back to the default browser, saying so,
    /// rather than failing the navigation over the app name.
    private func goTo(url: String, app spokenApp: String?) async -> ExecutionOutcome {
        guard let full = URL(string: url.contains("://") ? url : "https://\(url)") else {
            return .failed("Couldn't form a URL from “\(url)”")
        }
        if let spokenApp {
            guard let appURL = AppCatalog.resolve(spokenName: Self.canonicalName(for: spokenApp)) else {
                NSWorkspace.shared.open(full)
                return .done(notice: "→ \(url) — no app “\(spokenApp)”, used the default browser")
            }
            let name = appURL.deletingPathExtension().lastPathComponent
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                _ = try await NSWorkspace.shared.open(
                    [full], withApplicationAt: appURL, configuration: configuration)
                // Postcondition, not a hope: the app the user named comes to
                // the front, or the notice would be a lie.
                _ = await waitForFrontmost(appNamed: name, timeout: 3.0)
                return .done(notice: "→ \(url) in \(name)")
            } catch {
                NSWorkspace.shared.open(full)
                return .done(notice: "→ \(url) — \(name) refused it, used the default browser")
            }
        }
        if frontmostBrowser != nil {
            if await driveAddressBar(text: url) {
                return .done(notice: "→ \(url)")
            }
            // The address bar never verifiably held the text — open the URL
            // through the system instead of pressing Return on faith.
            NSWorkspace.shared.open(full)
            return .done(notice: "→ \(url) (address bar balked — opened via the system)")
        }
        NSWorkspace.shared.open(full)
        return .done(notice: "→ \(url)")
    }

    private func webSearch(query: String, app spokenApp: String?) async -> ExecutionOutcome {
        // A named browser gets fronted first, then its address bar does the
        // searching — the omnibox treats "discord" exactly the way the user's
        // own typing would (autocomplete or search). If the named app never
        // comes up as a drivable browser, fall through to the default path.
        if let spokenApp {
            if case .done = await openApp(named: spokenApp) {
                _ = await waitForFrontmost(appNamed: spokenApp, timeout: 3.0)
                try? await Task.sleep(for: .milliseconds(250))
                if frontmostBrowser != nil, await driveAddressBar(text: query) {
                    return .done(notice: "Searching: \(query)")
                }
            }
        }
        if frontmostBrowser != nil, await driveAddressBar(text: query) {
            // The address bar searches with the user's own default engine.
            return .done(notice: "Searching: \(query)")
        }
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://www.google.com/search?q=\(escaped)") else {
            return .failed("Couldn't form a search for “\(query)”")
        }
        NSWorkspace.shared.open(url)
        return .done(notice: "Searching: \(query)")
    }

    /// ⌘L (focus address bar) → type → VERIFY → return. Return is gated on
    /// the focused field verifiably holding what was typed (read back over
    /// accessibility), because a Return pressed into an unknown field state
    /// navigates to whatever is there — the "went to the URL I already had"
    /// failure. One reselect-and-retype retry; then fail honestly rather
    /// than press Return on faith. Returns false when the text never
    /// verifiably landed.
    private func driveAddressBar(text: String) async -> Bool {
        typer.press(KeyChord(key: "l", modifiers: [.command]))
        // The browser may still be becoming key after an activation — wait
        // for an editable focused field before typing at it.
        guard await waitForFocusedEditableField(timeout: 1.5) else { return false }
        for _ in 0..<2 {
            typer.type(text)
            try? await Task.sleep(for: .milliseconds(150))
            // Inline autocomplete extends typed text with a selected
            // completion ("youtube.com" → the user's most-visited channel);
            // Return would navigate to the completion, not the command.
            // Forward-delete removes a selected completion and is a no-op at
            // end-of-text, so it's always safe here.
            if let value = focusedFieldValue(),
               value.lowercased() != text.lowercased(),
               value.lowercased().hasPrefix(text.lowercased()) {
                typer.press(KeyChord(key: "forwarddelete"))
                try? await Task.sleep(for: .milliseconds(80))
            }
            if focusedFieldHolds(text) {
                typer.press(KeyChord(key: "return"))
                return true
            }
            // Reselect the address bar (⌘L selects-all, so retyping
            // replaces whatever half-state the last attempt left).
            typer.press(KeyChord(key: "l", modifiers: [.command]))
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    // MARK: - Focused-field verification (accessibility)

    private func focusedElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else {
            return nil
        }
        return (element as! AXUIElement)
    }

    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String, kAXTextAreaRole as String,
        kAXComboBoxRole as String, "AXSearchField",
    ]

    private func waitForFocusedEditableField(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = focusedElement() {
                var role: CFTypeRef?
                if AXUIElementCopyAttributeValue(
                    element, kAXRoleAttribute as CFString, &role) == .success,
                   let roleName = role as? String,
                   Self.editableRoles.contains(roleName) {
                    return true
                }
            }
            try? await Task.sleep(for: .milliseconds(80))
        } while Date() < deadline && !Task.isCancelled
        return false
    }

    private func focusedFieldValue() -> String? {
        guard let element = focusedElement() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value) == .success,
            let string = value as? String else { return nil }
        return string
    }

    /// True when the focused field's value starts with the typed text —
    /// prefix, not equality, because browser omniboxes extend what you type
    /// with inline autocompletion (removed before Return, see above, but a
    /// completion that survives the forward-delete must not fail the drive).
    private func focusedFieldHolds(_ typed: String) -> Bool {
        guard let string = focusedFieldValue() else { return false }
        return string.lowercased().hasPrefix(typed.lowercased())
    }

    // MARK: - Apps

    /// Focus is the contract, not a hope: "open X" means X ends up frontmost
    /// (the effect of ⌘Space + typing the name + return, via the same system
    /// call Spotlight uses). A running app gets activate-and-verify; if it
    /// won't front that way, relaunching through NSWorkspace fronts it more
    /// forcefully. Every path verifies before claiming success.
    private func openApp(named spoken: String) async -> ExecutionOutcome {
        if let running = matchRunningApp(named: spoken) {
            let name = running.localizedName ?? spoken
            running.activate()
            if await waitForFrontmost(appNamed: name, timeout: 1.5) {
                return .done(notice: "Switched to \(name)")
            }
            // Fall through: openApplication on a running app re-activates it
            // through the workspace, which succeeds where activate() is
            // ignored (e.g. the app was busy or activation was contested).
        }
        guard let url = AppCatalog.resolve(spokenName: spoken) else {
            return await openAppViaAIRescue(spoken: spoken)
        }
        return await launch(appAt: url)
    }

    /// Nothing installed matches, even phonetically — one Apple Intelligence
    /// round picks the sound-alike from a short, deterministically ranked
    /// list of real installed names ("clawed ai" → Claude). The pick is only
    /// acted on when it names a listed app verbatim, and the notice says
    /// what was heard so a wrong rescue is explainable, not spooky.
    private func openAppViaAIRescue(spoken: String) async -> ExecutionOutcome {
        let failure = ExecutionOutcome.failed("No app matching “\(spoken)”")
        guard aiAppNameRescueEnabled, #available(macOS 26.0, *),
              AppNameRescuer.isSupported else { return failure }
        let installed = AppCatalog.installedAppNames()
        guard let picked = try? await AppNameRescuer.resolve(
                  spoken: spoken, amongInstalled: installed),
              let url = AppCatalog.resolve(spokenName: picked) else {
            Log.voice.log("App-name rescue found nothing for: \(spoken, privacy: .private)")
            return failure
        }
        Log.voice.log("App-name rescue: \(spoken, privacy: .private) → \(picked, privacy: .public)")
        return await launch(appAt: url, heard: spoken)
    }

    private func launch(appAt url: URL, heard: String? = nil) async -> ExecutionOutcome {
        let name = url.deletingPathExtension().lastPathComponent
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            if !(await waitForFrontmost(appNamed: name, timeout: 3.0)) {
                app.activate()
                _ = await waitForFrontmost(appNamed: name, timeout: 1.5)
            }
            return .done(notice: heard.map { "Opening \(name) — heard “\($0)”" }
                ?? "Opening \(name)")
        } catch {
            return .failed("Couldn't open \(name): \(error.localizedDescription)")
        }
    }

    private func switchToApp(named spoken: String) async -> ExecutionOutcome {
        guard let app = matchRunningApp(named: spoken) else {
            return .failed("“\(spoken)” isn't running — say “open \(spoken)”")
        }
        let name = app.localizedName ?? spoken
        app.activate()
        if await waitForFrontmost(appNamed: name, timeout: 1.5) {
            return .done(notice: "Switched to \(name)")
        }
        // Once more — apps mid-launch or mid-dialog ignore the first ask.
        app.activate()
        if await waitForFrontmost(appNamed: name, timeout: 1.5) {
            return .done(notice: "Switched to \(name)")
        }
        return .failed("Couldn't bring \(name) to the front")
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

    /// Waits until the frontmost app plausibly IS the named one — the
    /// postcondition behind "opened X" claims. Fuzzy on the same rules as
    /// resolution, so "chrome" satisfies "Google Chrome".
    func waitForFrontmost(appNamed spoken: String, timeout: TimeInterval) async -> Bool {
        let target = Self.canonicalName(for: spoken)
        func satisfied() -> Bool {
            guard let name = NSWorkspace.shared.frontmostApplication?.localizedName else {
                return false
            }
            return AppNameMatch.matches(spoken: target, appName: name)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            if satisfied() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return satisfied()
    }

    /// Whether the frontmost app is a browser we know how to drive — also
    /// the autopilot's completion check for goToURL/webSearch steps.
    var frontmostIsBrowser: Bool { frontmostBrowser != nil }

    /// The frontmost app's display name (autopilot completion checks).
    var frontmostAppName: String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    /// Spoken names that don't fuzzy-match their bundle's actual name pass
    /// through the alias table first.
    private static func canonicalName(for spoken: String) -> String {
        Self.appAliases[AppCatalog.fold(spoken)] ?? spoken
    }

    private func matchRunningApp(named spoken: String) -> NSRunningApplication? {
        let target = Self.canonicalName(for: spoken)
        guard !AppCatalog.fold(target).isEmpty else { return nil }
        let candidates = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
        var best: (app: NSRunningApplication, score: Int)?
        for app in candidates {
            guard let name = app.localizedName else { continue }
            let score = AppNameMatch.bestScore(spoken: target, name: name)
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
/// standard app directories (~16 ms; no cache needed). Scoring lives in
/// PawvisCore's `AppNameMatch` so the autopilot's completion checks share the
/// exact rules that resolution uses.
enum AppCatalog {
    /// Lowercased, alphanumerics+spaces only, collapsed.
    static func fold(_ s: String) -> String {
        AppNameMatch.fold(s)
    }

    /// Score a spoken query (pre-folded) against an app name. 0 = no match.
    static func matchScore(query: String, name: String) -> Int {
        AppNameMatch.matchScore(query: query, name: name)
    }

    /// Best-matching installed app for a spoken name, boosting running apps
    /// (the running boost fixes e.g. "chrome" ranking a Chrome uninstaller
    /// above the browser).
    static func resolve(spokenName: String) -> URL? {
        guard !fold(spokenName).isEmpty else { return nil }

        let runningNames = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.localizedName.map(fold) })

        var best: (url: URL, score: Int)?
        for url in installedApps() {
            let name = url.deletingPathExtension().lastPathComponent
            var score = AppNameMatch.bestScore(spoken: spokenName, name: name)
            guard score > 0 else { continue }
            if runningNames.contains(fold(name)) { score += 250 }
            if score > (best?.score ?? 0) {
                best = (url, score)
            }
        }
        return best?.url
    }

    /// Display names of every installed app (the AI name-rescue's candidate
    /// pool), deduped and sorted for deterministic prompts.
    static func installedAppNames() -> [String] {
        Array(Set(installedApps().map { $0.deletingPathExtension().lastPathComponent }))
            .sorted()
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
