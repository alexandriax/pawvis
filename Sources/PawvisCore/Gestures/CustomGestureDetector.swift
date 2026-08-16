import Foundation

/// Detects the bindable one-shot gestures (`CustomGesture`) in the same
/// tracked, screen-space hand stream the engine's built-in gestures run on.
/// Deterministic and clock-free like everything else in PawvisCore: all
/// timing comes from frame timestamps.
///
/// Every family follows the house state-machine shape — strict engage, loose
/// hold, debounce, and an explicit story for presses: nothing here may fire
/// while a button is down or a scroll is active (a fast drag must never read
/// as a swipe), and the motion families additionally stand down while the
/// criss-cross wave is engaged (hands trading sides are not swiping).
/// Missing joints hold state rather than flapping it.
///
/// Detection runs armed or parked — like the criss-cross wave, a bound
/// command must not require cursor control. Only gestures in
/// `Config.enabled` are watched at all; an empty set makes `process` free.
public final class CustomGestureDetector {

    /// Distilled from `CustomGestureSettings` (the bindings choose `enabled`,
    /// the sensitivity sliders choose the thresholds). Changing it resets all
    /// in-flight detection state.
    public struct Config: Equatable, Sendable {
        /// The gestures with a live binding. Everything else is ignored.
        public var enabled: Set<CustomGesture> = []
        /// Screen-normalized distance an open hand must sweep to swipe.
        public var swipeTravel: Double = 0.32
        /// Per-finger direction reversals within the window that count as
        /// wiggling.
        public var wiggleReversals: Int = 3
        /// How long a held pose (thumbs, shaka) must dwell before firing.
        public var holdSeconds: TimeInterval = 0.35
        /// Screen-normalized displacement that completes a grab & fling.
        public var flingTravel: Double = 0.16

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
        /// The criss-cross wave is engaged: the motion families (swipe,
        /// grab & fling) reset; the in-place families keep running.
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

    /// Swipe: how fast the palm must already be moving (screen-normalized
    /// per second) for a sweep to begin accumulating.
    private static let swipeMinSpeed = 1.1
    /// A sweep that hasn't covered the distance in this long isn't a swipe.
    private static let swipeMaxDuration: TimeInterval = 0.6
    /// The dominant axis must beat the other by this factor, or the sweep is
    /// an ambiguous diagonal and deliberately rejected.
    private static let swipeAxisDominance = 1.6
    /// Cos of the allowed drift from the sweep's initial direction.
    private static let swipeDirectionCos = 0.75
    /// Fraction of `swipeMinSpeed` below which a finished (or aborted) hand
    /// re-arms, so one long sweep can't fire twice.
    private static let swipeRearmFraction = 0.35
    /// Fraction of `swipeMinSpeed` below which an accumulating sweep aborts.
    private static let swipeContinueFraction = 0.45
    /// Consecutive strict-open frames a hand needs before its next fast frame
    /// may begin a sweep (motion blur ruins the strict check mid-sweep).
    private static let swipeOpenFrames = 2
    /// How long a one-hand candidate waits for its partner before deciding
    /// the swipe was one-handed after all.
    private static let swipePairWindow: TimeInterval = 0.18
    /// Partner travel (as a fraction of the threshold) that counts as
    /// swiping along for the two-hand version.
    private static let swipePartnerFraction = 0.5
    private static let swipeRefractory: TimeInterval = 0.8

    /// Wiggle: reversals older than this fall out of the count.
    private static let wiggleWindow: TimeInterval = 1.2
    /// Extent change (in hand scales) that counts as a finger moving; smaller
    /// is landmark shimmer.
    private static let wiggleNoiseFloor = 0.045
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
    /// The hand must have been strictly open within this long of gathering —
    /// the transition is what makes a grab deliberate; a hand that was simply
    /// resting closed can never fling.
    private static let flingOpenWindow: TimeInterval = 0.7
    /// Consecutive ungathered frames that release a grab.
    private static let flingReleaseFrames = 2
    /// An engaged grab that goes nowhere for this long lets go on its own,
    /// so a closed hand can't park the cursor forever (the criss-cross
    /// stall's idea).
    private static let flingStallTimeout: TimeInterval = 2.0
    /// Fraction of the fling distance below which the grab counts as stalled.
    private static let flingStallFraction = 0.3
    private static let flingRefractory: TimeInterval = 0.6

