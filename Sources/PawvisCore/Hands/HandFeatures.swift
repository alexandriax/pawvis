import Foundation

/// Which landmark drives the on-screen cursor.
public enum PointerSource: String, Codable, CaseIterable, Sendable {
    /// The index fingertip. Most direct, but the cursor shifts when you pinch.
    case indexTip
    /// Midpoint of thumb tip and index tip. Stays put while pinching, so clicks
    /// land where you aimed. Default.
    case pinchMidpoint
    /// Centroid of the four knuckles — most stable, least precise.
    case palmCenter
}

/// Tunable thresholds for pose classification.
public struct PoseThresholds: Codable, Equatable, Sendable {
    /// A finger counts as extended when the angle at its PIP joint (between the
    /// knuckle and the fingertip) exceeds this, in radians. π = dead straight.
    public var extendedAngle: Double = 2.15
    /// A finger counts as curled when the PIP angle is below this. Between the
    /// two thresholds a finger is "neutral" — neither pose claims it.
    public var curledAngle: Double = 1.75
    /// Thumb counts as extended when distance(thumbTip, indexMCP) / handScale
    /// exceeds this ratio.
    public var thumbExtendedRatio: Double = 0.50
    /// Open-palm splay requires the mean gap between adjacent fingertips,
    /// normalized by hand scale, to exceed this.
    public var splayRatio: Double = 0.25

    public init() {}
}

/// Derived geometry for one hand: scale-normalized distances, finger extension,
/// and pose classification. All methods return nil when the joints they need
/// are missing or below the confidence floor.
public struct HandFeatures {
    public let hand: Hand
    /// Reference length used to normalize distances: wrist → middle knuckle,
    /// falling back to the knuckle span when the wrist is occluded.
    public let scale: Double

    private let minConf: Double
    private let thresholds: PoseThresholds

    public init?(hand: Hand, thresholds: PoseThresholds = PoseThresholds(), minJointConfidence: Double = 0.0) {
        self.hand = hand
        self.thresholds = thresholds
        self.minConf = minJointConfidence

        if let wrist = hand.point(for: .wrist, minConfidence: minJointConfidence),
           let middleMCP = hand.point(for: .middleMCP, minConfidence: minJointConfidence),
           wrist.distance(to: middleMCP) > 1e-6 {
            self.scale = wrist.distance(to: middleMCP)
        } else if let indexMCP = hand.point(for: .indexMCP, minConfidence: minJointConfidence),
                  let littleMCP = hand.point(for: .littleMCP, minConfidence: minJointConfidence),
                  indexMCP.distance(to: littleMCP) > 1e-6 {
            // Knuckle span is ~0.7× the wrist→middleMCP length; rescale to match.
            self.scale = indexMCP.distance(to: littleMCP) / 0.7
        } else {
            return nil
        }
    }

    private func point(_ joint: HandJoint) -> Vec2? {
        hand.point(for: joint, minConfidence: minConf)
    }

    // MARK: - Pinch

    /// Distance between the thumb tip and the given fingertip, normalized by
    /// hand scale so it is invariant to distance from the camera.
    public func pinchRatio(to finger: Finger) -> Double? {
        guard let thumb = point(.thumbTip), let tip = point(finger.tip) else { return nil }
        return thumb.distance(to: tip) / scale
    }

    /// Midpoint of the thumb tip and given fingertip (where a pinch "grabs").
    public func pinchPoint(with finger: Finger) -> Vec2? {
        guard let thumb = point(.thumbTip), let tip = point(finger.tip) else { return nil }
        return thumb.midpoint(with: tip)
    }

    // MARK: - Finger extension

    /// Angle at the PIP joint; π means dead straight.
    public func pipAngle(of finger: Finger) -> Double? {
        guard let mcp = point(finger.mcp), let pip = point(finger.pip), let tip = point(finger.tip) else {
            return nil
        }
        return Vec2.angle(at: pip, from: mcp, to: tip)
    }

