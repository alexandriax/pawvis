import Foundation

/// Which landmark drives the on-screen cursor.
public enum PointerSource: String, Codable, CaseIterable, Sendable {
    /// Centroid of the wrist + knuckles, falling back to the thumb tip when the
    /// palm is occluded. The most stable choice — pinching moves the fingers
    /// but not the palm, so the cursor holds still through clicks. Default.
    case palmCenter
    /// The thumb tip — steadier than the index during pinches.
    case thumbTip
    /// The index fingertip. Most direct, but the cursor shifts when you pinch.
    case indexTip
    /// Midpoint of thumb tip and index tip.
    case pinchMidpoint
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
    /// The open-hand trigger pose additionally requires `openness()` to reach
    /// this. The PIP-angle bands alone cannot see fingers curled *toward* the
    /// camera — their 2D projection stays a straight chain while the tips
    /// collapse onto the palm — so a closed hand facing the lens read as
    /// "open" and armed cursor control. The tips standing well off the palm
    /// is the signal foreshortening can't fake. Raised and lowered by the
    /// open-hand strictness slider.
    ///
    /// The default sits low in the slider's range on purpose: field testing
    /// found the original 0.40 turned away hands that plainly read as open —
    /// a hand held slightly off-axis, or fingers relaxed rather than posed —
    /// and asking for a stiffer hand is worse than the misfires it prevented.
    /// The floor still clears every closed pose by a wide margin: a half-curl
    /// reads ~0.19 and a hand curled toward the camera reads 0.0, against
    /// ~0.50 for a relaxed open hand.
    public var openHandMinOpenness: Double = 0.29

    /// The floor that shipped before that retune. A stored value of exactly
    /// this is the old default with the slider never touched — the slider is
    /// continuous, so a hand-dragged setting lands on a long decimal, never on
    /// the round number.
    public static let retiredOpenHandMinOpenness = 0.40

    /// Follows the retuned default down, but only for settings still sitting
    /// on the retired floor. A strictness the user dialed themselves is left
    /// exactly where they put it.
    public mutating func adoptRetunedOpenHandFloor() {
        if openHandMinOpenness == Self.retiredOpenHandMinOpenness {
            openHandMinOpenness = PoseThresholds().openHandMinOpenness
        }
    }

    public init() {}

    enum CodingKeys: String, CodingKey {
        case extendedAngle, curledAngle, thumbExtendedRatio, splayRatio
        case openHandMinOpenness
    }

