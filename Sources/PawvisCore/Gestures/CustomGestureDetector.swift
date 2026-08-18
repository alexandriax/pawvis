import Foundation

/// Detects the bindable one-shot gestures (`CustomGesture`) in the same
/// tracked, screen-space hand stream the engine's built-in gestures run on.
/// Deterministic and clock-free like everything else in PawvisCore: all
/// timing comes from frame timestamps.
///
/// Every family follows the house state-machine shape — strict engage, loose
/// hold, debounce, and an explicit story for presses: nothing here may fire
/// while a button is down or a scroll is active, and the grab family
/// additionally stands down while the criss-cross wave is engaged. Missing
/// joints hold state rather than flapping it.
///
/// Detection runs armed or parked — like the criss-cross wave, a bound
/// command must not require cursor control. Only gestures in
/// `Config.enabled` are watched at all; an empty set makes `process` free.
public final class CustomGestureDetector {

    /// Distilled from `CustomGestureSettings` (the bindings choose `enabled`,
    /// the tuning sliders choose the thresholds). Changing it resets all
    /// in-flight detection state.
    public struct Config: Equatable, Sendable {
        /// The gestures with a live binding. Everything else is ignored.
        public var enabled: Set<CustomGesture> = []
        /// Per-finger direction reversals within the window that count as
        /// wiggling.
        public var wiggleReversals: Int = 3
        /// How long a held pose (thumbs, shaka) must dwell before firing.
        public var holdSeconds: TimeInterval = 0.35
        /// Screen-normalized displacement that completes a grab & fling.
        public var flingTravel: Double = 0.16
        /// How tightly the fingertips must bunch to read as a grab: mean tip
        /// distance to the bunch's own center, in hand scales. Larger =
        /// a looser bunch counts.
        public var gatherSpread: Double = 0.32

        public init() {}
    }

    /// Everything the detector needs to read one frame, taken from the
    /// engine's own config so the two can never disagree mid-stream.
    public struct Context {
        public var time: TimeInterval
        public var thresholds: PoseThresholds
        public var minJointConfidence: Double
        public var trackingLossGrace: TimeInterval
        /// A button is engaged/held or a scroll is active: every family
        /// resets — presses always win.
        public var pressOrScrollActive: Bool
        /// The criss-cross wave is engaged: the grab family resets; the
        /// in-place families keep running.
        public var crissCrossEngaged: Bool

        public init(time: TimeInterval, thresholds: PoseThresholds,
                    minJointConfidence: Double, trackingLossGrace: TimeInterval,
                    pressOrScrollActive: Bool, crissCrossEngaged: Bool) {
            self.time = time
            self.thresholds = thresholds
            self.minJointConfidence = minJointConfidence
            self.trackingLossGrace = trackingLossGrace
            self.pressOrScrollActive = pressOrScrollActive
            self.crissCrossEngaged = crissCrossEngaged
        }
    }

    /// One tracked hand, by the engine's persistent slot identity.
    public struct HandInput {
        public var slot: Int
        public var hand: Hand

        public init(slot: Int, hand: Hand) {
            self.slot = slot
            self.hand = hand
        }
    }

    public var config: Config {
        didSet { if config != oldValue { reset() } }
    }

    public init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - Tuning constants

    /// Engage-grade joint confidence for strict pose checks, matching the
    /// engine's `engageConfidenceFloor`: guessed joints must not start things.
    private static let engageConfidenceFloor = 0.40

    /// Wiggle: reversals older than this fall out of the count.
    private static let wiggleWindow: TimeInterval = 1.2
    /// Raised wiggle: extent change (in hand scales) that counts as a finger
    /// moving; smaller is landmark shimmer.
    private static let wiggleNoiseFloor = 0.045
    /// Pointed wiggle: fingertip-drop change (in knuckle-span units) that
    /// counts as a finger drumming. Its own floor because the two measures
    /// have different units — and the pointed pose's landmarks shimmer more,
    /// with the fingers foreshortened toward the lens.
    private static let pointedWiggleNoiseFloor = 0.10
    /// Consecutive frames of the *opposite* orientation before the machine
    /// switches poses (and restarts its buffers): the drop measure sweeps
    /// through both bands during vigorous curls, and one frame of the other
    /// pose must not throw away an in-flight wiggle.
    private static let wiggleOrientationFrames = 4
    /// The palm may drift this far (screen-normalized) while wiggling; more
    /// means the hand is travelling, not wiggling in place.
    private static let wigglePalmStill = 0.10
    /// Openness below which the hand reads as closed. Debounced by
    /// `wiggleClosedFrames` before clearing: a vigorous wiggle legitimately
    /// dips through this for a frame or two at the bottom of each curl.
    private static let wiggleOpennessFloor = 0.12
    /// Consecutive closed frames before the buffers clear (a resting fist
    /// sits below the floor indefinitely and never accumulates).
    private static let wiggleClosedFrames = 4
    /// Fingers that must each reach the reversal count.
    private static let wiggleMinFingers = 3
    /// How long a one-hand candidate waits for the partner hand.
    private static let wigglePairWindow: TimeInterval = 0.35
    private static let wiggleRefractory: TimeInterval = 1.5

