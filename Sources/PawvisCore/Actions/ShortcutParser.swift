import Foundation

/// Parses a typed keyboard shortcut ("cmd+shift+t", "⌘⇧T", "control alt
/// delete") into a `KeyChord`, and renders one back for display. The typed
/// cousin of `SpokenKeyParser`: same canonical key names, so anything it
/// produces is something `TextTyper` can press.
public enum ShortcutParser {
    private static let modifierNames: [String: KeyChord.Modifier] = [
        "command": .command, "cmd": .command, "meta": .command,
        "shift": .shift,
        "option": .option, "opt": .option, "alt": .option,
        "control": .control, "ctrl": .control,
        "function": .function, "fn": .function,
    ]

    /// Symbol characters expand to named tokens before splitting, so "⌘⇧T"
    /// works with no separators at all.
    private static let symbolTokens: [Character: String] = [
        "⌘": "cmd", "⇧": "shift", "⌥": "opt", "⌃": "ctrl", "^": "ctrl",
        "↩": "return", "⎋": "escape", "⌫": "delete", "⇥": "tab",
        "←": "left", "→": "right", "↑": "up", "↓": "down",
    ]

    private static let namedKeys: [String: String] = [
        "return": "return", "enter": "return",
        "tab": "tab",
        "space": "space", "spacebar": "space",
        "escape": "escape", "esc": "escape",
        "delete": "delete", "backspace": "delete",
        "forwarddelete": "forwarddelete",
        "home": "home", "end": "end",
        "pageup": "pageup", "pagedown": "pagedown",
        "up": "up", "down": "down", "left": "left", "right": "right",
        "plus": "=", "minus": "-", "comma": ",", "period": ".", "dot": ".",
        "slash": "/", "backslash": "\\", "semicolon": ";", "quote": "'",
        "grave": "`", "backtick": "`", "equals": "=",
        "leftbracket": "[", "rightbracket": "]",
    ]

    /// Single characters accepted as keys directly (beyond letters/digits).
    private static let punctuationKeys: Set<Character> = [
        "[", "]", ";", "'", ",", ".", "/", "\\", "-", "=", "`",
    ]

    public static func chord(from text: String) -> KeyChord? {
        var expanded = ""
        for ch in text {
            if let token = symbolTokens[ch] {
                expanded += " \(token) "
            } else {
                expanded.append(ch)
            }
        }

        var tokens = expanded.lowercased()
            .split(whereSeparator: { $0 == "+" || $0.isWhitespace })
            .map(String.init)
        // "-" separates too ("cmd-shift-t"), except when it is itself the key
        // ("cmd+-" or a trailing "-").
        tokens = tokens.flatMap { token -> [String] in
            guard token.contains("-"), token != "-" else { return [token] }
            return token.split(separator: "-").map(String.init)
        }

        var modifiers: Set<KeyChord.Modifier> = []
        var key: String?
        for token in tokens {
            if let modifier = modifierNames[token] {
                // A modifier after the key ("t+shift") is not a shortcut.
                guard key == nil else { return nil }
                modifiers.insert(modifier)
                continue
            }
            guard key == nil, let name = keyName(from: token) else { return nil }
            key = name
        }
        guard let key else { return nil }
        return KeyChord(key: key, modifiers: modifiers)
    }

    private static func keyName(from token: String) -> String? {
        if let named = namedKeys[token] { return named }
        if token.count == 1, let ch = token.first {
            if ch.isLetter && ch.isASCII { return String(ch) }
            if ch.isNumber && ch.isASCII { return String(ch) }
            if punctuationKeys.contains(ch) { return String(ch) }
            return nil
        }
        if token.hasPrefix("f"), token.count <= 3,
           let n = Int(token.dropFirst()), (1...12).contains(n) {
            return token
        }
        return nil
    }

    /// Compact display form, Apple's modifier order: "⌃⌥⇧⌘T".
    public static func display(_ chord: KeyChord) -> String {
        var out = ""
        if chord.modifiers.contains(.function) { out += "fn " }
        if chord.modifiers.contains(.control) { out += "⌃" }
        if chord.modifiers.contains(.option) { out += "⌥" }
        if chord.modifiers.contains(.shift) { out += "⇧" }
        if chord.modifiers.contains(.command) { out += "⌘" }
        switch chord.key {
        case "return": out += "↩"
        case "escape": out += "⎋"
        case "delete": out += "⌫"
        case "forwarddelete": out += "⌦"
        case "tab": out += "⇥"
        case "space": out += "Space"
        case "left": out += "←"
        case "right": out += "→"
        case "up": out += "↑"
        case "down": out += "↓"
        case "pageup": out += "Page Up"
        case "pagedown": out += "Page Down"
        case "home": out += "Home"
        case "end": out += "End"
        default: out += chord.key.uppercased()
        }
        return out
    }
}
