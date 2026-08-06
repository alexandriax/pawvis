import Foundation

/// The One Euro filter (Casiez, Roussel, Vogel 2012): an adaptive low-pass
/// filter that smooths hard at low speeds (killing jitter) and lightly at high
/// speeds (killing lag). Ported from sporecaster's implementation, including
/// its two stability details: dt floored at 1e-4 s, and the derivative computed
/// against the previous *filtered* value.
public struct OneEuroFilter: Sendable {
    public struct Params: Codable, Equatable, Sendable {
        /// Baseline cutoff frequency in Hz. Lower = smoother at rest.
        public var minCutoff: Double
        /// Speed coefficient. Higher = snappier during fast motion.
        public var beta: Double
        /// Cutoff for the derivative estimate, in Hz.
        public var dCutoff: Double

        public init(minCutoff: Double = 1.4, beta: Double = 0.014, dCutoff: Double = 1.0) {
            self.minCutoff = minCutoff
            self.beta = beta
            self.dCutoff = dCutoff
        }

        /// sporecaster's landmark filter tuning (minCutoff 1.4, beta 0.014).
        public static let landmark = Params()
        /// Snappier tuning for driving a cursor, where lag is more noticeable
        /// than jitter during fast motion.
        public static let cursor = Params(minCutoff: 1.4, beta: 0.03, dCutoff: 1.0)
    }

    public var params: Params

    private var hasPrev = false
    private var prevT: Double = 0
    private var prevX: Double = 0
    private var prevDx: Double = 0

    public init(params: Params = Params()) {
        self.params = params
    }

    private static func smoothingFactor(cutoffHz: Double, dt: Double) -> Double {
        let r = 2 * .pi * cutoffHz * dt
        return r / (r + 1)
    }

    /// Filter one sample taken at time `t` (seconds, strictly increasing).
    public mutating func filter(_ value: Double, at t: Double) -> Double {
        guard hasPrev else {
            hasPrev = true
            prevT = t
            prevX = value
            prevDx = 0
            return value
        }
        let dt = max(t - prevT, 1e-4)
        let rawDx = (value - prevX) / dt
        let aD = Self.smoothingFactor(cutoffHz: params.dCutoff, dt: dt)
        let dx = aD * rawDx + (1 - aD) * prevDx
        let cutoff = params.minCutoff + params.beta * abs(dx)
        let a = Self.smoothingFactor(cutoffHz: cutoff, dt: dt)
        let x = a * value + (1 - a) * prevX
        prevT = t
        prevX = x
        prevDx = dx
        return x
    }

    public mutating func reset() {
        hasPrev = false
        prevDx = 0
    }
}

/// A 2D One Euro filter (independent filter per axis).
public struct OneEuroFilter2D: Sendable {
    private var fx: OneEuroFilter
    private var fy: OneEuroFilter

    public init(params: OneEuroFilter.Params = .init()) {
        fx = OneEuroFilter(params: params)
        fy = OneEuroFilter(params: params)
    }

    public var params: OneEuroFilter.Params {
        get { fx.params }
        set {
            fx.params = newValue
            fy.params = newValue
        }
    }

    public mutating func filter(_ point: Vec2, at t: Double) -> Vec2 {
        Vec2(fx.filter(point.x, at: t), fy.filter(point.y, at: t))
    }

    public mutating func reset() {
        fx.reset()
        fy.reset()
    }
}