    /// Held poses: consecutive frames outside the loose hold before the pose
    /// resets (missing joints read as "not held", so this doubles as the
    /// dropout tolerance).
    private static let holdExitFrames = 4
    private static let holdRefractory: TimeInterval = 0.8

    /// Grab & fling: consecutive gathered frames to engage.
    private static let flingEngageFrames = 2
    /// The gather point must be no faster than this (screen-normalized per
    /// second) while gathering. A real grab closes from rest and *then*
    /// flings; a relaxed closed hand travelling through the frame closes
    /// mid-flight — the measured false-fling on real video.
    private static let flingEngageMaxSpeed = 0.6
    /// The hand must have been open within this long of gathering — the
    /// open→gathered transition is what makes a grab deliberate; a hand
    /// that was simply resting closed can never fling.
    private static let flingOpenWindow: TimeInterval = 1.0
    /// Consecutive positively-ungathered frames that release a grab.
    private static let flingReleaseFrames = 2
    /// An engaged grab that goes nowhere for this long lets go on its own,
    /// so a closed hand can't park the cursor forever (the criss-cross
    /// stall's idea).
    private static let flingStallTimeout: TimeInterval = 2.0
    /// Fraction of the fling distance below which the grab counts as stalled.
    private static let flingStallFraction = 0.3
    private static let flingRefractory: TimeInterval = 0.6

    // MARK: - State

    private struct WiggleState {
        /// Which wiggle this hand is performing — adopted from the first
        /// confident pose read, switched only after a debounced run of the
        /// opposite pose. The buffers below are in this orientation's units.
        var orientation: HandFeatures.WiggleOrientation?
        var switchFrames = 0
        var lastExtent: [Double?] = Array(repeating: nil, count: Finger.allCases.count)
        var lastSign: [Int] = Array(repeating: 0, count: Finger.allCases.count)
        var reversals: [[TimeInterval]] = Array(repeating: [], count: Finger.allCases.count)
        var palmOrigin: Vec2?
        var closedFrames = 0
        var satisfiedAt: TimeInterval = -.infinity
        var pendingAt: TimeInterval = -.infinity

        /// The gestures this state's orientation fires.
        var singleGesture: CustomGesture {
            orientation == .pointed ? .pointedWiggle : .fingerWiggle
        }
        var twoHandGesture: CustomGesture {
            orientation == .pointed ? .twoHandPointedWiggle : .twoHandFingerWiggle
        }

        mutating func clearMotion() {
            lastExtent = Array(repeating: nil, count: Finger.allCases.count)
            lastSign = Array(repeating: 0, count: Finger.allCases.count)
            reversals = Array(repeating: [], count: Finger.allCases.count)
            palmOrigin = nil
            closedFrames = 0
        }
    }

    private struct HoldState {
        var gesture: CustomGesture?
        var start: TimeInterval = 0
        var fired = false
        var exitFrames = 0
    }

    private struct GrabState {
        var lastOpenTime: TimeInterval = -.infinity
        var openFrames = 0
        var lastPoint: Vec2?
        var lastTime: TimeInterval = -.infinity
        var gatherFrames = 0
        var active = false
        var anchor: Vec2 = .zero
        var activeSince: TimeInterval = 0
        var fired = false
        var releaseFrames = 0
    }

    private struct SlotState {
        var lastSeen: TimeInterval = -.infinity
        var wiggle = WiggleState()
        var hold = HoldState()
        var grab = GrabState()
    }

