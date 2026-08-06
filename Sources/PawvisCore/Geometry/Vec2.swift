import Foundation

/// A lightweight 2D vector used throughout PawvisCore.
///
/// Conventions: unless stated otherwise, coordinates are normalized to [0, 1]
/// with the origin at the top-left and +y pointing down (screen orientation).
public struct Vec2: Equatable, Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func * (s: Double, a: Vec2) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func / (a: Vec2, s: Double) -> Vec2 { Vec2(a.x / s, a.y / s) }

    public var length: Double { (x * x + y * y).squareRoot() }

    public func distance(to other: Vec2) -> Double { (self - other).length }

    public func dot(_ other: Vec2) -> Double { x * other.x + y * other.y }

    /// Midpoint between this point and another.
    public func midpoint(with other: Vec2) -> Vec2 { (self + other) / 2 }

    /// Linear interpolation: t = 0 → self, t = 1 → other.
    public func lerp(to other: Vec2, t: Double) -> Vec2 { self + (other - self) * t }

    /// Component-wise clamp to [0, 1].
    public func clampedToUnit() -> Vec2 {
        Vec2(min(max(x, 0), 1), min(max(y, 0), 1))
    }

    /// Angle in radians of the vector formed at vertex `self` between rays to `a` and `b`.
    /// Returns a value in [0, π]. Returns π (fully straight) when either ray is degenerate,
    /// so degenerate joints read as "extended" rather than "curled".
    public static func angle(at vertex: Vec2, from a: Vec2, to b: Vec2) -> Double {
        let u = a - vertex
        let v = b - vertex
        let lu = u.length
        let lv = v.length
        guard lu > 1e-9, lv > 1e-9 else { return .pi }
        let cosTheta = min(max(u.dot(v) / (lu * lv), -1), 1)
        return acos(cosTheta)
    }
}

/// Average of a non-empty collection of points; `.zero` for an empty one.
public func centroid(of points: [Vec2]) -> Vec2 {
    guard !points.isEmpty else { return .zero }
    let sum = points.reduce(Vec2.zero, +)
    return sum / Double(points.count)
}
