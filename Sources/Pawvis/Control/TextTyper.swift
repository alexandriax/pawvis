import CoreGraphics
import Foundation
import PawvisCore

/// Types dictated text into the focused app via synthetic keyboard events.
final class TextTyper {
    private let source = CGEventSource(stateID: .hidSystemState)

    private enum KeyCode {
        static let `return`: CGKeyCode = 36
        static let tab: CGKeyCode = 48
        static let delete: CGKeyCode = 51
    }

    func perform(_ actions: [TypingAction]) {
        for action in actions {
            switch action {
            case .type(let text):
                type(text)
            case .backspace(let count):
                pressKey(KeyCode.delete, times: count)
            case .key(.return):
                pressKey(KeyCode.return)
            case .key(.tab):
                pressKey(KeyCode.tab)
            }
        }
    }

    /// Unicode injection: no keyboard-layout mapping needed, works for any
    /// text. Chunked because keyboardSetUnicodeString tops out around 20
    /// UTF-16 units per event.
    private func type(_ text: String) {
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + 20, units.count)])
            index += chunk.count
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }
            chunk.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buffer.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private func pressKey(_ keyCode: CGKeyCode, times: Int = 1) {
        guard times > 0 else { return }
        for _ in 0..<times {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
                continue
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            // Brief spacing so repeated deletes register reliably everywhere.
            if times > 1 { usleep(2000) }
        }
    }
}
