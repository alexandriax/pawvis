import AppKit
import SwiftUI

/// Brand palette: the blue/purple pair from save.page's wordmark
/// (stock Tailwind violet / sky).
enum PawvisTheme {
    // Core pair — fixed sRGB on purpose: the overlay paints on top of
    // arbitrary screen content, not on a window material, so these never
    // flip with the system appearance.
    static let purple = NSColor(hex: 0x8B5CF6)      // violet-500 — left-click / primary
    static let blue = NSColor(hex: 0x0EA5E9)        // sky-500 — right-click / secondary
    static let purpleLight = NSColor(hex: 0xC4B5FD) // violet-300 — index fingertip
    static let blueLight = NSColor(hex: 0x7DD3FC)   // sky-300 — thumb fingertip

    static let purpleUI = Color(nsColor: purple)

    /// One color per finger — thumb, index, middle, ring, little — for the
    /// trainer's live landmark dots and the trained-gesture badge. Thumb and
    /// index keep the overlay's own pair; the rest extend the palette with
    /// the same Tailwind 300-weight family so the set reads as one system.
    static let fingerDots: [NSColor] = [
        blueLight,                 // thumb — sky-300, as on the overlay
        purpleLight,               // index — violet-300, as on the overlay
        NSColor(hex: 0xF0ABFC),    // middle — fuchsia-300
        NSColor(hex: 0x6EE7B7),    // ring — emerald-300
        NSColor(hex: 0xFCD34D),    // little — amber-300
    ]
    static var fingerDotsUI: [Color] { fingerDots.map(Color.init(nsColor:)) }

    /// Menu accent, on save.page's own wordmark pair: violet-500 in light
    /// mode, violet-300 in dark. Violet-500 is only ~3.4:1 on the dark menu
    /// material, which is why the claw all but disappeared there; violet-300
    /// takes it to ~7.7:1.
    static let accent = dynamic(light: 0x8B5CF6, dark: 0xC4B5FD)
    static let accentUI = Color(nsColor: accent)

    /// Attention: the mic is live, or something wants a decision. Warm
    /// enough to pull an eye without red's "you broke it" reading, and it is
    /// the third hue save.page uses. Fuchsia-600 in light mode,
    /// fuchsia-300 in dark.
    static let attention = dynamic(light: 0xC026D3, dark: 0xF0ABFC)
    static let attentionUI = Color(nsColor: attention)

    /// A menu chip: solid fill, high-contrast type, optional hairline.
    struct Chip {
        let fill: NSColor
        let text: NSColor
        let border: NSColor?

        var fillUI: Color { Color(nsColor: fill) }
        var textUI: Color { Color(nsColor: text) }
        var borderUI: Color? { border.map(Color.init(nsColor:)) }
    }

    // One visual language per appearance, which is the part that read as
    // "funky" before: a saturated fill with white type in light mode, the
    // pale 300-shade with ink type in dark, following how save.page colors
    // its own buttons. Light fills sit one Tailwind stop darker than
    // save.page's 500s because white on violet-500 is 4.2:1, under AA's
    // 4.5:1 at this text size. `chips.contrastAA` in the self-test is what
    // keeps that true if these are ever retuned.
    static let chipPurple = Chip(                       // violet-600 / violet-300
        fill: dynamic(light: 0x7C3AED, dark: 0xC4B5FD), text: chipInk, border: nil)
    static let chipBlue = Chip(                         // sky-700 / sky-300
        fill: dynamic(light: 0x0369A1, dark: 0x7DD3FC), text: chipInk, border: nil)
    static let chipFuchsia = Chip(fill: attention, text: chipInk, border: nil)

    /// The recessive chip, for actions that shouldn't compete: it takes the
    /// panel's own value (light chip in light mode, dark chip in dark) with
    /// a hairline to keep the edge legible on translucent material. Quit
    /// wears this — a bright chip there made "leave" the loudest thing in
    /// the menu, and a red one made it look dangerous.
    static let chipQuiet = Chip(
        fill: dynamic(light: 0xE8E8ED, dark: 0x3A3A42),
        text: dynamic(light: 0x0B0912, dark: 0xEFECF8),
        border: dynamic(light: 0x0B0912, dark: 0xFFFFFF, alpha: 0.18))

    /// The disabled chip: the quiet fill with muted (but still AA-clearing)
    /// type, at full opacity. Disabled must never be an alpha wash — a
    /// half-transparent chip over the menu's vibrancy reads as a rendering
    /// bug, not as "off" (measured: the voice Start chip while voice
    /// control is switched off in Settings). Hue-less is the affordance.
    static let chipDisabled = Chip(
        fill: dynamic(light: 0xE8E8ED, dark: 0x3A3A42),
        text: dynamic(light: 0x515157, dark: 0xAEAEB6),
        border: dynamic(light: 0x0B0912, dark: 0xFFFFFF, alpha: 0.12))

    /// Type on the saturated chips: white in light mode, the site's ink in
    /// dark, since those fills invert.
    private static let chipInk = dynamic(light: 0xFFFFFF, dark: 0x0B0912)

    /// Every chip, so the self-test can check each one's fill/type contrast
    /// in both appearances.
    static let allChips: [(name: String, chip: Chip)] = [
        ("purple", chipPurple), ("blue", chipBlue),
        ("fuchsia", chipFuchsia), ("quiet", chipQuiet),
        ("disabled", chipDisabled),
    ]

    /// A color that resolves per appearance, so chips flip with the OS
    /// light/dark setting instead of holding one fixed fill.
    private static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(hex: hex).withAlphaComponent(alpha)
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }

    /// Resolves a dynamic color against one appearance. Dynamic colors only
    /// pick a value while something is drawing, so component access outside
    /// this returns whichever side happened to be current.
    func resolved(for appearance: NSAppearance) -> NSColor {
        var result = self
        appearance.performAsCurrentDrawingAppearance {
            result = self.usingColorSpace(.sRGB) ?? self
        }
        return result
    }

    /// WCAG 2.1 relative luminance.
    var relativeLuminance: CGFloat {
        func channel(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(redComponent)
            + 0.7152 * channel(greenComponent)
            + 0.0722 * channel(blueComponent)
    }

    /// WCAG 2.1 contrast ratio, 1...21. Both colors must be opaque sRGB.
    func contrastRatio(against other: NSColor) -> CGFloat {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