    private var slots: [Int: SlotState] = [:]
    private var lastFire: [CustomGesture.Family: TimeInterval] = [:]

    /// Slots currently holding an engaged grab. The engine parks the cursor
    /// while the primary slot is in here — a fling must not drag the cursor
    /// across the screen on its way out (the scroll park's idea).
    public private(set) var grabbingSlots: Set<Int> = []

    /// The hold pose currently dwelling toward its fire (a thumb signal,
    /// the shaka), with the seconds left to hold. Recomputed every
    /// `process` call; nil when nothing is dwelling. The app layer reads
    /// this for the countdown pill — a pose you must hold for a beat is
    /// invisible until it fires, and invisible reads as broken.
    public private(set) var holdProgress: (gesture: CustomGesture, remaining: TimeInterval)?

    public func reset() {
        slots = [:]
        lastFire = [:]
        grabbingSlots = []
        holdProgress = nil
    }

    // MARK: - Per-frame entry

    /// Feed one frame. Returns the gestures that completed on it (usually
    /// none). Safe — and cheap — to call with no hands: pending decisions
    /// still time out and stale slots still expire.
    public func process(hands: [HandInput], context: Context) -> [CustomGesture] {
        guard !config.enabled.isEmpty else {
            if !slots.isEmpty || !grabbingSlots.isEmpty { reset() }
            return []
        }

        var fired: [CustomGesture] = []
        let families = Set(config.enabled.map(\.family))

        // Stale slots expire through the same grace the engine's slots use.
        for (slot, state) in slots
        where !hands.contains(where: { $0.slot == slot })
            && context.time - state.lastSeen > context.trackingLossGrace {
            slots.removeValue(forKey: slot)
            grabbingSlots.remove(slot)
        }

        // Pending one-vs-two-hand decisions resolve before new candidates.
        if families.contains(.wiggle) {
            resolveExpiredWigglePendings(at: context.time, fired: &fired)
        }

        for input in hands {
            var state = slots[input.slot] ?? SlotState()
            state.lastSeen = context.time

            let strict = HandFeatures(
                hand: input.hand, thresholds: context.thresholds,
                minJointConfidence: max(context.minJointConfidence, Self.engageConfidenceFloor))
            let loose = HandFeatures(
                hand: input.hand, thresholds: context.thresholds,
                minJointConfidence: context.minJointConfidence)

            if context.pressOrScrollActive {
                // A press always wins: every family resets outright. That
                // includes a wiggle's parked one-vs-two-hand decision —
                // clearMotion() only wipes the motion buffers, not
                // pendingAt/satisfiedAt, so without this a decision parked
                // just before the press would still resolve (and fire)
                // once the pair window elapsed, press or no press. A press
                // is a change of intent: a wiggle satisfied before it must
                // not fire during it, or after it either.
                state.wiggle.clearMotion()
                state.wiggle.pendingAt = -.infinity
                state.wiggle.satisfiedAt = -.infinity
                state.hold = HoldState()
                state.grab = GrabState()
                grabbingSlots.remove(input.slot)
            } else {
                if families.contains(.wiggle) {
                    updateWiggle(&state.wiggle, slot: input.slot, loose: loose,
                                 at: context.time, fired: &fired)
                }
                if families.contains(.holdPose) {
                    updateHold(&state.hold, strict: strict, loose: loose,
                               at: context.time, fired: &fired)
                }
                if families.contains(.grabFling) {
                    if context.crissCrossEngaged {
                        state.grab = GrabState()
                        grabbingSlots.remove(input.slot)
                    } else {
                        updateGrab(&state.grab, slot: input.slot, loose: loose,
                                   at: context.time, fired: &fired)
                    }
                }
            }

            slots[input.slot] = state
        }

        // The dwell in progress, if any — the one furthest along when both
        // hands are somehow holding poses at once.
        holdProgress = slots.values
            .compactMap { state -> (CustomGesture, TimeInterval)? in
                guard let gesture = state.hold.gesture, !state.hold.fired else { return nil }
                return (gesture, max(0, config.holdSeconds - (context.time - state.hold.start)))
            }
            .min { $0.1 < $1.1 }

        return fired
    }

    // MARK: - Firing

    private func refractory(for family: CustomGesture.Family) -> TimeInterval {
        switch family {
        case .wiggle: return Self.wiggleRefractory
        case .holdPose: return Self.holdRefractory
        case .grabFling: return Self.flingRefractory
        }
    }

