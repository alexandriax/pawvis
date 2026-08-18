import Foundation

/// One gesture the user taught Pawvis: a named template built from their
/// own recorded takes, an optional bound action, and its matching tuning.
/// Everything the detector needs is persisted — the takes themselves are
/// not, only what was learned from them.
public struct TrainedGesture: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// 1 or 2 — a two-hand gesture only matches when both hands are tracked.
    public var handCount: Int
    /// `GestureTrace.keyframes` resampled feature frames.
    public var template: [[Double]]
    /// Mean take duration, seconds — sizes the live matching windows.
    public var duration: Double
    /// Calibrated from the takes: the distance a genuine performance
    /// typically lands at. The live threshold scales this by `sensitivity`.
    public var baseThreshold: Double
    /// 0 = strict … 1 = forgiving. Default 0.5.
    public var sensitivity: Double
    /// Hold-to-confirm: the match must hold this long before firing.
    /// 0 (the default) fires the moment it matches.
    public var holdSeconds: Double
    /// What firing does; nil while unassigned (an unassigned gesture is
    /// never matched, exactly like the built-in library).
    public var action: GestureAction?

    public init(id: UUID = UUID(), name: String, handCount: Int,
                template: [[Double]], duration: Double, baseThreshold: Double,
                sensitivity: Double = 0.5, holdSeconds: Double = 0,
                action: GestureAction? = nil) {
        self.id = id
        self.name = name
        self.handCount = handCount
        self.template = template
        self.duration = duration
        self.baseThreshold = baseThreshold
        self.sensitivity = sensitivity
        self.holdSeconds = holdSeconds
        self.action = action
    }

    /// The live matching threshold: strict at 0 (0.7×), forgiving at 1
    /// (1.6×), calibration as measured at the middle.
    public var threshold: Double {
        baseThreshold * (0.7 + 0.9 * min(max(sensitivity, 0), 1))
    }

    enum CodingKeys: String, CodingKey {
        case id, name, handCount, template, duration, baseThreshold
        case sensitivity, holdSeconds, action
    }

    /// The identity and the learned template decode strictly — without them
    /// there is no gesture, and the lossy list drops the record alone. The
    /// user-adjustable extras are tolerant.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        handCount = try c.decode(Int.self, forKey: .handCount)
        template = try c.decode([[Double]].self, forKey: .template)
        duration = try c.decode(Double.self, forKey: .duration)
        baseThreshold = try c.decode(Double.self, forKey: .baseThreshold)
        sensitivity = (try? c.decodeIfPresent(Double.self, forKey: .sensitivity)) ?? 0.5
        holdSeconds = (try? c.decodeIfPresent(Double.self, forKey: .holdSeconds)) ?? 0
        action = try? c.decodeIfPresent(GestureAction.self, forKey: .action)
    }
}

/// The persisted "your gestures" section: everything the user has trained.
/// Detection honors the same master switch as the built-in library
/// (`CustomGestureSettings.enabled`) — one switch pauses every extra
/// gesture, trained ones included.
public struct TrainedGestureSettings: Codable, Equatable, Sendable {
    public var gestures: [TrainedGesture] = []
    /// Trained gestures take priority over the mouse: matching keeps
    /// running through presses, and new clicks are blocked while a match
    /// is dwelling. On by default — someone who trained a gesture that
    /// curls a finger wants the gesture, not the click it resembles.
    public var mouseOverride: Bool = true

    public init() {}

    public func gesture(withID id: UUID) -> TrainedGesture? {
        gestures.first { $0.id == id }
    }

    /// What the engine's detector should watch: only gestures with an
    /// action, compiled to their effective thresholds. `enabled` is the
    /// shared custom-gestures master switch.
    public func detectorConfig(enabled: Bool) -> TrainedGestureDetector.Config {
        var config = TrainedGestureDetector.Config()
        guard enabled else { return config }
        config.overridesMouse = mouseOverride
        config.gestures = gestures.compactMap { gesture in
            guard gesture.action != nil, !gesture.template.isEmpty else { return nil }
            return TrainedGestureDetector.Compiled(
                id: gesture.id, handCount: gesture.handCount,
                template: gesture.template, duration: gesture.duration,
                threshold: gesture.threshold, holdSeconds: gesture.holdSeconds)
        }
        return config
    }

    enum CodingKeys: String, CodingKey {
        case gestures, mouseOverride
    }

    /// Element-tolerant, like the custom bindings list: one unreadable
    /// record (a newer build's format, a corrupted template) drops alone.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent([Lossy<TrainedGesture>].self, forKey: .gestures) {
            var seen: Set<UUID> = []
            gestures = v.compactMap(\.value).filter { seen.insert($0.id).inserted }
        }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .mouseOverride) { mouseOverride = v }
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
