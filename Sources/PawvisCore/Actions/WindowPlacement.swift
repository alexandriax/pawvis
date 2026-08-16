import Foundation

/// Pure geometry for the window-management actions: given the screen's
/// visible frame and the window's current frame, where should the window go?
/// Top-left origin with +y down, matching the Accessibility API the app layer
/// applies these with. Kept model-free and here so the arithmetic — thirds,
/// quarters, centering — is unit-tested rather than eyeballed.
public enum WindowPlacement {
    public struct Frame: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// The target frame for a placement kind, or nil when the kind doesn't
    /// place a window (minimize and next-display act differently, and
    /// non-window kinds don't act on windows at all).
    public static func frame(for kind: GestureAction.Kind,
                             visible: Frame, current: Frame) -> Frame? {
        let x = visible.x, y = visible.y, w = visible.width, h = visible.height
        switch kind {
        case .windowLeftHalf:
            return Frame(x: x, y: y, width: w / 2, height: h)
        case .windowRightHalf:
            return Frame(x: x + w / 2, y: y, width: w / 2, height: h)
        case .windowTopHalf:
            return Frame(x: x, y: y, width: w, height: h / 2)
        case .windowBottomHalf:
            return Frame(x: x, y: y + h / 2, width: w, height: h / 2)
        case .windowLeftTwoThirds:
            return Frame(x: x, y: y, width: w * 2 / 3, height: h)
        case .windowRightTwoThirds:
            return Frame(x: x + w / 3, y: y, width: w * 2 / 3, height: h)
        case .windowLeftThird:
            return Frame(x: x, y: y, width: w / 3, height: h)
        case .windowRightThird:
            return Frame(x: x + w * 2 / 3, y: y, width: w / 3, height: h)
        case .windowTopLeftQuarter:
            return Frame(x: x, y: y, width: w / 2, height: h / 2)
        case .windowTopRightQuarter:
            return Frame(x: x + w / 2, y: y, width: w / 2, height: h / 2)
        case .windowBottomLeftQuarter:
            return Frame(x: x, y: y + h / 2, width: w / 2, height: h / 2)
        case .windowBottomRightQuarter:
            return Frame(x: x + w / 2, y: y + h / 2, width: w / 2, height: h / 2)
        case .windowMaximize:
            return visible
        case .windowCenter:
            // Keep the window's size (shrunk to fit if it overflows), centered.
            let cw = min(current.width, w)
            let ch = min(current.height, h)
            return Frame(x: x + (w - cw) / 2, y: y + (h - ch) / 2, width: cw, height: ch)
        default:
            return nil
        }
    }

    /// Where a window goes when it moves to another display: same relative
    /// position and proportional size, so a left-half window is still a
    /// left-half window on the new screen.
    public static func translated(_ current: Frame,
                                  from source: Frame, to target: Frame) -> Frame {
        guard source.width > 0, source.height > 0 else { return target }
        let rx = (current.x - source.x) / source.width
        let ry = (current.y - source.y) / source.height
        let rw = min(current.width / source.width, 1)
        let rh = min(current.height / source.height, 1)
        return Frame(
            x: target.x + rx * target.width,
            y: target.y + ry * target.height,
            width: rw * target.width,
            height: rh * target.height)
    }
}