    // MARK: - State

    private struct SwipeState {
        var lastPalm: Vec2?
        var lastTime: TimeInterval = -.infinity
        var openFrames = 0
        var anchor: Vec2?
        var anchorTime: TimeInterval = -.infinity
        var dir: Vec2 = .zero
        /// Fired or aborted: the hand must slow down before another sweep.
        var mustSlow = false
        /// Crossed the threshold and waiting on the partner hand.
        var pending: (gesture: CustomGesture, twoHand: CustomGesture, at: TimeInterval)?
        /// Travel so far, for the partner check.
        var travel: Double = 0
    }

    private struct WiggleState {
        var lastExtent: [Double?] = Array(repeating: nil, count: Finger.allCases.count)
        var lastSign: [Int] = Array(repeating: 0, count: Finger.allCases.count)
        var reversals: [[TimeInterval]] = Array(repeating: [], count: Finger.allCases.count)
        var palmOrigin: Vec2?
        var closedFrames = 0
        var satisfiedAt: TimeInterval = -.infinity
        var pendingAt: TimeInterval = -.infinity

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
        var gatherFrames = 0
        var active = false
        var anchor: Vec2 = .zero
        var activeSince: TimeInterval = 0
        var fired = false
        var releaseFrames = 0
    }

    private struct SlotState {
        var lastSeen: TimeInterval = -.infinity
        var swipe = SwipeState()
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

    public func reset() {
        slots = [:]
        lastFire = [:]
        grabbingSlots = []
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
        if families.contains(.swipe) {
            resolveExpiredSwipePendings(at: context.time, fired: &fired)
        }
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
                // A press always wins: every family resets outright.
                state.swipe = SwipeState()
                state.wiggle.clearMotion()
                state.hold = HoldState()
                state.grab = GrabState()
                grabbingSlots.remove(input.slot)
            } else {
                if families.contains(.swipe) {
                    if context.crissCrossEngaged {
                        state.swipe = SwipeState()
                    } else {
                        updateSwipe(&state.swipe, slot: input.slot, strict: strict,
                                    loose: loose, at: context.time, fired: &fired)
                    }
                }
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
                        updateGrab(&state.grab, slot: input.slot, strict: strict,
                                   loose: loose, at: context.time, fired: &fired)
                    }
                }
            }