    /// One gate for every fire: the gesture must be enabled and its family
    /// out of refractory. Firing starts the next refractory.
    private func fire(_ gesture: CustomGesture, at time: TimeInterval,
                      into fired: inout [CustomGesture]) -> Bool {
        guard config.enabled.contains(gesture) else { return false }
        let last = lastFire[gesture.family] ?? -.infinity
        guard time - last >= refractory(for: gesture.family) else { return false }
        lastFire[gesture.family] = time
        fired.append(gesture)
        return true
    }

    // MARK: - Wiggle

    private func updateWiggle(_ wiggle: inout WiggleState, slot: Int,
                              loose: HandFeatures?, at time: TimeInterval,
                              fired: inout [CustomGesture]) {
        // Inside the refractory the buffers stay empty, so a long wiggle
        // fires once, not once per window.
        if time - (lastFire[.wiggle] ?? -.infinity) < Self.wiggleRefractory {
            wiggle.clearMotion()
            return
        }
        guard let loose else { return } // missing hand geometry holds state

        // Raised or pointed decides which measure the buffers count and
        // which gestures a satisfied wiggle fires. Switching poses restarts
        // the buffers, so the two measures (different units) never mix and
        // a wiggle begun raised can never finish as a pointed one. A frame
        // of the *opposite* pose feeds neither machine — the old one must
        // not count the wild measure swing of the pose change itself, and
        // the new one hasn't been confirmed yet.
        var opposedFrame = false
        if let seen = loose.wiggleOrientation() {
            if wiggle.orientation == nil {
                wiggle.orientation = seen
            } else if seen != wiggle.orientation {
                wiggle.switchFrames += 1
                if wiggle.switchFrames >= Self.wiggleOrientationFrames {
                    wiggle.clearMotion()
                    wiggle.orientation = seen
                    wiggle.switchFrames = 0
                } else {
                    opposedFrame = true
                }
            } else {
                wiggle.switchFrames = 0
            }
        }
        // A hand that never commits to either pose doesn't wiggle at all.
        guard let orientation = wiggle.orientation, !opposedFrame else { return }

        if orientation == .raised {
            // The resting-fist clear is a raised-pose idea: a pointed hand's
            // openness rides the collapsed hand scale and means nothing.
            guard let openness = loose.openness() else { return }
            if openness < Self.wiggleOpennessFloor {
                wiggle.closedFrames += 1
                if wiggle.closedFrames >= Self.wiggleClosedFrames {
                    wiggle.clearMotion()
                    return
                }
            } else {
                wiggle.closedFrames = 0
            }
        }
        if let palm = loose.pointerPoint(.palmCenter) {
            if let origin = wiggle.palmOrigin, palm.distance(to: origin) > Self.wigglePalmStill {
                // The hand is travelling, not wiggling in place.
                wiggle.clearMotion()
                wiggle.palmOrigin = palm
            } else if wiggle.palmOrigin == nil {
                wiggle.palmOrigin = palm
            }
        }

        let noiseFloor = orientation == .pointed
            ? Self.pointedWiggleNoiseFloor : Self.wiggleNoiseFloor
        for (i, finger) in Finger.allCases.enumerated() {
            let measure = orientation == .pointed
                ? loose.fingertipDrop(finger) : loose.fingertipExtent(finger)
            guard let measure else { continue }
            guard let last = wiggle.lastExtent[i] else {
                wiggle.lastExtent[i] = measure
                continue
            }
            let delta = measure - last
            guard abs(delta) >= noiseFloor else { continue }
            let sign = delta > 0 ? 1 : -1
            if wiggle.lastSign[i] != 0, sign != wiggle.lastSign[i] {
                wiggle.reversals[i].append(time)
            }
            wiggle.lastSign[i] = sign
            wiggle.lastExtent[i] = measure
        }
        for i in wiggle.reversals.indices {
            wiggle.reversals[i].removeAll { time - $0 > Self.wiggleWindow }
        }

        let wigglingFingers = wiggle.reversals.filter { $0.count >= max(config.wiggleReversals, 1) }.count
        guard wigglingFingers >= Self.wiggleMinFingers else { return }
        wiggle.satisfiedAt = time

        guard config.enabled.contains(wiggle.twoHandGesture) else {
            if fire(wiggle.singleGesture, at: time, into: &fired) {
                wiggle.clearMotion()
                clearPartnerWiggle(of: slot)
            }
            return
        }
        // Two-hand version is bound: fire it the moment both hands are
        // wiggling the same way; a lone hand waits out the pair window first.
        if let partner = partnerWiggle(of: slot, matching: orientation),
           time - partner.state.satisfiedAt <= Self.wigglePairWindow {
            if fire(wiggle.twoHandGesture, at: time, into: &fired) {
                wiggle.clearMotion()
                clearPartnerWiggle(of: slot)
            }
            return
        }
        if wiggle.pendingAt == -.infinity || time - wiggle.pendingAt > Self.wigglePairWindow {
            wiggle.pendingAt = time
        }
    }

