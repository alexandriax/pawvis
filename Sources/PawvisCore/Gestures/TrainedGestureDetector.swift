import Foundation

/// Matches the user's trained gestures against the live hand stream.
///
/// Each tracked hand keeps a rolling buffer of snapshots; one-hand gestures
/// match against any single hand's recent window, two-hand gestures against
/// the combined stream of exactly two tracked hands. A candidate window is
/// vectorized (travel re-zeroed at the window start), resampled to the
/// template's keyframe count, and DTW-scored at a few window lengths around
/// the template's own duration — under the gesture's calibrated threshold,
/// it fires.
///
/// House rules, same as the built-in one-shot detector: deterministic and
/// clock-free; presses and scrolls stand everything down; the criss-cross
/// wave stands this whole family down (a trained gesture mid-wave is more
/// likely the wave); unreadable frames hold state; firing latches until the
/// match visibly breaks, so a *held* trained pose fires once, not once per
/// refractory.
public final class TrainedGestureDetector {

    /// One gesture, compiled for matching.
    public struct Compiled: Equatable, Sendable {
        public var id: UUID
        public var handCount: Int
        public var template: [[Double]]
        public var duration: TimeInterval
        public var threshold: Double

        public init(id: UUID, handCount: Int, template: [[Double]],
                    duration: TimeInterval, threshold: Double) {
            self.id = id
            self.handCount = handCount
            self.template = template
            self.duration = duration
            self.threshold = threshold
        }
    }

    public struct Config: Equatable, Sendable {
        public var gestures: [Compiled] = []

        public init() {}
    }

    /// A live match candidate the trainer's "try it" panel can display:
    /// the best distance seen this frame against a gesture's threshold.
    public struct Score: Equatable, Sendable {
        public var id: UUID
        public var distance: Double
        public var threshold: Double

        public var matches: Bool { distance <= threshold }
    }

    public var config: Config {
        didSet { if config != oldValue { reset() } }
    }

    public init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - Tuning

    /// Candidate window lengths, as fractions of the template's duration:
    /// people repeat their own gesture a little quicker or slower.
    static let windowScales: [Double] = [0.75, 1.0, 1.3]
    /// The shortest usable candidate window.
    static let minWindowSeconds: TimeInterval = 0.15
    static let minWindowFrames = 6
    /// One fire per family per this long.
    static let refractory: TimeInterval = 1.2
    /// A fired gesture stays latched until its best distance rises this far
    /// above the threshold — a held pose fires once per performance.
    static let unlatchFactor = 1.3
    /// Buffer gaps larger than this break a stream (hand lost or pair
    /// dissolved); the buffer restarts.
    static let maxGap: TimeInterval = 0.30

    // MARK: - State

    private struct Sample {
        var time: TimeInterval
        var frame: [GestureTrace.HandSnapshot]
    }

    /// One matching stream: a single hand's history, or the two-hand pair's.
    private struct Stream {
        var samples: [Sample] = []
        var lastSeen: TimeInterval = -.infinity

        mutating func append(_ frame: [GestureTrace.HandSnapshot],
                             at time: TimeInterval, keeping horizon: TimeInterval) {
            if time - lastSeen > TrainedGestureDetector.maxGap { samples = [] }
            samples.append(Sample(time: time, frame: frame))
            lastSeen = time
            while let first = samples.first, time - first.time > horizon {
                samples.removeFirst()
            }
        }
    }

    public struct HandInput {
        public var slot: Int
        public var hand: Hand

        public init(slot: Int, hand: Hand) {
            self.slot = slot
            self.hand = hand
        }
    }

    private var singleStreams: [Int: Stream] = [:]
    private var pairStream = Stream()
    private var lastFire: TimeInterval = -.infinity
    /// Gestures currently latched (matched and not yet visibly released).
    private var latched: Set<UUID> = []
    /// The best scores of the most recent frame, for the trainer's live
    /// feedback panel.
    public private(set) var lastScores: [Score] = []

