import Foundation

/// What a bound custom gesture does when it fires. Pure description — the app
/// layer (`GestureActionRunner`) performs it. A flat kind plus one string
/// argument keeps the whole thing trivially Codable and lets the pickers stay
/// dumb; the categories below exist only to group the picker's menu.
public struct GestureAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        // Desktops & Mission Control — posted as the stock macOS shortcuts.
        case desktopLeft, desktopRight, missionControl, appWindows, showDesktop

        // Window management — the focused window, moved and sized directly
        // through the Accessibility API.
        case windowLeftHalf, windowRightHalf, windowTopHalf, windowBottomHalf
        case windowLeftTwoThirds, windowRightTwoThirds
        case windowLeftThird, windowRightThird
        case windowTopLeftQuarter, windowTopRightQuarter
        case windowBottomLeftQuarter, windowBottomRightQuarter
        case windowMaximize, windowCenter, windowMinimize, windowNextDisplay

        // Navigation & media — key chords (and the hardware play/pause key)
        // sent to the frontmost app.
        case pressReturn, pressEscape
        case browserBack, browserForward
        case previousTab, nextTab
        case playPause

        // Pawvis itself.
        case stopTracking, toggleVoiceControl

        // Custom — the argument carries the app name, the shell command, or
        // the shortcut to press.
        case openApp, runShellCommand, keyboardShortcut
    }

    public var kind: Kind
    /// App name for `openApp`, command line for `runShellCommand`, chord text
    /// ("cmd+shift+t", "⌘⇧T") for `keyboardShortcut`; empty otherwise.
    public var argument: String

    public init(kind: Kind, argument: String = "") {
        self.kind = kind
        self.argument = argument
    }

    enum CodingKeys: String, CodingKey {
        case kind, argument
    }

    /// `kind` decodes strictly on purpose: a binding saved by a newer Pawvis
    /// with an action this build doesn't know is dropped by the settings
    /// decoder's lossy list rather than misread. Only `argument` is tolerant.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        argument = (try? c.decodeIfPresent(String.self, forKey: .argument)) ?? ""
    }

    // MARK: - Picker grouping

    public enum Category: String, CaseIterable, Sendable {
        case desktops, window, navigation, pawvis, custom

        public var displayName: String {
            switch self {
            case .desktops: return "Desktops & Mission Control"
            case .window: return "Window"
            case .navigation: return "Navigate & media"
            case .pawvis: return "Pawvis"
            case .custom: return "Custom"
            }
        }
    }

    public var category: Category { kind.category }

    // MARK: - Key chords

    /// The chord this action presses, when it is a key action. Mission
    /// Control's own shortcuts and the near-universal app conventions. nil
    /// for everything performed another way — including the desktop switch,
    /// which macOS refuses to perform for synthetic ⌃←/⌃→ (the app drives
    /// Mission Control's spaces bar instead; see `SpaceSwitcher`).
    public var keyChord: KeyChord? {
        switch kind {
        case .missionControl: return KeyChord(key: "up", modifiers: [.control])
        case .appWindows: return KeyChord(key: "down", modifiers: [.control])
        case .showDesktop: return KeyChord(key: "f11", modifiers: [])
        case .pressReturn: return KeyChord(key: "return", modifiers: [])
        case .pressEscape: return KeyChord(key: "escape", modifiers: [])
        case .browserBack: return KeyChord(key: "[", modifiers: [.command])
        case .browserForward: return KeyChord(key: "]", modifiers: [.command])
        case .previousTab: return KeyChord(key: "tab", modifiers: [.control, .shift])
        case .nextTab: return KeyChord(key: "tab", modifiers: [.control])
        case .keyboardShortcut: return ShortcutParser.chord(from: argument)
        default: return nil
        }
    }

    // MARK: - Display

    /// Whether this kind is meaningless without its argument filled in.
    public var needsArgument: Bool { kind.needsArgument }

    public var displayName: String { kind.displayName }

    /// The label the picker and the guide show: the kind, plus the argument
    /// when there is one ("Open app: Safari").
    public var summary: String {
        guard kind.needsArgument else { return kind.displayName }
        let trimmed = argument.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return kind.displayName }
        return "\(kind.displayName): \(trimmed)"
    }

    /// The short line the status pill flashes when the gesture fires.
    public var feedback: String {
        switch kind {
        case .desktopLeft: return "Desktop left"
        case .desktopRight: return "Desktop right"
        case .missionControl: return "Mission Control"
        case .appWindows: return "App windows"
        case .showDesktop: return "Show desktop"
        case .windowLeftHalf: return "Window → left half"
        case .windowRightHalf: return "Window → right half"
        case .windowTopHalf: return "Window → top half"
        case .windowBottomHalf: return "Window → bottom half"
        case .windowLeftTwoThirds: return "Window → left two thirds"
        case .windowRightTwoThirds: return "Window → right two thirds"
        case .windowLeftThird: return "Window → left third"
        case .windowRightThird: return "Window → right third"
        case .windowTopLeftQuarter: return "Window → top left"
        case .windowTopRightQuarter: return "Window → top right"
        case .windowBottomLeftQuarter: return "Window → bottom left"
        case .windowBottomRightQuarter: return "Window → bottom right"
        case .windowMaximize: return "Window → full screen size"
        case .windowCenter: return "Window centered"
        case .windowMinimize: return "Window minimized"
        case .windowNextDisplay: return "Window → next display"
        case .pressReturn: return "Pressed Return"
        case .pressEscape: return "Pressed Escape"
        case .browserBack: return "Back"
        case .browserForward: return "Forward"
        case .previousTab: return "Previous tab"
        case .nextTab: return "Next tab"
        case .playPause: return "Play / pause"
        case .stopTracking: return "Tracking stopped"
        case .toggleVoiceControl: return "Voice control toggled"
        case .openApp: return "Opening \(argument.trimmingCharacters(in: .whitespaces))"
        case .runShellCommand: return "Running command"
        case .keyboardShortcut:
            if let chord = keyChord { return "Pressed \(ShortcutParser.display(chord))" }
            return "Shortcut not understood"
        }
    }
}

