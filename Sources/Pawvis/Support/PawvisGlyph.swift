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

    /// The photoreal sloth paw from the README — the About pane's portrait.
    /// Not a template: it's a photograph, not a glyph.
    static func pawPhoto() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "paw-photo", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
