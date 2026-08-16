import AppKit
import CoreGraphics
import Foundation
import PawvisCore

/// Types text and presses key chords in the focused app via synthetic
/// keyboard events.
final class TextTyper {
    private let source = CGEventSource(stateID: .hidSystemState)

    /// ANSI virtual key codes (kVK_*) for every canonical KeyChord name.
    private static let keyCodes: [String: CGKeyCode] = [
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "forwarddelete": 117, "home": 115, "end": 119,
        "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
        "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "9": 25, "7": 26, "8": 28, "0": 29,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        // ANSI punctuation, for typed shortcuts (gesture actions): ⌘[ and ⌘]
        // are browser back/forward, and ShortcutParser accepts the rest.
        "[": 33, "]": 30, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44,
        "\\": 42, "-": 27, "=": 24, "`": 50,
    ]

    func perform(_ actions: [TypingAction]) {
        for action in actions {
            switch action {
            case .type(let text):
                type(text)
            case .backspace(let count):
                pressKeyCode(51, times: count) // delete
            case .key(let chord):
                press(chord)
            }
        }
    }

    /// Whether a chord's key name is one the typist can actually press.
    static func canPress(_ chord: KeyChord) -> Bool {
        keyCodes[chord.key] != nil
    }

    func press(_ chord: KeyChord) {
        guard let keyCode = Self.keyCodes[chord.key] else { return }
        pressKeyCode(keyCode, flags: Self.flags(for: chord.modifiers))
    }

    private static func flags(for modifiers: Set<KeyChord.Modifier>) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .shift: flags.insert(.maskShift)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            case .function: flags.insert(.maskSecondaryFn)
            }
        }
        return flags
    }

    /// Unicode injection: no keyboard-layout mapping needed, works for any
    /// text. Chunked because keyboardSetUnicodeString tops out around 20
    /// UTF-16 units per event.
    ///
    /// `.flags = []` on every event is load-bearing, not tidiness: a CGEvent
    /// created from a source INHERITS the source state's current modifier
    /// flags. After a flagged chord (⌘L to focus an address bar), inherited
    /// state intermittently left Command on the "typed" events and the
    /// Return that followed — in Chrome's omnibox that turns into ignored
    /// text plus ⌘Return, which opens the still-selected CURRENT url in a
    /// background tab. Every synthetic keyboard event states its modifiers
    /// explicitly; nothing is left to inheritance.
    func type(_ text: String) {
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + 20, units.count)])
            index += chunk.count
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }
            down.flags = []
            up.flags = []
            chunk.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buffer.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Hardware media keys aren't regular key codes — they're systemDefined
    /// NSEvents (subtype 8) that macOS routes to the now-playing app.
    func press(_ media: MediaKey) {
        let keyType: Int32
        switch media {
        case .playPause: keyType = 16 // NX_KEYTYPE_PLAY
        }
        for down in [true, false] {
            let data1 = Int((keyType << 16) | Int32((down ? 0xA : 0xB) << 8))
            NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                context: nil, subtype: 8, data1: data1, data2: -1
            )?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private func pressKeyCode(_ keyCode: CGKeyCode, flags: CGEventFlags = [], times: Int = 1) {
        guard times > 0 else { return }
        for _ in 0..<times {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
                continue
            }
            // Always assigned — an unmodified press must SAY it is
            // unmodified, or it inherits whatever the source state holds
            // (see type() above for the bug that taught this).
            down.flags = flags
            up.flags = flags
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            // Brief spacing so repeated deletes register reliably everywhere.
            if times > 1 { usleep(2000) }
        }
    }
}