    public func isExtended(_ finger: Finger) -> Bool? {
        pipAngle(of: finger).map { $0 > thresholds.extendedAngle }
    }

    public func isCurled(_ finger: Finger) -> Bool? {
        pipAngle(of: finger).map { $0 < thresholds.curledAngle }
    }

    public func isThumbExtended() -> Bool? {
        guard let thumbTip = point(.thumbTip), let indexMCP = point(.indexMCP) else { return nil }
        return thumbTip.distance(to: indexMCP) / scale > thresholds.thumbExtendedRatio
    }

    // MARK: - Poses

    /// Palm center: mean of wrist + the four finger knuckles.
    public func palmCenter() -> Vec2? {
        let ids: [HandJoint] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        let pts = ids.compactMap { point($0) }
        guard pts.count >= 3 else { return nil }
        return centroid(of: pts)
    }

    /// Continuous open-hand measure in [0, 1]: 0 ≈ closed fist, 1 ≈ fully open
    /// palm. Ported from sporecaster: mean fingertip→palm distance over the four
    /// non-thumb tips, normalized by hand scale, calibrated fist ≈ 0.75 and open
    /// palm ≈ 1.55 in those units.
    public func openness() -> Double? {
        guard let palm = palmCenter() else { return nil }
        let tips: [HandJoint] = [.indexTip, .middleTip, .ringTip, .littleTip]
        let pts = tips.compactMap { point($0) }
        guard pts.count == 4 else { return nil }
        let mean = pts.reduce(0.0) { $0 + $1.distance(to: palm) } / 4 / scale
        let lo = 0.75, hi = 1.55
        return min(max((mean - lo) / (hi - lo), 0), 1)
    }

    /// Mean gap between adjacent fingertips (index↔middle, middle↔ring,
    /// ring↔little), normalized by hand scale. High when fingers are splayed.
    public func splayAmount() -> Double? {
        guard let i = point(.indexTip), let m = point(.middleTip),
              let r = point(.ringTip), let l = point(.littleTip) else { return nil }
        let mean = (i.distance(to: m) + m.distance(to: r) + r.distance(to: l)) / 3
        return mean / scale
    }

    /// All five fingers extended and spread wide.
    public func isOpenPalmSplayed() -> Bool {
        guard isThumbExtended() == true,
              Finger.allCases.allSatisfy({ isExtended($0) == true }),
              let splay = splayAmount() else { return false }
        return splay > thresholds.splayRatio
    }

    /// All four fingers genuinely curled (tight hand). The neutral band between
    /// curled and extended keeps a relaxed hand from reading as a fist.
    public func isFist() -> Bool {
        Finger.allCases.allSatisfy { isCurled($0) == true }
    }

    /// Thumb + little finger extended, middle three folded ("shaka" / hang loose).
    public func isShaka() -> Bool {
        guard isThumbExtended() == true,
              isExtended(.little) == true,
              isExtended(.index) == false,
              isExtended(.middle) == false,
              isExtended(.ring) == false else { return false }
        return true
    }

    /// Index + middle extended, ring + little folded — the scroll pose.
    public func isTwoFingerPoint() -> Bool {
        guard isExtended(.index) == true,
              isExtended(.middle) == true,
              isExtended(.ring) == false,
              isExtended(.little) == false else { return false }
        return true
    }

    // MARK: - Pointer

    /// The point that drives the cursor, per the configured source.
    public func pointerPoint(_ source: PointerSource) -> Vec2? {
        switch source {
        case .indexTip:
            return point(.indexTip)
        case .pinchMidpoint:
            if let thumb = point(.thumbTip), let index = point(.indexTip) {
                return thumb.midpoint(with: index)
            }
            return point(.indexTip)
        case .palmCenter:
            let mcps = [HandJoint.indexMCP, .middleMCP, .ringMCP, .littleMCP].compactMap { point($0) }
            guard !mcps.isEmpty else { return nil }
            return centroid(of: mcps)
        }
    }
}
