import Foundation

/// What the on-device model translated a free-form utterance into: one
/// primitive machine intent, or the admission that the screen is needed.
/// Plain mirror of the app layer's @Generable schema, same pattern as
/// `AutopilotStep` (FoundationModels never reaches PawvisCore).
public enum TranslatedIntent: String, CaseIterable, Equatable, Sendable {
    case openApp, switchToApp, goToURL, webSearch, pressKey, quitApp
    /// The command refers to what's on screen, or needs several actions —
    /// hand it to the visual autopilot loop.
    case needsScreen
}

public struct IntentTranslation: Equatable, Sendable {
    public var intent: TranslatedIntent
    public var argument: String?
    /// App the intent should act in, when one was spoken ("in Chrome").
    public var app: String?

    public init(intent: TranslatedIntent, argument: String? = nil, app: String? = nil) {
        self.intent = intent
        self.argument = argument
        self.app = app
    }
}

/// The translation stage's pure rules: the prompt, and the compilation of a
/// translation into an executable `VoiceCommand`. The stage exists because
/// the on-device model is small: it is reliable at translating one sentence
/// into one constrained intent, and unreliable at sequencing GUI actions —
/// so every free-form command gets one cheap, screen-free translation
/// attempt before the visual loop is allowed anywhere near it.
public enum TranslationPolicy {
    /// Instructions for the translation session. Kept deliberately short and
    /// example-led — this is a ~3B model with a 4096-token window.
    public static let instructions = """
        You translate one spoken macOS voice command into a single machine \
        intent. You cannot see the screen.

        Intents:
        - openApp: launch or show an application. argument = the app's name.
        - switchToApp: bring an already-open application forward. argument = \
        the app's name.
        - goToURL: visit a website. argument = the address as a real URL. \
        Spoken URLs arrive as words: "discord dot com" → "discord.com"; \
        "github dot com slash anthropics" → "github.com/anthropics"; \
        "localhost colon three thousand" → "localhost:3000". Never invent \
        parts that were not spoken.
        - webSearch: search the web. argument = the words to search for.
        - pressKey: press one key or shortcut. argument = its spoken name \
        ("return", "escape", "command shift t").
        - quitApp: quit an application. argument = its name; omit it for \
        "quit this app".
        - needsScreen: anything else. The command talks about what is on \
        the screen (click, choose, select, fill, move, resize, scroll, \
        tabs, menus, windows, buttons), or needs more than one action, or \
        fits no intent above.

        If an app to act in is named ("in Chrome", "with Safari"), set app \
        to that name and leave it out of the argument.
        When unsure, answer needsScreen.
        """

    /// The per-command prompt. The instructions carry the rules; the prompt
    /// is just the utterance.
    public static func prompt(for goal: String) -> String {
        "Command: “\(goal)”"
    }

    /// App qualifiers that name "the web", not an app. The small model
    /// regularly emits these (measured live: app "web" on plain search
    /// requests); they mean "wherever the default browser is" — nil.
    private static let genericWebQualifiers: Set<String> = [
        "web", "the web", "internet", "the internet", "online",
        "browser", "the browser", "my browser", "a browser",
        "default browser", "the default browser",
    ]

    /// Intent names, folded — the model occasionally bleeds the schema into
    /// an argument (measured live: quitApp with argument "needsScreen").
    /// Such an argument is noise, never a real target.
    private static let intentNames = Set(
        TranslatedIntent.allCases.map { $0.rawValue.lowercased() })

    /// Placeholder words the model emits when a command has no explicit
    /// target (measured live: quitApp with argument "unknown" for "get rid
    /// of this app"). They mean "no specific target" — for quitApp that is
    /// the frontmost app, the same reading the grammar gives "quit it".
    private static let placeholderArguments: Set<String> = [
        "unknown", "none", "nil", "null", "na", "not specified", "unspecified",
        "it", "this", "that", "current",
        "this app", "that app", "the app", "this one",
        "current app", "the current app", "frontmost app", "the frontmost app",
    ]

    /// Compile a translation into an executable command — nil when the
    /// translation is unusable (empty argument, unparseable key or URL), in
    /// which case the visual loop is the honest next step. Arguments are
    /// checked with the same parsers that will execute them, so a compiled
    /// command can't fail on decode.
    public static func command(from translation: IntentTranslation) -> VoiceCommand? {
        var argument = translation.argument?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if intentNames.contains(argument.lowercased())
            || placeholderArguments.contains(VoiceControlParser.normalize(argument)) {
            argument = ""
        }
        let app = translation.app?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var qualifier = (app?.isEmpty ?? true) ? nil : app
        if let named = qualifier,
           genericWebQualifiers.contains(VoiceControlParser.normalize(named))
            || intentNames.contains(named.lowercased())
            || placeholderArguments.contains(VoiceControlParser.normalize(named)) {
            qualifier = nil
        }

        switch translation.intent {
        case .openApp:
            guard !argument.isEmpty else { return nil }
            return .open(app: argument)
        case .switchToApp:
            guard !argument.isEmpty else { return nil }
            return .switchTo(app: argument)
        case .goToURL:
            guard let url = SpokenURLNormalizer.normalize(argument)
                ?? (argument.contains(".") ? argument : nil) else { return nil }
            return .goTo(url: url, app: qualifier)
        case .webSearch:
            guard !argument.isEmpty else { return nil }
            return .webSearch(query: argument, app: qualifier)
        case .pressKey:
            let tokens = argument.lowercased().split(separator: " ").map(String.init)
            guard let chord = SpokenKeyParser.chord(from: tokens) else { return nil }
            return .press(chord)
        case .quitApp:
            return .quit(app: argument.isEmpty ? nil : argument)
        case .needsScreen:
            return nil
        }
    }
}
