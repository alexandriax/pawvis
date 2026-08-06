import AppKit
import SwiftUI

/// Brand palette: the blue/purple pair from save.page's light-mode wordmark
/// (stock Tailwind violet-500 / sky-500 plus their light variants).
enum PawvisTheme {
    // Core pair
    static let purple = NSColor(hex: 0x8B5CF6)      // violet-500 — left-click / primary
    static let blue = NSColor(hex: 0x0EA5E9)        // sky-500 — right-click / secondary
    static let purpleLight = NSColor(hex: 0xC4B5FD) // violet-300 — index fingertip
    static let blueLight = NSColor(hex: 0x7DD3FC)   // sky-300 — thumb fingertip

    static let purpleUI = Color(nsColor: purple)
    static let blueUI = Color(nsColor: blue)
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}
