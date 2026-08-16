import Foundation

/// One custom gesture the user has added, and what it does. `action` is nil
/// while the row sits in Settings waiting for an action to be chosen — an
/// unbound gesture is never detected.
public struct CustomGestureBinding: Codable, Equatable, Sendable, Identifiable {
    public var gesture: CustomGesture
    public var action: GestureAction?

    /// One binding per gesture, so the gesture is the identity.
    public var id: CustomGesture { gesture }

    public init(gesture: CustomGesture, action: GestureAction? = nil) {
        self.gesture = gesture
        self.action = action
    }

    enum CodingKeys: String, CodingKey {
        case gesture, action
    }

    /// `gesture` decodes strictly (a binding for a gesture this build doesn't
    /// know is dropped by the lossy list below); an unreadable action just
    /// leaves the binding unbound.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gesture = try c.decode(CustomGesture.self, forKey: .gesture)
        action = try? c.decodeIfPresent(GestureAction.self, forKey: .action)
    }
}

/// The Settings → Custom section: which extra gestures are bound to which
/// actions, plus the per-family sensitivity tuning. Nothing here is on by
/// default — an empty `bindings` list means the detector never runs.
public struct CustomGestureSettings: Codable, Equatable, Sendable {
    /// Master switch: off keeps every binding but stops detection.
    public var enabled: Bool = true
    /// The user's gestures, in the order they added them.
    public var bindings: [CustomGestureBinding] = []

    // Sensitivity, in the detector's own units (the sliders map onto these
    // ranges directly).
    /// Screen-normalized distance an open hand must sweep to swipe.
    public var swipeTravel: Double = 0.32
    /// Per-finger direction reversals that count as wiggling.
    public var wiggleReversals: Int = 3
    /// How long a held pose must dwell before it fires, in seconds.
    public var holdSeconds: Double = 0.35
    /// Screen-normalized displacement that completes a grab & fling.
    public var flingTravel: Double = 0.16

    public init() {}

    /// The binding for a gesture, if the user added one.
    public func binding(for gesture: CustomGesture) -> CustomGestureBinding? {
        bindings.first { $0.gesture == gesture }
    }

    /// The action a fired gesture should perform, honoring the master switch.
    public func action(for gesture: CustomGesture) -> GestureAction? {
        guard enabled else { return nil }
        return binding(for: gesture)?.action
    }

    /// The families that currently have at least one added gesture — the
    /// sensitivity sliders only show for these.
    public var familiesInUse: Set<CustomGesture.Family> {
        Set(bindings.map(\.gesture.family))
    }

    /// What the engine's detector should watch: only gestures whose binding
    /// has an action, and nothing at all while the master switch is off.
    public func detectorConfig() -> CustomGestureDetector.Config {
        var config = CustomGestureDetector.Config()
        guard enabled else { return config }
        config.enabled = Set(bindings.compactMap { $0.action != nil ? $0.gesture : nil })
        config.swipeTravel = swipeTravel
        config.wiggleReversals = wiggleReversals
        config.holdSeconds = holdSeconds
        config.flingTravel = flingTravel
        return config
    }

    enum CodingKeys: String, CodingKey {
        case enabled, bindings
        case swipeTravel, wiggleReversals, holdSeconds, flingTravel
    }

    /// Field-tolerant decoding, like every settings section; the bindings
    /// list is additionally element-tolerant, so one unreadable binding (say,
    /// from a newer build's gesture) drops alone instead of resetting the list.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .enabled) { enabled = v }
        if let v = try? c.decodeIfPresent([Lossy<CustomGestureBinding>].self, forKey: .bindings) {
            var seen: Set<CustomGesture> = []
            bindings = v.compactMap(\.value).filter { seen.insert($0.gesture).inserted }
        }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .swipeTravel) { swipeTravel = v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .wiggleReversals) { wiggleReversals = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .holdSeconds) { holdSeconds = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .flingTravel) { flingTravel = v }
    }
}

/// Wraps an element so a failed decode yields nil instead of failing the
/// whole array (the unkeyed container still advances past the element).
private struct Lossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) {
        value = try? T(from: decoder)
    }
}
