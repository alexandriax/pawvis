import AppKit

/// Bundled art shared by the UI. Every call returns a *fresh* `NSImage`:
/// `size` and `isTemplate` are instance state, so handing out one cached
/// object would let the menu bar's 18pt copy resize the menu's copy too.
///
/// Nil when the asset is missing — running the bare binary rather than the
/// assembled `.app`. Callers fall back to an SF Symbol.
enum PawvisGlyph {
    /// The sloth-claw glyph, as a template image so it takes the surrounding
    /// tint (menu bar light/dark, or `.tint` inside our own views).
    static func claw(size: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "menubar-claw", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: size, height: size)
        return image
    }

    /// A posed-hand glyph for the Gesture Guide, by the name of its file in
    /// `docs/assets/gestures` (`click`, `right-click-little`, …), which
    /// `make_app.sh` copies into the bundle with a `gesture-` prefix.
    ///
    /// Template, like the claw: the SVG carries the *site's* colors, and
    /// template rendering keys off alpha alone, so the app draws the whole
    /// pose in the surrounding tint and one file serves both. NSImage renders
    /// SVG as a vector rep, so setting `size` scales it cleanly.
    static func gesture(_ name: String, size: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "gesture-\(name)", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: size, height: size)
        return image
    }

    /// A whole-gesture guide panel (the `full-*` set), same pipeline as
    /// `gesture` but in the panels' wide 104x48 format, so the height
    /// follows the width instead of assuming a square.
    static func guidePanel(_ name: String, width: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "gesture-\(name)", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: width, height: width * 48 / 104)
        return image
    }

    /// The photoreal sloth paw from the README — the About pane's portrait.
    /// Not a template: it's a photograph, not a glyph.
    static func pawPhoto() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "paw-photo", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
