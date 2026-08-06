import AppKit
import CoreGraphics
import PawvisCore

/// Maps engine screen-normalized coordinates ([0,1] top-left origin) into
/// global display coordinates (CG space: origin at main display's top-left,
/// y down — the space CGEvent expects).
struct ScreenProjector {
    var targetRect: CGRect

    init(controlAllDisplays: Bool) {
        self.targetRect = Self.computeTarget(controlAllDisplays: controlAllDisplays)
    }

    static func computeTarget(controlAllDisplays: Bool) -> CGRect {
        guard controlAllDisplays else {
            return CGDisplayBounds(CGMainDisplayID())
        }
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        let union = displays
            .map { CGDisplayBounds($0) }
            .reduce(CGRect.null) { $0.union($1) }
        return union.isNull ? CGDisplayBounds(CGMainDisplayID()) : union
    }

    func toGlobal(_ norm: Vec2) -> CGPoint {
        CGPoint(
            x: targetRect.minX + norm.x * targetRect.width,
            y: targetRect.minY + norm.y * targetRect.height)
    }
}
