import Foundation

/// The feature stream user-trained gestures are recorded and matched in.
///
/// Each usable camera frame reduces, per hand, to a `HandSnapshot`: the palm
/// point, the hand scale, and the five fingertip offsets from the palm in
/// hand scales. A *window* of snapshots (a training take, or a live
/// candidate) vectorizes into fixed-length frames — tip offsets plus the
/// palm's travel from the window's start — so the representation is
/// translation- and distance-invariant but still shape- and motion-aware:
/// a static pose is a flat trace, a swipe is a moving one.
///
/// Everything here is pure math on numbers already extracted from hands:
/// deterministic, clock-free, unit-testable — the same rules as the rest of
/// PawvisCore.
public enum GestureTrace {
    /// Dimensions per hand: five fingertip offsets (x, y) in hand scales,
    /// plus the palm's travel from the window start (x, y) in hand scales.
    public static let dimsPerHand = 12
    /// A two-hand frame is both hands (ordered left-to-right at the window
    /// start) plus the palm separation vector, in mean hand scales.
    public static func dims(handCount: Int) -> Int {
        handCount == 2 ? 2 * dimsPerHand + 2 : dimsPerHand
    }

    /// Keyframes a template (and every live candidate) is resampled to.
    public static let keyframes = 16

    static let tipJoints: [HandJoint] = [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]

    /// One hand, one frame, before windowing.
    public struct HandSnapshot: Equatable, Sendable {
        /// Palm point in camera space (the engine's wrist→knuckle midpoint).
        public var palm: Vec2
        /// The hand's reference scale this frame.
        public var scale: Double
        /// Fingertip offsets from the palm in hand scales — thumb, index,
        /// middle, ring, little.
        public var tipOffsets: [Vec2]

        public init(palm: Vec2, scale: Double, tipOffsets: [Vec2]) {
            self.palm = palm
            self.scale = scale
            self.tipOffsets = tipOffsets
        }
    }

    /// Read one hand into a snapshot. nil when the geometry isn't usable
    /// (no scale, or any fingertip missing) — recording skips such frames
    /// and matching holds, the house rule for unreadable geometry.
    public static func snapshot(of hand: Hand, minJointConfidence: Double) -> HandSnapshot? {
        guard let features = HandFeatures(hand: hand, minJointConfidence: minJointConfidence),
              let palm = features.pointerPoint(.palmCenter) else { return nil }
        var offsets: [Vec2] = []
        for tip in tipJoints {
            guard let point = hand.point(for: tip, minConfidence: minJointConfidence) else {
                return nil
            }
            offsets.append((point - palm) / features.scale)
        }
        return HandSnapshot(palm: palm, scale: features.scale, tipOffsets: offsets)
    }

    /// Order a two-hand frame left-to-right by palm position, so "left hand
    /// does X, right hand does Y" stays one gesture however the slots were
    /// assigned. (Mirroring the performance is a different gesture, which is
    /// what you'd expect of a trained pair.)
    public static func orderedPair(_ pair: [HandSnapshot]) -> [HandSnapshot] {
        guard pair.count == 2 else { return pair }
        return pair.sorted { $0.palm.x < $1.palm.x }
    }

    /// Vectorize a window of snapshot frames (all with the same hand count,
    /// two-hand frames already ordered). Travel is measured from the
    /// window's own first frame, normalized by that hand's median scale
    /// over the window — so the same gesture reads the same near and far.
    public static func vectorize(_ frames: [[HandSnapshot]]) -> [[Double]] {
        guard let first = frames.first, !first.isEmpty else { return [] }
        let handCount = first.count

        // Median scale per hand column, for stable travel normalization.
        var scaleRef: [Double] = []
        for hand in 0..<handCount {
            let scales = frames.compactMap { $0.count == handCount ? $0[hand].scale : nil }.sorted()
            scaleRef.append(scales.isEmpty ? 1 : scales[scales.count / 2])
        }

        return frames.compactMap { frame -> [Double]? in
            guard frame.count == handCount else { return nil }
            var vector: [Double] = []
            for hand in 0..<handCount {
                let snapshot = frame[hand]
                for offset in snapshot.tipOffsets {
                    vector.append(offset.x)
                    vector.append(offset.y)
                }
                let travel = (snapshot.palm - first[hand].palm) / scaleRef[hand]
                vector.append(travel.x)
                vector.append(travel.y)
            }
            if handCount == 2 {
                let separation = (frame[1].palm - frame[0].palm) / ((scaleRef[0] + scaleRef[1]) / 2)
                vector.append(separation.x)
                vector.append(separation.y)
            }
            return vector
        }
    }