    /// The other slot's wiggle, but only in the same orientation: a raised
    /// hand and a pointed hand wiggling together are two different gestures
    /// happening at once, not a pair.
    private func partnerWiggle(of slot: Int,
                               matching orientation: HandFeatures.WiggleOrientation)
        -> (slot: Int, state: WiggleState)? {
        for (other, state) in slots
        where other != slot && state.wiggle.orientation == orientation {
            return (other, state.wiggle)
        }
        return nil
    }

    private func clearPartnerWiggle(of slot: Int) {
        for (other, var state) in slots where other != slot {
            state.wiggle.clearMotion()
            state.wiggle.satisfiedAt = -.infinity
            state.wiggle.pendingAt = -.infinity
            slots[other] = state
        }
    }

    private func resolveExpiredWigglePendings(at time: TimeInterval,
                                              fired: inout [CustomGesture]) {
        for (slot, var state) in slots {
            let pendingAt = state.wiggle.pendingAt
            guard pendingAt > -.infinity, time - pendingAt >= Self.wigglePairWindow else { continue }
            state.wiggle.pendingAt = -.infinity
            if fire(state.wiggle.singleGesture, at: time, into: &fired) {
                state.wiggle.clearMotion()
                state.wiggle.satisfiedAt = -.infinity
                slots[slot] = state
                clearPartnerWiggle(of: slot)
            } else {
                slots[slot] = state
            }
        }
    }

    // MARK: - Held poses

    private static let thumbSignals: [(CustomGesture, HandFeatures.ThumbDirection)] = [
        (.thumbsUp, .up), (.thumbsDown, .down), (.thumbsLeft, .left), (.thumbsRight, .right),
    ]

    private func strictHoldGesture(_ features: HandFeatures?) -> CustomGesture? {
        guard let features else { return nil }
        // A hand pointed at the screen collapses its tips onto the palm
        // (the closed-hand read matches) while the thumb naturally juts
        // sideways — a phantom thumb signal. Pointed hands belong to the
        // pointed wiggle; the hold family stands down.
        guard features.wiggleOrientation() != .pointed else { return nil }
        for (gesture, direction) in Self.thumbSignals
        where config.enabled.contains(gesture) && features.isThumbSignal(direction) {
            return gesture
        }
        if config.enabled.contains(.shaka), features.isShaka() { return .shaka }
        return nil
    }

    private func holdStillHeld(_ gesture: CustomGesture, _ features: HandFeatures?) -> Bool {
        guard let features else { return false }
        switch gesture {
        case .thumbsUp: return features.isThumbSignalHeld(.up)
        case .thumbsDown: return features.isThumbSignalHeld(.down)
        case .thumbsLeft: return features.isThumbSignalHeld(.left)
        case .thumbsRight: return features.isThumbSignalHeld(.right)
        case .shaka: return features.isShakaHeld()
        default: return false
        }
    }

    private func updateHold(_ hold: inout HoldState, strict: HandFeatures?,
                            loose: HandFeatures?, at time: TimeInterval,
                            fired: inout [CustomGesture]) {
        guard let current = hold.gesture else {
            if let gesture = strictHoldGesture(strict) {
                hold = HoldState(gesture: gesture, start: time, fired: false, exitFrames: 0)
            }
            return
        }
        if holdStillHeld(current, loose) {
            hold.exitFrames = 0
            if !hold.fired, time - hold.start >= config.holdSeconds {
                _ = fire(current, at: time, into: &fired)
                hold.fired = true // one fire per dwell, however long it's held
            }
        } else {
            hold.exitFrames += 1
            if hold.exitFrames >= Self.holdExitFrames {
                hold = HoldState()
            }
        }
    }

