import Foundation

/// One recorded performance of a gesture being trained.
public struct GestureTake: Equatable, Sendable {
    public var times: [TimeInterval]
    /// Snapshot frames, hand count consistent throughout (two-hand frames
    /// ordered left-to-right).
    public var frames: [[GestureTrace.HandSnapshot]]
    public var handCount: Int

    public init(times: [TimeInterval], frames: [[GestureTrace.HandSnapshot]], handCount: Int) {
        self.times = times
        self.frames = frames
        self.handCount = handCount
    }

    public var duration: TimeInterval {
        guard let first = times.first, let last = times.last else { return 0 }
        return last - first
    }

    /// The take as template-shaped keyframes.
    public func keyframes() -> [[Double]] {
        GestureTrace.resample(GestureTrace.vectorize(frames), times: times,
                              to: GestureTrace.keyframes)
    }
}

/// Segments one take out of the live snapshot stream, clock-free like every
/// core state machine: begin() arms it (the trainer's countdown just ended),
/// motion starts the capture, stillness (or the cap) ends it — and a pose
/// held *without* motion becomes a static take after a grace, so "train a
/// peace sign" needs no waving.
public final class TakeRecorder {
    public enum Event: Equatable {
        /// Motion seen; the take is being captured.
        case started
        /// The take ended and survived the sanity floor.
        case finished(GestureTake)
        /// The take ended but was unusable.
        case discarded(reason: String)
    }

    public enum Phase: Equatable {
        case idle
        /// Armed, waiting for motion (or the static-pose grace).
        case waiting
        case recording
    }

    // Tuning, all in feature-space or seconds. Motion is the *largest*
    // frame-to-frame change across the feature dims — a palm sweeping on
    // one axis and a finger curling read the same way, where a mean across
    // twelve dims would dilute either below any usable floor.
    static let motionFloor = 0.06
    static let stillSeconds: TimeInterval = 0.55
    static let maxSeconds: TimeInterval = 4.0
    /// No motion for this long after arming → the held pose *is* the
    /// gesture: capture what's buffered as a static take.
    static let staticGrace: TimeInterval = 1.5
    static let minSeconds: TimeInterval = 0.20
    static let minFrames = 6
    /// Consecutive unusable frames (wrong hand count, unreadable geometry)
    /// tolerated mid-recording before the take is abandoned.
    static let maxDropoutFrames = 8

    public private(set) var phase: Phase = .idle

    private var handCount = 1
    private var times: [TimeInterval] = []
    private var frames: [[GestureTrace.HandSnapshot]] = []
    private var lastVector: [Double]?
    private var stillSince: TimeInterval?
    private var armedAt: TimeInterval = -.infinity
    private var dropoutFrames = 0

    public init() {}

    /// Arm for one take. The trainer calls this when its countdown ends.
    public func begin(handCount: Int, at time: TimeInterval) {
        self.handCount = max(1, min(handCount, 2))
        phase = .waiting
        times = []
        frames = []
        lastVector = nil
        stillSince = nil
        armedAt = time
        dropoutFrames = 0
    }

    public func cancel() {
        phase = .idle
    }

    /// Feed one camera frame's snapshots (already reduced; pass every frame,
    /// usable or not). Returns an event when something happened.
    public func feed(_ snapshots: [GestureTrace.HandSnapshot], at time: TimeInterval) -> Event? {
        guard phase != .idle else { return nil }

        let usable = snapshots.count == handCount
        let frame = handCount == 2 ? GestureTrace.orderedPair(snapshots) : snapshots

        guard usable else {
            guard phase == .recording else { return nil } // waiting just waits
            dropoutFrames += 1
            if dropoutFrames > Self.maxDropoutFrames {
                phase = .idle
                return .discarded(reason: "Lost the hand mid-take")
            }
            return nil
        }
        dropoutFrames = 0

        times.append(time)
        frames.append(frame)

        // Instantaneous motion: the largest per-dim change of the tip
        // offsets and the palm (in hand scales) against the previous
        // usable frame.
        let vector = instantVector(frame)
        let motion = lastVector.map { previous -> Double in
            var largest = 0.0
            for k in 0..<min(vector.count, previous.count) {
                largest = max(largest, abs(vector[k] - previous[k]))
            }
            return largest
        }
        lastVector = vector

        switch phase {
        case .waiting:
            // Keep only a short pre-roll while waiting, so the take starts
            // near the motion rather than at the countdown.
            while let first = times.first, time - first > 0.35 {
                times.removeFirst()
                frames.removeFirst()
            }
            if let motion, motion >= Self.motionFloor {
                phase = .recording
                stillSince = nil
                return .started
            }
            if time - armedAt >= Self.staticGrace {
                // The pose held still *is* the take: capture the buffered
                // window as a static gesture.
                phase = .idle
                return finish(at: time)
            }
            return nil

        case .recording:
            if let motion, motion < Self.motionFloor {
                if stillSince == nil { stillSince = time }
            } else {
                stillSince = nil
            }
            let ended = (stillSince.map { time - $0 >= Self.stillSeconds } ?? false)
                || (time - times[0] >= Self.maxSeconds)
            guard ended else { return nil }
            phase = .idle
            // Trim the trailing stillness — the gesture ended when the hand
            // stopped, not when the recorder noticed.
            if let stillStart = stillSince,
               let cut = times.lastIndex(where: { $0 <= stillStart }) {
                times = Array(times[...cut])
                frames = Array(frames[...cut])
            }
            return finish(at: time)

        case .idle:
            return nil
        }
    }

