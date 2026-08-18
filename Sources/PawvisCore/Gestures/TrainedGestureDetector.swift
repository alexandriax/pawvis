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
        /// The match must hold continuously this long before firing —
        /// 0 fires the moment it matches. For pose-like gestures, so a
        /// passing resemblance can't trigger.
        public var holdSeconds: TimeInterval

        public init(id: UUID, handCount: Int, template: [[Double]],
                    duration: TimeInterval, threshold: Double,
                    holdSeconds: TimeInterval = 0) {
            self.id = id
            self.handCount = handCount
            self.template = template
            self.duration = duration
            self.threshold = threshold
            self.holdSeconds = holdSeconds
        }
    }

    public struct Config: Equatable, Sendable {
        public var gestures: [Compiled] = []
        /// Trained gestures keep matching through presses and scrolls, and
        /// the engine blocks new clicks while a match is dwelling. Off, the
        /// house rule stands: a press always wins — which also means a
        /// gesture that dips a finger can click and cancel its own match.
        public var overridesMouse: Bool = false

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
    /// Mid-dwell, the distance may flicker up to this far over the
    /// threshold without resetting the hold-to-confirm clock.
    static let dwellHysteresis = 1.15
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
    /// When each gesture's current match streak began (the hold-to-confirm
    /// dwell clock).
    private var dwellStart: [UUID: TimeInterval] = [:]
    /// The best scores of the most recent frame, for the trainer's live
    /// feedback panel.
    public private(set) var lastScores: [Score] = []
    /// A gesture is matching right now and dwelling toward its fire. The
    /// engine blocks click engagement on this while `overridesMouse` is on.
    public private(set) var candidateActive = false
    /// The dwell furthest along, for the countdown pill.
    public private(set) var holdProgress: (id: UUID, remaining: TimeInterval)?

    public func reset() {
        singleStreams = [:]
        pairStream = Stream()
        lastFire = -.infinity
        latched = []
        dwellStart = [:]
        lastScores = []
        candidateActive = false
        holdProgress = nil
    }

    // MARK: - Per-frame entry

    public func process(hands: [HandInput], context: CustomGestureDetector.Context) -> [UUID] {
        guard !config.gestures.isEmpty else {
            if !singleStreams.isEmpty || !pairStream.samples.isEmpty { reset() }
            return []
        }
        // With mouse override on, presses no longer stand matching down — a
        // gesture that dips a finger would otherwise click and cancel its
        // own match every time. The wave still wins either way.
        let standDown = (context.pressOrScrollActive && !config.overridesMouse)
            || context.crissCrossEngaged
        if standDown {
            singleStreams = [:]
            pairStream = Stream()
            lastScores = []
            dwellStart = [:]
            candidateActive = false
            holdProgress = nil
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

        // Score every gesture on its stream(s); fire the best match whose
        // hold-to-confirm dwell has elapsed.
        var scores: [Score] = []
        var bestFire: (gesture: Compiled, distance: Double)?
        var dwelling: (id: UUID, remaining: TimeInterval)?
        for gesture in config.gestures {
            let streams: [Stream] = gesture.handCount == 2
                ? [pairStream] : Array(singleStreams.values)
            var best = Double.infinity
            for stream in streams {
                best = min(best, bestDistance(of: gesture, in: stream, at: context.time))
            }
            guard best < .infinity else {
                latched.remove(gesture.id)
                dwellStart.removeValue(forKey: gesture.id)
                continue
            }
            scores.append(Score(id: gesture.id, distance: best, threshold: gesture.threshold))

            if latched.contains(gesture.id) {
                if best > gesture.threshold * Self.unlatchFactor {
                    latched.remove(gesture.id)
                }
                dwellStart.removeValue(forKey: gesture.id)
                continue
            }
            if best <= gesture.threshold {
                let start = dwellStart[gesture.id] ?? context.time
                dwellStart[gesture.id] = start
                let elapsed = context.time - start
                if elapsed >= gesture.holdSeconds {
                    if bestFire == nil || best < bestFire!.distance {
                        bestFire = (gesture, best)
                    }
                } else {
                    let remaining = gesture.holdSeconds - elapsed
                    if dwelling == nil || remaining < dwelling!.remaining {
                        dwelling = (gesture.id, remaining)
                    }
                }
            } else if best > gesture.threshold * Self.dwellHysteresis {
                // A clear miss resets the hold; a flicker just over the
                // line doesn't throw the dwell away.
                dwellStart.removeValue(forKey: gesture.id)
            }
        }
        lastScores = scores
        holdProgress = dwelling
        candidateActive = dwelling != nil

        guard let fire = bestFire, context.time - lastFire >= Self.refractory else { return [] }
        lastFire = context.time
        latched.insert(fire.gesture.id)
        dwellStart.removeValue(forKey: fire.gesture.id)
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
