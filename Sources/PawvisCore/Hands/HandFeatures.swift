import Foundation

/// Which landmark drives the on-screen cursor.
public enum PointerSource: String, Codable, CaseIterable, Sendable {
    /// Midpoint of the wrist and the middle-finger knuckle, falling back to
    /// the thumb tip (then the index tip) when the palm is occluded. The most
    /// stable choice — finger gestures barely move the palm, so the cursor
    /// holds still through clicks. Default.
    case palmCenter
    /// The thumb tip — steadier than the index during finger dips.
    case thumbTip
    /// The index fingertip. Most direct, but the cursor shifts when a finger
    /// gesture moves it.
    case indexTip
    /// Midpoint of thumb tip and index tip.
    case pinchMidpoint

    public var displayName: String {
        switch self {
        case .palmCenter: return "Palm (steady)"
        case .thumbTip: return "Thumb tip"
        case .indexTip: return "Index fingertip"
        case .pinchMidpoint: return "Pinch midpoint (thumb and index)"
        }
    }

    /// The phrase copy drops into "the cursor rides your …", so the guide
    /// and the settings captions stay honest whichever source is chosen.
    public var inlineName: String {
        switch self {
        case .palmCenter: return "palm"
        case .thumbTip: return "thumb tip"
        case .indexTip: return "index fingertip"
        case .pinchMidpoint: return "pinch midpoint"
        }
    }
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
    /// Angle-band based, so it only sees fists shown broadside — see
    /// `isClosedHand` for the orientation-proof read.
    public func isFist() -> Bool {
        Finger.allCases.allSatisfy { isCurled($0) == true }
    }