    private func finish(at time: TimeInterval) -> Event {
        guard frames.count >= Self.minFrames,
              (times.last ?? 0) - (times.first ?? 0) >= Self.minSeconds else {
            return .discarded(reason: "Too quick to read — try a slightly longer take")
        }
        return .finished(GestureTake(times: times, frames: frames, handCount: handCount))
    }

    /// Frame-local features for the motion measure: tip offsets plus the
    /// palm in hand scales (absolute, so palm travel registers).
    private func instantVector(_ frame: [GestureTrace.HandSnapshot]) -> [Double] {
        var vector: [Double] = []
        for snapshot in frame {
            for offset in snapshot.tipOffsets {
                vector.append(offset.x)
                vector.append(offset.y)
            }
            vector.append(snapshot.palm.x / snapshot.scale)
            vector.append(snapshot.palm.y / snapshot.scale)
        }
        return vector
    }
}

/// Turns 3–10 takes into a matchable template plus its calibration, and
/// judges whether the takes agree well enough to trust.
public enum TrainedGestureBuilder {
    public static let minTakes = 3
    public static let maxTakes = 10

    public struct Build: Equatable {
        public var template: [[Double]]
        public var duration: TimeInterval
        public var baseThreshold: Double
        /// Each take's distance to the built template, take order.
        public var takeDistances: [Double]
    }

    public enum Verdict: Equatable {
        /// Keep recording — fewer than `minTakes` so far.
        case needsMoreTakes(have: Int)
        /// One take disagrees with the rest; drop it (index) or re-record.
        case inconsistent(worstTake: Int)
        /// The takes agree; the gesture is usable.
        case ready(Build)
    }

    /// Build a template from takes: DTW-align every take to the medoid and
    /// average the aligned frames, so tempo differences between takes don't
    /// smear the shape.
    public static func build(takes: [GestureTake]) -> Build? {
        let keyframeSets = takes.map { $0.keyframes() }
        guard !keyframeSets.isEmpty, keyframeSets.allSatisfy({ !$0.isEmpty }) else { return nil }

        // Medoid: the take most like the others.
        var bestIndex = 0
        var bestSum = Double.infinity
        for i in keyframeSets.indices {
            var sum = 0.0
            for j in keyframeSets.indices where j != i {
                sum += GestureTrace.distance(keyframeSets[i], keyframeSets[j])
            }
            if sum < bestSum { bestSum = sum; bestIndex = i }
        }
        let medoid = keyframeSets[bestIndex]

        // Average: for each medoid keyframe, the mean of every frame any
        // take's DTW path aligns to it (the medoid's own frame included).
        var sums = medoid.map { $0 }
        var counts = [Double](repeating: 1, count: medoid.count)
        for (i, keyframes) in keyframeSets.enumerated() where i != bestIndex {
            for (medoidIndex, takeIndex) in alignmentPath(from: medoid, to: keyframes) {
                let frame = keyframes[takeIndex]
                for k in 0..<min(sums[medoidIndex].count, frame.count) {
                    sums[medoidIndex][k] += frame[k]
                }
                counts[medoidIndex] += 1
            }
        }
        let template = sums.enumerated().map { index, frame in
            frame.map { $0 / counts[index] }
        }

        let distances = keyframeSets.map { GestureTrace.distance(template, $0) }
        let mean = distances.reduce(0, +) / Double(distances.count)
        let variance = distances.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(distances.count)
        let std = variance.squareRoot()
        // The floor keeps a perfectly consistent trainer (or synthetic takes)
        // from calibrating a threshold nothing human could ever hit again.
        let base = max(mean + 2 * std, mean * 1.35, 0.06)

        let duration = takes.reduce(0.0) { $0 + $1.duration } / Double(takes.count)
        return Build(template: template, duration: duration,
                     baseThreshold: base, takeDistances: distances)
    }

    /// Judge the takes as a set. `inconsistent` names the take to throw out.
    public static func verdict(takes: [GestureTake]) -> Verdict {
        guard takes.count >= minTakes else { return .needsMoreTakes(have: takes.count) }
        guard let build = build(takes: takes) else { return .needsMoreTakes(have: takes.count) }
        let distances = build.takeDistances
        let sorted = distances.sorted()
        let median = sorted[sorted.count / 2]
        if let worst = distances.max(), let worstIndex = distances.firstIndex(of: worst),
           worst > max(median * 2.5, median + 0.12), worst > 0.10 {
            return .inconsistent(worstTake: worstIndex)
        }
        return .ready(build)
    }

    /// The DTW alignment path between two keyframe sequences, as
    /// (fromIndex, toIndex) pairs.
    static func alignmentPath(from a: [[Double]], to b: [[Double]],
                              band: Int = 4) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        var cost = [[Double]](repeating: [Double](repeating: .infinity, count: m + 1), count: n + 1)
        cost[0][0] = 0
        for i in 1...n {
            let lo = max(1, i - band), hi = min(m, i + band)
            guard lo <= hi else { continue }
            for j in lo...hi {
                let previous = min(cost[i - 1][j - 1], cost[i - 1][j], cost[i][j - 1])
                guard previous < .infinity else { continue }
                var sum = 0.0
                for k in 0..<min(a[i - 1].count, b[j - 1].count) {
                    let d = a[i - 1][k] - b[j - 1][k]
                    sum += d * d
                }
                cost[i][j] = previous + sum.squareRoot()
            }
        }
        var path: [(Int, Int)] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            path.append((i - 1, j - 1))
            let diagonal = cost[i - 1][j - 1], up = cost[i - 1][j], left = cost[i][j - 1]
            if diagonal <= up && diagonal <= left {
                i -= 1; j -= 1
            } else if up <= left {
                i -= 1
            } else {
                j -= 1
            }
        }
        return path.reversed()
    }
}
