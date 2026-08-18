import Foundation

/// A keyboard shortcut the parser understood: a canonical key name plus
/// modifiers. The app layer maps names to virtual key codes.
public struct KeyChord: Equatable, Hashable, Sendable {
    public enum Modifier: String, CaseIterable, Equatable, Hashable, Sendable {
        case command, shift, option, control, function
    }

    /// Canonical lowercase key name: "return", "tab", "space", "escape",
    /// "delete", "forwarddelete", "home", "end", "pageup", "pagedown",
    /// "left"/"right"/"up"/"down", "a"…"z", "0"…"9", "f1"…"f12".
    public var key: String
    public var modifiers: Set<Modifier>

    public init(key: String, modifiers: Set<Modifier> = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// What the app-layer text typist should do, in order.
public enum TypingAction: Equatable, Sendable {
    case type(String)
    /// Delete this many characters (used to reconcile streamed deltas against
    /// the final transcript, and to un-type text that turned out to be a
    /// command or stop phrase).
    case backspace(Int)
    case key(KeyChord)
}

public enum ClickKind: String, Equatable, Sendable {
    case left, right, double
}

public enum ScrollDirection: String, Equatable, Sendable {
    case up, down, left, right
}

public enum ScrollAmount: String, Equatable, Sendable {
    case nudge, step, page
}

/// Hardware media keys, delivered as systemDefined NSEvents rather than
/// regular key codes. `playPause` is routed by macOS to whatever's playing;
/// the volume and brightness keys act on the system directly (macOS shows
/// its own HUD) and need no "now playing" app at all.
public enum MediaKey: String, Equatable, Sendable {
    case playPause
    case volumeUp, volumeDown, volumeMute
    case brightnessUp, brightnessDown
}

/// A machine-control command parsed from a wake-word utterance. Typing is not
/// a command — the parser handles it as a mode (see `VoiceControlParser`).
public enum VoiceCommand: Equatable, Sendable {
    /// Press a hardware media key ("pause", "play") — macOS routes it to
    /// whatever is playing, which is exactly what the speaker means.
    case mediaKey(MediaKey)
    /// Deterministic composite ("open chrome and go to youtube dot com"):
    /// every clause parsed on its own, so the whole thing executes
    /// sequentially with focus verified between steps — no model involved.
    /// Only ever produced with 2+ non-control member commands, never nested.
    case sequence([VoiceCommand])
    /// Navigate to a URL — in the named app when one was spoken ("open
    /// discord dot com in Chrome"), else the frontmost browser, else the
    /// default one.
    case goTo(url: String, app: String?)
    /// Search the web for a phrase ("go to" targets that aren't URL-shaped) —
    /// in the named browser when one was spoken.
    case webSearch(query: String, app: String?)
    case press(KeyChord)
    case open(app: String)
    case switchTo(app: String)
    /// Click at the current pointer position.
    case click(ClickKind)
    case scroll(direction: ScrollDirection, amount: ScrollAmount)
    /// Quit an app gracefully; nil quits the frontmost one.
    case quit(app: String?)
    /// Turn voice control off ("Pawvis stop listening").
    case stopVoiceControl
    /// Cancel whatever is in flight ("Pawvis stop" / "cancel"). With nothing
    /// running, the controller treats it as `stopVoiceControl` — bare "stop"
    /// keeps its original meaning when there's nothing to cancel.
    case cancelActivity
    /// Not matched by the deterministic grammar — resolve against on-screen
    /// context with the on-device model ("Pawvis click sign in").
    case resolve(transcript: String)
}

// MARK: - Spoken key chords

/// Parses spoken key names ("press command shift T", "hit enter") into
/// `KeyChord`s. Input is pre-normalized tokens (lowercased, punctuation
/// stripped).
public enum SpokenKeyParser {
    private static let modifierNames: [String: KeyChord.Modifier] = [
        "command": .command, "cmd": .command, "apple": .command,
        "shift": .shift,
        "option": .option, "alt": .option,
        "control": .control, "ctrl": .control,
        "function": .function, "fn": .function,
    ]

    private static let namedKeys: [String: String] = [
        "return": "return", "enter": "return",
        "tab": "tab",
        "space": "space", "spacebar": "space",
        "escape": "escape", "esc": "escape",
        "delete": "delete", "backspace": "delete",
        "home": "home", "end": "end",
        "up": "up", "down": "down", "left": "left", "right": "right",
    ]

    private static let spelledDigits: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    ]

    /// Filler words that may appear around key names ("press the enter key").
    private static let filler: Set<String> = ["the", "key", "button"]

    public static func chord(from tokens: [String]) -> KeyChord? {
        var modifiers: Set<KeyChord.Modifier> = []
        var keyTokens: [String] = []

        for token in tokens {
            if keyTokens.isEmpty, let modifier = modifierNames[token] {
                modifiers.insert(modifier)
            } else if filler.contains(token) {
                continue
            } else {
                keyTokens.append(token)
            }
        }

        guard let key = keyName(from: keyTokens) else { return nil }
        return KeyChord(key: key, modifiers: modifiers)
    }

    private static func keyName(from tokens: [String]) -> String? {
        switch tokens.count {
        case 1:
            let t = tokens[0]
            if let named = namedKeys[t] { return named }
            if let digit = spelledDigits[t] { return digit }
            if t.count == 1, let scalar = t.unicodeScalars.first,
               CharacterSet.lowercaseLetters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                return t
            }
            // "f5", "f12"
            if t.hasPrefix("f"), t.count <= 3, let n = Int(t.dropFirst()), (1...12).contains(n) {
                return t
            }
            return nil
        case 2:
            switch (tokens[0], tokens[1]) {
            case ("page", "up"): return "pageup"
            case ("page", "down"): return "pagedown"
            case ("forward", "delete"): return "forwarddelete"
            // "up arrow" / "arrow up"
            case (let d, "arrow") where namedKeys[d] != nil: return namedKeys[d]
            case ("arrow", let d) where namedKeys[d] != nil: return namedKeys[d]
            // "f five"
            case ("f", let n) where spelledDigits[n] != nil || Int(n) != nil:
                let digit = spelledDigits[n] ?? n
                if let value = Int(digit), (1...12).contains(value) { return "f\(digit)" }
                return nil
            default: return nil
            }
        default:
            return nil
        }
    }
}