    /// Field-tolerant decoding, as `GestureConfig`: settings saved before a
    /// threshold existed keep its default instead of resetting the others.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(Double.self, forKey: .extendedAngle) { extendedAngle = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .curledAngle) { curledAngle = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .thumbExtendedRatio) { thumbExtendedRatio = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .splayRatio) { splayRatio = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .openHandMinOpenness) { openHandMinOpenness = v }
    }
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

    /// Thumb-tip→index-knuckle distance, normalized by hand scale: low means
    /// the thumb is tucked across the palm. `isThumbExtended()` thresholds this
    /// same quantity.
    public func thumbCurlRatio() -> Double? {
        guard let thumbTip = point(.thumbTip), let indexMCP = point(.indexMCP) else { return nil }
        return thumbTip.distance(to: indexMCP) / scale
    }

    /// The neighbor each finger's dip is measured against. Pinned pairs, and
    /// the reason two fingers can drive two different buttons: a *reference*
    /// finger dipping can only push the ratio up, away from engagement, and a
    /// finger that is neither the subject nor its reference doesn't move it at
    /// all. So no dip can ever trip another finger's button.
    public static func tapReference(for finger: Finger) -> Finger {
        switch finger {
        case .index: return .middle
        case .middle: return .index
        case .ring: return .middle
        case .little: return .ring
        }
    }

    /// The mouse-button measure: how far a finger has dipped RELATIVE to its
    /// reference neighbor, folded into a low-when-tapped ratio:
    ///   1 + (fingerExtent − referenceExtent)
    /// where extent = tip→own-knuckle distance / hand scale. Idles near 1.0
    /// with both fingers up; dips to ~0.5 when the finger taps down (flexion
    /// foreshortens its projected extent). Differencing against a neighbor
    /// cancels whole-hand tilt — only the finger moving *relative to that
    /// neighbor* reads as a tap, like a finger on a physical mouse button.
    public func fingerTapRatio(_ finger: Finger) -> Double? {
        let reference = Self.tapReference(for: finger)
        guard let tip = point(finger.tip), let mcp = point(finger.mcp),
              let referenceTip = point(reference.tip), let referenceMCP = point(reference.mcp) else {
            return nil
        }
        let extent = tip.distance(to: mcp) / scale
        let referenceExtent = referenceTip.distance(to: referenceMCP) / scale
        return 1 + (extent - referenceExtent)
    }

    /// The index finger's tap ratio — the left button in `.indexTap` mode.
    public func indexTapRatio() -> Double? {
        fingerTapRatio(.index)
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
        thumbCurlRatio().map { $0 > thresholds.thumbExtendedRatio }
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

    /// The control-trigger pose: every non-thumb finger extended, with the
    /// tips standing at least `openHandMinOpenness` off the palm. The thumb is
    /// deliberately ignored — the thumb-curl click keeps all four fingers up
    /// while the thumb tucks, and that must still read as "open". A finger
    /// whose joints are missing counts as not extended, so a half-tracked
    /// hand can't arm cursor control.
    ///
    /// The openness floor is the second, independent signal: the angle bands
    /// judge each finger's projected shape, which foreshortening fakes
    /// (fingers curled toward the camera project as straight chains), while
    /// `openness()` measures how far the tips actually stand from the palm —
    /// which a curled hand can't fake at any orientation.
    public func isOpenHand() -> Bool {
        guard Finger.allCases.allSatisfy({ isExtended($0) == true }) else { return false }
        guard let open = openness() else { return false }
        return open >= thresholds.openHandMinOpenness
    }

    /// How many fingers are genuinely curled — the disarm side of the control
    /// trigger reads 3+ as a deliberately closed hand. The neutral band
    /// between curled and extended counts for neither pose, which gives the
    /// trigger hysteresis for free: a relaxed half-curl neither arms nor
    /// disarms.
    public func curledFingerCount() -> Int {
        Finger.allCases.filter { isCurled($0) == true }.count
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

    /// Index + little extended, middle + ring folded in — the scroll pose.
    /// Strict on purpose: the folded fingers must read genuinely curled, so
    /// this is the *engage* check. The thumb is ignored — the pose is
    /// comfortable with it out or tucked.
    public func isScrollPose() -> Bool {
        guard isExtended(.index) == true,
              isExtended(.little) == true,
              isCurled(.middle) == true,
              isCurled(.ring) == true else { return false }
        return true
    }

    /// The loosened *hold* check for the scroll pose: the folded fingers may
    /// drift into the neutral band between curled and extended without ending
    /// the scroll — the same free hysteresis the control trigger gets from
    /// the pose bands. (A folded finger whose joints go missing counts as
    /// still folded; the extended fingers must stay positively extended.)
    public func isScrollPoseHeld() -> Bool {
        guard isExtended(.index) == true,
              isExtended(.little) == true,
              isExtended(.middle) != true,
              isExtended(.ring) != true else { return false }
        return true
    }

    // MARK: - Pointer

    /// The point that drives the cursor, per the configured source.
    public func pointerPoint(_ source: PointerSource) -> Vec2? {
        switch source {
        case .indexTip:
            return point(.indexTip)
        case .thumbTip:
            return point(.thumbTip) ?? point(.indexTip)
        case .pinchMidpoint:
            if let thumb = point(.thumbTip), let index = point(.indexTip) {
                return thumb.midpoint(with: index)
            }
            return point(.indexTip)
        case .palmCenter:
            // Palm if we can see it, otherwise thumb, otherwise index — "track
            // the palm if possible, else the thumb".
            //
            // Anchor on the wrist→middle-knuckle midpoint rather than a
            // centroid of whichever palm joints happen to clear the confidence
            // floor this frame: a variable-membership centroid shifts by
            // several percent of the screen whenever a joint drops out, which
            // reads as the cursor jumping around.
            if let wrist = point(.wrist), let middleMCP = point(.middleMCP) {
                return wrist.midpoint(with: middleMCP)
            }
            return point(.thumbTip) ?? point(.indexTip)
        }
    }
}