    /// The closed hand read the way foreshortening can't fake: every
    /// non-thumb tip collapsed onto the palm. A fist facing the camera —
    /// the natural thumbs-up orientation — projects its curled chains as
    /// straight lines, so the angle bands read it as anything but a fist
    /// (measured: thumb signals never engaged on real hands). Openness is
    /// the same signal the open-hand trigger uses, from the other side:
    /// a fist reads ~0.0 at any orientation, against ~0.19 for even a
    /// half-curl. The thumb is not part of `openness()`, so a thumb
    /// standing clear doesn't lift it.
    public func isClosedHand() -> Bool {
        guard let open = openness() else { return false }
        return open <= 0.15
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

    /// The loosened *hold* check for the shaka: the folded fingers may drift
    /// into the neutral band without dropping the pose — the same free
    /// hysteresis every held pose gets from the bands. The extended pair must
    /// stay positively extended.
    public func isShakaHeld() -> Bool {
        guard isThumbExtended() == true,
              isExtended(.little) == true,
              isExtended(.index) != true,
              isExtended(.middle) != true,
              isExtended(.ring) != true else { return false }
        return true
    }

    /// One fingertip's distance from the palm center, normalized by hand
    /// scale — the per-finger openness the raised wiggle watches oscillate.
    public func fingertipExtent(_ finger: Finger) -> Double? {
        guard let palm = palmCenter(), let tip = point(finger.tip) else { return nil }
        return tip.distance(to: palm) / scale
    }

    /// Projected index→little knuckle width. The one reference length that
    /// survives a hand *pointed at the camera*: the wrist→knuckle axis lies
    /// along the view direction there and `scale` collapses with it, while
    /// the knuckle line stays broadside to the lens at either orientation.
    public func knuckleSpan() -> Double? {
        guard let index = point(.indexMCP), let little = point(.littleMCP) else { return nil }
        let span = index.distance(to: little)
        return span > 1e-6 ? span : nil
    }

    /// How far a fingertip hangs below its own knuckle on screen, in
    /// knuckle-span units (+y is down, so positive = tip below the knuckle).
    /// A raised hand holds its tips far above the knuckle line (≈ −1 span);
    /// a hand pointed at the screen foreshortens the chain and the tips
    /// settle at or below it — and drumming the fingers swings this measure,
    /// which is what the pointed wiggle counts. Span-normalized because
    /// `scale` is itself foreshortened in exactly the pose this measures.
    public func fingertipDrop(_ finger: Finger) -> Double? {
        guard let span = knuckleSpan(), let tip = point(finger.tip),
              let mcp = point(finger.mcp) else { return nil }
        return (tip.y - mcp.y) / span
    }

    /// The two wiggle poses: an open hand held up with the palm to the
    /// camera, or a flat hand pointed at the screen (palm down, the desk
    /// posture). Separate *gestures*, so the classification is structural:
    /// each wiggle machine only counts motion in its own orientation.
    public enum WiggleOrientation: String, Sendable {
        case raised, pointed
    }

    /// Mean fingertip drop below this reads as the raised pose (tips well
    /// above the knuckles). Even the contracted phase of a vigorous raised
    /// wiggle keeps the tips far clear of the knuckle line.
    public static let raisedDropCeiling = -0.45
    /// Mean fingertip drop above this reads as pointed: tips at or below
    /// the knuckle line, which no upright open hand produces.
    public static let pointedDropFloor = 0.0

    /// Which wiggle pose the hand is in — nil between the bands (a tilted
    /// hand commits to neither) or when too few fingers are readable.
    /// Deliberately not an `openness()` check: a pointed hand's collapsed
    /// `scale` inflates openness unpredictably, while where the tips stand
    /// relative to the knuckle line separates the two poses at any distance.
    public func wiggleOrientation() -> WiggleOrientation? {
        let drops = Finger.allCases.compactMap { fingertipDrop($0) }
        guard drops.count >= 3 else { return nil }
        let mean = drops.reduce(0, +) / Double(drops.count)
        if mean <= Self.raisedDropCeiling { return .raised }
        if mean >= Self.pointedDropFloor { return .pointed }
        return nil
    }

    /// The direction a thumb-signal fist points its thumb, on screen: which
    /// way the thumb tip stands relative to the palm, when it stands clear
    /// (most of a hand-scale) and decisively along one axis. The axis
    /// dominance is what keeps the in-between angles of a rotating or
    /// resting thumb from counting. nil when the thumb isn't standing clear
    /// or sits between the cones.
    public enum ThumbDirection: String, CaseIterable, Sendable {
        case up, down, left, right
    }

    public func thumbDirection() -> ThumbDirection? {
        guard let palm = palmCenter(), let thumb = point(.thumbTip) else { return nil }
        let v = (thumb - palm) / scale
        guard v.length >= 0.85 else { return nil }
        if abs(v.y) >= 1.5 * abs(v.x) {
            return v.y < 0 ? .up : .down
        }
        if abs(v.x) >= 1.5 * abs(v.y) {
            return v.x < 0 ? .left : .right
        }
        return nil
    }

    /// The thumb-signal *engage* pose: a genuine fist with the thumb
    /// standing clear of it in the given direction. Strict like every
    /// engage check — but the fist may be read either way: by the angle
    /// bands (broadside) or by the collapsed tips (`isClosedHand`), because
    /// the natural thumbs-up faces its knuckles at the camera, where the
    /// angle bands are blind.
    public func isThumbSignal(_ direction: ThumbDirection) -> Bool {
        guard isFist() || isClosedHand() else { return false }
        return thumbDirection() == direction
    }

    /// The loosened *hold* check for a thumb signal: fingers may drift into
    /// the neutral band, and the thumb's cone widens a little, but no finger
    /// may re-extend and the thumb must stay clear of the palm on the same
    /// side. A knuckles-on fist projects its curled chains straight — the
    /// bands call that "extended" — so the collapsed-tips read keeps the
    /// hold alive at that orientation too.
    public func isThumbSignalHeld(_ direction: ThumbDirection) -> Bool {
        guard Finger.allCases.allSatisfy({ isExtended($0) != true }) || isClosedHand(),
              let palm = palmCenter(), let thumb = point(.thumbTip) else { return false }
        let v = (thumb - palm) / scale
        guard v.length >= 0.70 else { return false }
        switch direction {
        case .up: return v.y < 0 && abs(v.y) >= 1.1 * abs(v.x)
        case .down: return v.y > 0 && abs(v.y) >= 1.1 * abs(v.x)
        case .left: return v.x < 0 && abs(v.x) >= 1.1 * abs(v.y)
        case .right: return v.x > 0 && abs(v.x) >= 1.1 * abs(v.y)
        }
    }

    /// All five fingertips (thumb included), where tracked.
    private func trackedTips() -> [Vec2] {
        let ids: [HandJoint] = [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]
        return ids.compactMap { point($0) }
    }

    /// How tightly all five fingertips bunch: mean distance to their own
    /// centroid, normalized by hand scale. Small when the fingers gather
    /// onto the thumb — *wherever* that bunch forms, in front of the palm
    /// included — and large whenever any tip (the thumb above all) stands
    /// apart. Needs at least four tracked tips; nil otherwise.
    public func fingertipGatherSpread() -> Double? {
        let tips = trackedTips()
        guard tips.count >= 4 else { return nil }
        let center = centroid(of: tips)
        return tips.reduce(0.0) { $0 + $1.distance(to: center) } / Double(tips.count) / scale
    }

    /// The point a gathered hand is *at*: the fingertip bunch itself, falling
    /// back to the palm. The fling is tracked from here rather than the palm
    /// — a forward gather stands well away from the palm anchor, and the
    /// bunch is the part of the hand the camera actually sees.
    public func gatherPoint() -> Vec2? {
        let tips = trackedTips()
        if tips.count >= 3 { return centroid(of: tips) }
        return pointerPoint(.palmCenter)
    }

    /// The grab pose, two ways of seeing one thing (either counts):
    ///
    /// - the fingertip bunch: all five tips within `spreadLimit` of their
    ///   centroid. Orientation-proof, works for the forward gather where the
    ///   bunch stands away from the palm, and — because the thumb is one of
    ///   the five — inherently refuses every thumb-out look-alike (thumb
    ///   signals, the shaka, an open hand).
    /// - the closed fist read through `openness()`, with the thumb not
    ///   extended: covers palm-on gathers whose bunched tips Vision can't
    ///   separate well enough to measure a spread.
    ///
    /// Deliberately NOT a finger-extension or splay check: a hand gathered
    /// toward the camera projects straight finger chains (measured on real
    /// video, where an extension guard silently vetoed the real gesture).
    /// Strict engage bound; the fling's hold side uses `isGatherHeld`.
    public func isGathered(spreadLimit: Double) -> Bool {
        if let spread = fingertipGatherSpread(), spread <= spreadLimit {
            return true
        }
        if let open = openness(), open <= 0.12, isThumbExtended() == false {
            return true
        }
        return false
    }

    /// The loosened hold check for a grab in flight: fast motion blurs the
    /// fingers, so anything still well short of an open hand — by either
    /// measure — keeps the grab. Returns nil when neither measure is
    /// readable this frame (blur): the caller holds state, as everywhere.
    public func isGatherHeld(spreadLimit: Double) -> Bool? {
        let spread = fingertipGatherSpread()
        let open = openness()
        if spread == nil, open == nil { return nil }
        if let spread, spread <= spreadLimit * 1.5 { return true }
        if let open, open <= 0.35 { return true }
        return false
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