// MARK: - Spoken URLs

/// Turns a spoken web address into a URL string: "here's alexandria dot com
/// slash blog" → "heresalexandria.com/blog". Returns nil when the result
/// isn't URL-shaped (no dot, no scheme) — those are better treated as web
/// searches.
public enum SpokenURLNormalizer {
    private static let tokenReplacements: [String: String] = [
        "dot": ".", "period": ".", "point": ".",
        "slash": "/", "backslash": "/",
        "dash": "-", "hyphen": "-", "minus": "-",
        "underscore": "_",
        "colon": ":",
        "tilde": "~",
        "plus": "+",
        "hash": "#", "pound": "#",
        "ampersand": "&",
        "percent": "%",
        "at": "@",
    ]

    /// Characters that may appear in the assembled URL; everything else is
    /// dropped (apostrophes, commas, trailing sentence punctuation…).
    private static let urlCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_/:~?=&+#%@")

    /// True when the token is spoken URL punctuation ("dot", "slash"…) —
    /// used by the parser to tell "linked in dot com" (the "in" is inside
    /// the domain) from "discord dot com in chrome" (the "in" introduces an
    /// app qualifier).
    public static func isConnectorToken(_ token: String) -> Bool {
        tokenReplacements[token] != nil
    }

    public static func normalize(_ spoken: String) -> String? {
        var pieces: [String] = []
        for rawToken in spoken.lowercased().split(whereSeparator: { $0.isWhitespace }) {
            let token = String(rawToken)
            if let replacement = tokenReplacements[token] {
                pieces.append(replacement)
                continue
            }
            let filtered = String(token.unicodeScalars.filter { urlCharacters.contains($0) })
            if !filtered.isEmpty {
                pieces.append(filtered)
            }
        }

        var joined = pieces.joined()
        // Strip sentence-ending punctuation the recognizer may have added.
        while let last = joined.last, ".,;:!?".contains(last) {
            joined.removeLast()
        }
        guard !joined.isEmpty else { return nil }

        let isURLShaped = joined.contains("://")
            || joined.hasPrefix("localhost")
            || joined.contains(".")
        return isURLShaped ? joined : nil
    }
}