    public func reset() {
        singleStreams = [:]
        pairStream = Stream()
        lastFire = -.infinity
        latched = []
        lastScores = []
    }

    // MARK: - Per-frame entry

    public func process(hands: [HandInput], context: CustomGestureDetector.Context) -> [UUID] {
        guard !config.gestures.isEmpty else {
            if !singleStreams.isEmpty || !pairStream.samples.isEmpty { reset() }
            return []
        }
        if context.pressOrScrollActive || context.crissCrossEngaged {
            // Presses (and the wave) always win: restart from silence.
            singleStreams = [:]
            pairStream = Stream()
            lastScores = []
            return []
        }

        let horizon = (config.gestures.map { $0.duration }.max() ?? 1)
            * (Self.windowScales.max() ?? 1) + 0.5

        // Reduce this frame's hands to snapshots; unreadable hands drop out
        // of their streams via the gap rule rather than poisoning them.
        var snapshots: [(slot: Int, snapshot: GestureTrace.HandSnapshot)] = []
        for input in hands {
            if let snapshot = GestureTrace.snapshot(
                of: input.hand, minJointConfidence: context.minJointConfidence) {
                snapshots.append((input.slot, snapshot))
            }
        }

        for (slot, snapshot) in snapshots {
            singleStreams[slot, default: Stream()]
                .append([snapshot], at: context.time, keeping: horizon)
        }
        for (slot, stream) in singleStreams
        where context.time - stream.lastSeen > context.trackingLossGrace {
            singleStreams.removeValue(forKey: slot)
        }
        if snapshots.count == 2 {
            let pair = GestureTrace.orderedPair(snapshots.map(\.snapshot))
            pairStream.append(pair, at: context.time, keeping: horizon)
        }

        // Score every gesture on its stream(s); fire the best match.
        var scores: [Score] = []
        var bestFire: (gesture: Compiled, distance: Double)?
        for gesture in config.gestures {
            let streams: [Stream] = gesture.handCount == 2
                ? [pairStream] : Array(singleStreams.values)
            var best = Double.infinity
            for stream in streams {
                best = min(best, bestDistance(of: gesture, in: stream, at: context.time))
            }
            guard best < .infinity else {
                latched.remove(gesture.id)
                continue
            }
            scores.append(Score(id: gesture.id, distance: best, threshold: gesture.threshold))

            if latched.contains(gesture.id) {
                if best > gesture.threshold * Self.unlatchFactor {
                    latched.remove(gesture.id)
                }
                continue
            }
            guard best <= gesture.threshold else { continue }
            if bestFire == nil || best < bestFire!.distance {
                bestFire = (gesture, best)
            }
        }
        lastScores = scores

        guard let fire = bestFire, context.time - lastFire >= Self.refractory else { return [] }
        lastFire = context.time
        latched.insert(fire.gesture.id)
        return [fire.gesture.id]
    }

    /// The best DTW distance of a gesture against a stream's most recent
    /// window, over the candidate window lengths.
    private func bestDistance(of gesture: Compiled, in stream: Stream,
                              at time: TimeInterval) -> Double {
        guard !stream.samples.isEmpty else { return .infinity }
        var best = Double.infinity
        for scale in Self.windowScales {
            let span = max(gesture.duration * scale, Self.minWindowSeconds)
            guard let first = stream.samples.first, time - first.time >= span else { continue }
            let window = stream.samples.filter { time - $0.time <= span }
            guard window.count >= Self.minWindowFrames else { continue }
            let vectors = GestureTrace.vectorize(window.map(\.frame))
            guard !vectors.isEmpty else { continue }
            let resampled = GestureTrace.resample(
                vectors, times: window.map(\.time), to: GestureTrace.keyframes)
            best = min(best, GestureTrace.distance(gesture.template, resampled))
        }
        return best
    }
}
