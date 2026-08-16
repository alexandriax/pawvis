import AppKit
import ApplicationServices
import PawvisCore

/// Moves and sizes the focused window of the frontmost app through the
/// Accessibility API — the same permission the mouse synthesis already
/// requires, so window actions need nothing extra. The geometry (halves,
/// thirds, quarters, centering) comes from `WindowPlacement`, which is pure
/// and unit-tested; this file only owns the AX plumbing.
///
/// AX speaks global top-left-origin coordinates (+y down); NSScreen speaks
/// Cocoa bottom-left-origin (+y up). Every rect crossing that boundary goes
/// through the two converters below.
@MainActor
final class WindowPlacer {

    /// Perform a window action. Returns false when there is no window to act
    /// on (or the app refused the AX write).
    func perform(_ kind: GestureAction.Kind) -> Bool {
        guard let window = focusedWindow() else { return false }

        if kind == .windowMinimize {
            return AXUIElementSetAttributeValue(
                window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
        }

        guard let current = frame(of: window) else { return false }
        guard let screen = screenContaining(axRect: current) else { return false }
        let visible = axRect(fromCocoa: screen.visibleFrame)

        let target: CGRect
        if kind == .windowNextDisplay {
            let screens = NSScreen.screens
            guard screens.count > 1,
                  let index = screens.firstIndex(of: screen) else { return false }
            let nextVisible = axRect(fromCocoa: screens[(index + 1) % screens.count].visibleFrame)
            target = cgRect(WindowPlacement.translated(
                placementFrame(current),
                from: placementFrame(visible), to: placementFrame(nextVisible)))
        } else {
            guard let placed = WindowPlacement.frame(
                for: kind, visible: placementFrame(visible),
                current: placementFrame(current)) else { return false }
            target = cgRect(placed)
        }

        return apply(target, to: window)
    }

    // MARK: - AX plumbing

    private func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) != .success {
            // Some apps expose only a main window (no focused one).
            guard AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &value) == .success else {
                return nil
            }
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func apply(_ target: CGRect, to window: AXUIElement) -> Bool {
        var position = target.origin
        var size = target.size
        guard let positionValue = AXValue.create(.cgPoint, &position),
              let sizeValue = AXValue.create(.cgSize, &size) else { return false }
        // Position, size, then position again: sizing can shove a window that
        // was placed while still large (moving it off the target when the new
        // size lands), and re-positioning after the resize settles it.
        let posOK = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success
        let sizeOK = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success
        _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        return posOK && sizeOK
    }

    // MARK: - Coordinate conversion

    /// The Cocoa global y-axis flips around the primary screen's top edge.
    private var primaryTop: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    private func axRect(fromCocoa rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY,
               width: rect.width, height: rect.height)
    }

    private func screenContaining(axRect rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for screen in NSScreen.screens {
            let frame = axRect(fromCocoa: screen.frame)
            if frame.contains(center) { return screen }
        }
        // Off every screen (mid-drag, odd apps): fall back to the biggest
        // overlap, then to the main screen.
        let best = NSScreen.screens.max { a, b in
            axRect(fromCocoa: a.frame).intersection(rect).area
                < axRect(fromCocoa: b.frame).intersection(rect).area
        }
        return best ?? NSScreen.main
    }

    private func placementFrame(_ rect: CGRect) -> WindowPlacement.Frame {
        WindowPlacement.Frame(x: rect.minX, y: rect.minY,
                              width: rect.width, height: rect.height)
    }

    private func cgRect(_ frame: WindowPlacement.Frame) -> CGRect {
        CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

private extension AXValue {
    static func create(_ type: AXValueType, _ value: UnsafeMutableRawPointer) -> AXValue? {
        AXValueCreate(type, value)
    }
}
