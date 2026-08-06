import Foundation

/// The sub-rectangle of the (mirrored) camera frame that maps onto the full
/// screen. Margins mean you never have to reach the edge of the camera's view
/// to reach the edge of the screen.
public struct InteractionBox: Codable, Equatable, Sendable {
    public var xMin: Double
    public var xMax: Double
    public var yMin: Double
    public var yMax: Double

    public init(xMin: Double = 0.15, xMax: Double = 0.85, yMin: Double = 0.18, yMax: Double = 0.82) {
        self.xMin = xMin
        self.xMax = xMax
        self.yMin = yMin
        self.yMax = yMax
    }

    public static let `default` = InteractionBox()
}

/// Maps camera-normalized landmark positions (x right, y down, unmirrored) to
/// screen-normalized positions (x right, y down, top-left origin).
public struct CoordinateMapper: Codable, Equatable, Sendable {
    public var box: InteractionBox
    /// Mirror horizontally so moving your hand right moves the cursor right
    /// (webcam images are unmirrored; the user expects mirror behavior).
    public var mirrored: Bool

    public init(box: InteractionBox = .default, mirrored: Bool = true) {
        self.box = box
        self.mirrored = mirrored
    }

    /// Map a camera-space point into screen-normalized space.
    /// - Parameter clamped: clamp to [0,1] (use for the cursor; leave unclamped
    ///   for overlay fingertip dots so they can visibly run off-screen).
    public func map(_ cameraPoint: Vec2, clamped: Bool = true) -> Vec2 {
        let x = mirrored ? 1 - cameraPoint.x : cameraPoint.x
        let y = cameraPoint.y
        let w = max(box.xMax - box.xMin, 1e-6)
        let h = max(box.yMax - box.yMin, 1e-6)
        let mapped = Vec2((x - box.xMin) / w, (y - box.yMin) / h)
        return clamped ? mapped.clampedToUnit() : mapped
    }
}
