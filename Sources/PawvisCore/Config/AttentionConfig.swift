import Foundation

/// The look-to-control settings: pause mouse and gesture actions while the
/// user faces away from the screen. Off by default — an availability gate on
/// every action is opt-in, never a surprise. Voice control is deliberately
/// outside it: speech works with your back turned, and "Pawvis stop" must
/// keep working precisely when you are not looking.
public struct AttentionConfig: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    /// One dial, 0…1. Left: relaxed — only turning well away (or leaving the
    /// frame) pauses control. Right: strict — a small turn of the head is
    /// enough. Mapped onto the gate's angle limit by `gateConfig()`.
    public var sensitivity: Double = 0.5

    public init() {}

    /// The slider's ends in degrees: relaxed tolerates a head turned almost
    /// to where the face detector loses the face anyway; strict pauses on
    /// little more than a glance at a side monitor.
    static let relaxedOffAngleDegrees = 50.0
    static let strictOffAngleDegrees = 15.0

    /// The pure gate tuning this section means. Only the angle limit rides
    /// the slider; the hysteresis margins and the away/return delays are
    /// constants, chosen rather than measured — make them settings only if
    /// someone actually asks.
    public func gateConfig() -> AttentionGate.Config {
        let s = sensitivity.clamped(to: 0...1)
        let degrees = Self.relaxedOffAngleDegrees
            - s * (Self.relaxedOffAngleDegrees - Self.strictOffAngleDegrees)
        return AttentionGate.Config(enabled: enabled, maxOffAngle: degrees * .pi / 180)
    }

    enum CodingKeys: String, CodingKey {
        case enabled, sensitivity
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .enabled) { enabled = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .sensitivity) {
            sensitivity = v.clamped(to: 0...1)
        }
    }
}