extension GestureAction.Kind {
    public var category: GestureAction.Category {
        switch self {
        case .desktopLeft, .desktopRight, .missionControl, .appWindows, .showDesktop:
            return .desktops
        case .windowLeftHalf, .windowRightHalf, .windowTopHalf, .windowBottomHalf,
             .windowLeftTwoThirds, .windowRightTwoThirds, .windowLeftThird, .windowRightThird,
             .windowTopLeftQuarter, .windowTopRightQuarter,
             .windowBottomLeftQuarter, .windowBottomRightQuarter,
             .windowMaximize, .windowCenter, .windowMinimize, .windowNextDisplay:
            return .window
        case .pressReturn, .pressEscape, .browserBack, .browserForward,
             .previousTab, .nextTab, .playPause:
            return .navigation
        case .stopTracking, .toggleVoiceControl:
            return .pawvis
        case .openApp, .runShellCommand, .keyboardShortcut:
            return .custom
        }
    }

    public var needsArgument: Bool {
        switch self {
        case .openApp, .runShellCommand, .keyboardShortcut: return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .desktopLeft: return "Desktop to the left"
        case .desktopRight: return "Desktop to the right"
        case .missionControl: return "Mission Control"
        case .appWindows: return "App windows (Exposé)"
        case .showDesktop: return "Show desktop"
        case .windowLeftHalf: return "Window: left half"
        case .windowRightHalf: return "Window: right half"
        case .windowTopHalf: return "Window: top half"
        case .windowBottomHalf: return "Window: bottom half"
        case .windowLeftTwoThirds: return "Window: left two thirds"
        case .windowRightTwoThirds: return "Window: right two thirds"
        case .windowLeftThird: return "Window: left third"
        case .windowRightThird: return "Window: right third"
        case .windowTopLeftQuarter: return "Window: top-left quarter"
        case .windowTopRightQuarter: return "Window: top-right quarter"
        case .windowBottomLeftQuarter: return "Window: bottom-left quarter"
        case .windowBottomRightQuarter: return "Window: bottom-right quarter"
        case .windowMaximize: return "Window: fill the screen"
        case .windowCenter: return "Window: center it"
        case .windowMinimize: return "Window: minimize"
        case .windowNextDisplay: return "Window: next display"
        case .pressReturn: return "Press Return (confirm)"
        case .pressEscape: return "Press Escape (dismiss)"
        case .browserBack: return "Back (⌘[)"
        case .browserForward: return "Forward (⌘])"
        case .previousTab: return "Previous tab"
        case .nextTab: return "Next tab"
        case .playPause: return "Play / pause media"
        case .stopTracking: return "Stop hand tracking"
        case .toggleVoiceControl: return "Start / stop voice control"
        case .openApp: return "Open app"
        case .runShellCommand: return "Run shell command"
        case .keyboardShortcut: return "Press keyboard shortcut"
        }
    }
}