            slots[input.slot] = state
        }

        return fired
    }

    // MARK: - Firing

    private func refractory(for family: CustomGesture.Family) -> TimeInterval {
        switch family {
        case .swipe: return Self.swipeRefractory
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

    // MARK: - Swipe

    private static func swipeGesture(dx: Double, dy: Double) -> (one: CustomGesture, two: CustomGesture?)? {
        if abs(dx) >= Self.swipeAxisDominance * abs(dy) {
            return dx < 0 ? (.swipeLeft, .twoHandSwipeLeft) : (.swipeRight, .twoHandSwipeRight)
        }
        if abs(dy) >= Self.swipeAxisDominance * abs(dx) {
            return dy < 0 ? (.swipeUp, nil) : (.swipeDown, nil)
        }
        return nil // ambiguous diagonal: deliberately not a swipe
    }

    private func updateSwipe(_ swipe: inout SwipeState, slot: Int,
                             strict: HandFeatures?, loose: HandFeatures?,
                             at time: TimeInterval, fired: inout [CustomGesture]) {
        defer {
            // The strict-open streak feeds the *next* frame's start check:
            // by the time the hand is sweeping, motion blur has ruined the
            // strict pose, so eligibility comes from the frames just before.
            if strict?.isOpenHand() == true {
                swipe.openFrames += 1
            } else if let open = loose?.openness(), open < 0.3 {
                swipe.openFrames = 0
            } // low-confidence frames hold the streak, as everywhere else
        }

        guard let palm = loose?.pointerPoint(.palmCenter) else { return }
        defer {
            swipe.lastPalm = palm
            swipe.lastTime = time
        }
        guard let lastPalm = swipe.lastPalm else { return }
        let dt = time - swipe.lastTime
        guard dt > 0, dt <= 0.2 else {
            swipe.anchor = nil
            return
        }
        let speed = palm.distance(to: lastPalm) / dt

        if swipe.mustSlow {
            if speed < Self.swipeMinSpeed * Self.swipeRearmFraction { swipe.mustSlow = false }
            swipe.anchor = nil
            return
        }

        if swipe.anchor == nil {
            // A sweep begins on a fast frame from a hand that was just
            // confidently open.
            guard speed >= Self.swipeMinSpeed, swipe.openFrames >= Self.swipeOpenFrames else { return }
            swipe.anchor = lastPalm
            swipe.anchorTime = swipe.lastTime
            swipe.dir = (palm - lastPalm) / max(palm.distance(to: lastPalm), 1e-9)
            swipe.travel = 0
        }

        guard let anchor = swipe.anchor else { return }
        if time - swipe.anchorTime > Self.swipeMaxDuration {
            swipe.anchor = nil
            return
        }
        if let open = loose?.openness(), open < 0.3 {
            // The hand closed mid-sweep — it became something else (a grab).
            swipe.anchor = nil
            return
        }
        if speed < Self.swipeMinSpeed * Self.swipeContinueFraction {
            swipe.anchor = nil
            return
        }
        let offset = palm - anchor
        swipe.travel = offset.length
        if swipe.travel >= 0.04,
           offset.dot(swipe.dir) / max(swipe.travel, 1e-9) < Self.swipeDirectionCos {
            swipe.anchor = nil // curved away from the sweep's own direction
            return
        }
        guard swipe.travel >= config.swipeTravel else { return }

        // Threshold crossed: this hand is done either way.
        swipe.anchor = nil
        swipe.mustSlow = true
        guard let (one, two) = Self.swipeGesture(dx: offset.x, dy: offset.y) else { return }

        guard let two, config.enabled.contains(two) else {
            _ = fire(one, at: time, into: &fired)
            return
        }
        // Two-hand version is bound: fire it if the partner hand is sweeping
        // along (or already waiting); otherwise hold the decision briefly.
        if var partner = partnerSwipe(of: slot) {
            let partnerHere = partner.state.pending?.gesture == one
                || (partner.state.anchor != nil
                    && partner.state.travel >= config.swipeTravel * Self.swipePartnerFraction
                    && Self.swipeGesture(dx: partner.state.dir.x, dy: partner.state.dir.y)?.one == one)
            if partnerHere {
                partner.state.pending = nil
                partner.state.anchor = nil
                partner.state.mustSlow = true
                slots[partner.slot]?.swipe = partner.state
                _ = fire(two, at: time, into: &fired)
                return
            }
        }
        if config.enabled.contains(one) || config.enabled.contains(two) {
            swipe.pending = (gesture: one, twoHand: two, at: time)
        }
    }

    private func partnerSwipe(of slot: Int) -> (slot: Int, state: SwipeState)? {
        for (other, state) in slots where other != slot {
            return (other, state.swipe)
        }
        return nil
    }

    /// A candidate whose partner never showed was a one-hand swipe after all.
    private func resolveExpiredSwipePendings(at time: TimeInterval,
                                             fired: inout [CustomGesture]) {
        for (slot, var state) in slots {
            guard let pending = state.swipe.pending else { continue }
            if time - pending.at >= Self.swipePairWindow {
                state.swipe.pending = nil
                slots[slot] = state
                _ = fire(pending.gesture, at: pending.at + Self.swipePairWindow, into: &fired)
            }
        }
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
        if let palm = loose.pointerPoint(.palmCenter) {
            if let origin = wiggle.palmOrigin, palm.distance(to: origin) > Self.wigglePalmStill {
                // The hand is travelling, not wiggling in place.
                wiggle.clearMotion()
                wiggle.palmOrigin = palm
            } else if wiggle.palmOrigin == nil {
                wiggle.palmOrigin = palm
            }
        }

        for (i, finger) in Finger.allCases.enumerated() {
            guard let extent = loose.fingertipExtent(finger) else { continue }
            guard let last = wiggle.lastExtent[i] else {
                wiggle.lastExtent[i] = extent
                continue
            }
            let delta = extent - last
            guard abs(delta) >= Self.wiggleNoiseFloor else { continue }
            let sign = delta > 0 ? 1 : -1
            if wiggle.lastSign[i] != 0, sign != wiggle.lastSign[i] {
                wiggle.reversals[i].append(time)
            }
            wiggle.lastSign[i] = sign
            wiggle.lastExtent[i] = extent
        }
        for i in wiggle.reversals.indices {
            wiggle.reversals[i].removeAll { time - $0 > Self.wiggleWindow }
        }

        let wigglingFingers = wiggle.reversals.filter { $0.count >= max(config.wiggleReversals, 1) }.count
        guard wigglingFingers >= Self.wiggleMinFingers else { return }
        wiggle.satisfiedAt = time

        guard config.enabled.contains(.twoHandFingerWiggle) else {
            if fire(.fingerWiggle, at: time, into: &fired) {
                wiggle.clearMotion()
                clearPartnerWiggle(of: slot)
            }
            return
        }
        // Two-hand version is bound: fire it the moment both hands are
        // wiggling; a lone hand waits out the pair window first.
        if let partner = partnerWiggle(of: slot),
           time - partner.state.satisfiedAt <= Self.wigglePairWindow {
            if fire(.twoHandFingerWiggle, at: time, into: &fired) {
                wiggle.clearMotion()
                clearPartnerWiggle(of: slot)
            }
            return
        }
        if wiggle.pendingAt == -.infinity || time - wiggle.pendingAt > Self.wigglePairWindow {
            wiggle.pendingAt = time
        }
    }

    private func partnerWiggle(of slot: Int) -> (slot: Int, state: WiggleState)? {
        for (other, state) in slots where other != slot {
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
            if fire(.fingerWiggle, at: time, into: &fired) {
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

    private func strictHoldGesture(_ features: HandFeatures?) -> CustomGesture? {
        guard let features else { return nil }
        if config.enabled.contains(.thumbsUp), features.isThumbSignal(up: true) { return .thumbsUp }
        if config.enabled.contains(.thumbsDown), features.isThumbSignal(up: false) { return .thumbsDown }
        if config.enabled.contains(.shaka), features.isShaka() { return .shaka }
        return nil
    }

    private func holdStillHeld(_ gesture: CustomGesture, _ features: HandFeatures?) -> Bool {
        guard let features else { return false }
        switch gesture {
        case .thumbsUp: return features.isThumbSignalHeld(up: true)
        case .thumbsDown: return features.isThumbSignalHeld(up: false)
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
                            strict: HandFeatures?, loose: HandFeatures?,
                            at time: TimeInterval, fired: inout [CustomGesture]) {
        if strict?.isOpenHand() == true {
            grab.lastOpenTime = time
        }

        if !grab.active {
            grabbingSlots.remove(slot)
            // Engaging requires the open→gathered transition (a resting fist
            // was never open) and a thumb that is *not* standing vertically —
            // that shape is the thumbs-up/down pose, whose held motion must
            // not fling.
            guard let loose, loose.isGathered(), loose.thumbVerticalSign() == nil else {
                grab.gatherFrames = 0
                return
            }
            grab.gatherFrames += 1
            guard grab.gatherFrames >= Self.flingEngageFrames,
                  time - grab.lastOpenTime <= Self.flingOpenWindow,
                  let palm = loose.pointerPoint(.palmCenter) else { return }
            grab.active = true
            grab.anchor = palm
            grab.activeSince = time
            grab.fired = false
            grab.releaseFrames = 0
            grabbingSlots.insert(slot)
            return
        }

        // Release: the hand opened back up (debounced). Missing geometry
        // holds, like everywhere else; a truly lost hand expires with its slot.
        if let loose {
            if loose.isGatherHeld() {
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

        guard let palm = loose?.pointerPoint(.palmCenter) else { return }
        let offset = palm - grab.anchor

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