    /// Resample a vector sequence to `count` frames, uniform in *time* —
    /// linear interpolation between neighbors, so a slow take and a quick
    /// take of the same motion land on comparable keyframes.
    public static func resample(_ vectors: [[Double]], times: [TimeInterval],
                                to count: Int) -> [[Double]] {
        guard vectors.count == times.count, let firstTime = times.first,
              let lastTime = times.last, vectors.count >= 2, count >= 2,
              lastTime > firstTime else {
            return vectors.isEmpty ? [] : Array(repeating: vectors[0], count: max(count, 1))
        }
        var result: [[Double]] = []
        result.reserveCapacity(count)
        var cursor = 0
        for i in 0..<count {
            let t = firstTime + (lastTime - firstTime) * Double(i) / Double(count - 1)
            while cursor + 1 < times.count - 1 && times[cursor + 1] < t { cursor += 1 }
            let t0 = times[cursor], t1 = times[cursor + 1]
            let f = t1 > t0 ? min(max((t - t0) / (t1 - t0), 0), 1) : 0
            let a = vectors[cursor], b = vectors[cursor + 1]
            result.append((0..<min(a.count, b.count)).map { a[$0] + (b[$0] - a[$0]) * f })
        }
        return result
    }

    /// Dynamic-time-warping distance between two vector sequences: mean
    /// per-step Euclidean distance along the best alignment path, inside a
    /// Sakoe-Chiba band. Both sequences are expected at `keyframes` length;
    /// the mean (not the sum) keeps the number comparable across lengths.
    public static func distance(_ a: [[Double]], _ b: [[Double]], band: Int = 4) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return .infinity }
        let n = a.count, m = b.count
        var cost = [[Double]](repeating: [Double](repeating: .infinity, count: m + 1), count: n + 1)
        var steps = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        cost[0][0] = 0

        for i in 1...n {
            let lo = max(1, i - band), hi = min(m, i + band)
            guard lo <= hi else { continue }
            for j in lo...hi {
                let d = euclidean(a[i - 1], b[j - 1])
                var best = cost[i - 1][j - 1]
                var from = (i - 1, j - 1)
                if cost[i - 1][j] < best { best = cost[i - 1][j]; from = (i - 1, j) }
                if cost[i][j - 1] < best { best = cost[i][j - 1]; from = (i, j - 1) }
                guard best < .infinity else { continue }
                cost[i][j] = best + d
                steps[i][j] = steps[from.0][from.1] + 1
            }
        }
        let total = cost[n][m]
        guard total < .infinity, steps[n][m] > 0 else { return .infinity }
        return total / Double(steps[n][m])
    }

    private static func euclidean(_ a: [Double], _ b: [Double]) -> Double {
        var sum = 0.0
        for k in 0..<min(a.count, b.count) {
            let d = a[k] - b[k]
            sum += d * d
        }
        return sum.squareRoot()
    }

    /// Decode a template keyframe back into drawable geometry — the palm's
    /// travel point and the five fingertips around it — for the animated
    /// badge and the trainer's replay. Inverse of `vectorize`'s layout.
    public static func handPoints(in vector: [Double], hand: Int, handCount: Int)
        -> (palmTravel: Vec2, tips: [Vec2])? {
        let base = hand * dimsPerHand
        guard hand < handCount, vector.count >= base + dimsPerHand else { return nil }
        let tips = (0..<5).map { i in
            Vec2(vector[base + i * 2], vector[base + i * 2 + 1])
        }
        let travel = Vec2(vector[base + 10], vector[base + 11])
        return (travel, tips)
    }
}