    // MARK: - Grab & fling

    private static let flingDirections: [CustomGesture] = [
        .grabFlingRight, .grabFlingUpRight, .grabFlingUp, .grabFlingUpLeft,
        .grabFlingLeft, .grabFlingDownLeft, .grabFlingDown, .grabFlingDownRight,
    ]

    /// Eight 45° sectors centered on the cardinals and diagonals. Screen
    /// coordinates: +y is down, so "up" is negative y.
    static func flingGesture(for offset: Vec2) -> CustomGesture {
        let angle = atan2(-offset.y, offset.x)
        let sector = Int((angle / (.pi / 4)).rounded())
        return flingDirections[(sector + 8) % 8]
    }

    private func updateGrab(_ grab: inout GrabState, slot: Int,
                            loose: HandFeatures?,
                            at time: TimeInterval, fired: inout [CustomGesture]) {
        // "Recently open" at a loose standard: a real hand pausing open
        // before a grab measures ~0.4 openness, where the strict
        // extension-band pose flickers (measured — the strict check
        // silently vetoed a real grab video).
        if let open = loose?.openness() {
            if open >= 0.33 {
                grab.openFrames += 1
                if grab.openFrames >= 2 { grab.lastOpenTime = time }
            } else {
                grab.openFrames = 0
            }
        }
        // The grab is tracked at the fingertip bunch, not the palm: a
        // forward gather stands well away from the palm anchor, and the
        // bunch is what the camera actually sees (the measured reason real
        // grabs went undetected).
        var pointSpeed: Double?
        let gatherPoint = loose?.gatherPoint()
        if let point = gatherPoint {
            let dt = time - grab.lastTime
            if let last = grab.lastPoint, dt > 0, dt <= 0.25 {
                pointSpeed = point.distance(to: last) / dt
            }
            grab.lastPoint = point
            grab.lastTime = time
        }

        if !grab.active {
            grabbingSlots.remove(slot)
            // Engaging requires the open→gathered transition (a resting fist
            // was never open), from a bunch that is roughly still (a real
            // grab closes from rest; a relaxed closed hand travelling
            // through the frame closes mid-flight). The thumb-out
            // look-alikes (thumb signals, shaka) exclude themselves: the
            // thumb is one of the five tips the bunch is measured over.
            guard let loose, loose.isGathered(spreadLimit: config.gatherSpread),
                  (pointSpeed ?? .infinity) <= Self.flingEngageMaxSpeed else {
                grab.gatherFrames = 0
                return
            }
            grab.gatherFrames += 1
            guard grab.gatherFrames >= Self.flingEngageFrames,
                  time - grab.lastOpenTime <= Self.flingOpenWindow,
                  let point = gatherPoint else { return }
            grab.active = true
            grab.anchor = point
            grab.activeSince = time
            grab.fired = false
            grab.releaseFrames = 0
            grabbingSlots.insert(slot)
            return
        }

        // Release: the hand opened back up (debounced). Unreadable geometry
        // holds, like everywhere else — the first frames of a fast fling
        // blur the fingertips into nothing, and that must not read as
        // "opened" (measured: it ended a real grab right before its fling).
        // A truly lost hand expires with its slot.
        if let held = loose?.isGatherHeld(spreadLimit: config.gatherSpread) {
            if held {
                grab.releaseFrames = 0
            } else {
                grab.releaseFrames += 1
                if grab.releaseFrames >= Self.flingReleaseFrames {
                    grab = GrabState(lastOpenTime: grab.lastOpenTime)
                    grabbingSlots.remove(slot)
                    return
                }
            }
        }

        guard let point = gatherPoint else { return }
        let offset = point - grab.anchor

        // A grab that goes nowhere lets go of the cursor on its own.
        if !grab.fired, time - grab.activeSince > Self.flingStallTimeout,
           offset.length < config.flingTravel * Self.flingStallFraction {
            grab = GrabState(lastOpenTime: grab.lastOpenTime)
            grabbingSlots.remove(slot)
            return
        }

        guard !grab.fired, offset.length >= config.flingTravel else { return }
        if fire(Self.flingGesture(for: offset), at: time, into: &fired) {
            grab.fired = true // one fling per grab; direction locked at firing
        }
    }
}
