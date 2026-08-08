import Foundation

/// Turns a stream of camera-space `HandFrame`s into mouse events plus overlay
/// render state. Deterministic and clock-free: all timing comes from frame
/// timestamps, so every behavior is unit-testable.
///
/// The gesture model is intentionally minimal:
///   open hand shown     → cursor control arms (see `config.controlTrigger`;
///                         `.anyHand` skips the ceremony, a fist parks it again)
///   hand tracked        → the cursor rides the palm
///   the index finger dips → left button down (click; twice quickly = double-click)
///   move while dipped   → drag
///   the finger lifts    → button up
///   a second finger dips → the same machinery, on the right button
///   middle + ring fold in → scroll: the scroll pose parks the cursor and
///                         turns vertical hand travel into wheel events
///   both hands splayed, traded sides → the criss-cross wave: hand tracking
///                         switches off entirely (optional, on by default)
///
/// The click reduces to one scale-normalized ratio crossing a threshold (the
/// index tip's extent differenced against the middle finger's, so whole-hand
/// tilt can't click), and the cursor rides the palm — a landmark the click
/// motion itself barely moves, so a click doesn't shift the cursor.
/// Only ever one button at a time: whichever engaged first owns the press.
///
/// Input hands are in **camera space**: normalized [0,1], x right, y down,
/// unmirrored. The engine mirrors, maps through the interaction box (sized to
/// the hand itself when `reachMode` is `.auto`), and smooths (One Euro per
/// joint, sporecaster-style slot tracking with stale reset) before running
/// gesture logic in screen-normalized space.
public final class GestureEngine {

    public var config: GestureConfig {
        didSet {
            if config.smoothing != oldValue.smoothing {
                for i in slots.indices { slots[i].setFilterParams(config.smoothing) }
            }
            if config.rightClickFinger != oldValue.rightClickFinger
                || config.rightClickEnabled != oldValue.rightClickEnabled {
                // The new setting's ratio says nothing about the old one's
                // hold, so changing it mid-press would strand the button down —
                // the finger moved out from under its right-click. The up
                // rides out with the next frame (or the next forceRelease).
                pendingEvents = forceRelease(at: lastHandTime)
            }
            if config.scrollEnabled != oldValue.scrollEnabled {
                // Off mid-scroll: stop scrolling at once. On: the pose still
                // has to engage from scratch.
                scroll = ScrollState()
            }
            if config.crissCrossDisableEnabled != oldValue.crissCrossDisableEnabled
                || config.crissCrossDisableCrossings != oldValue.crissCrossDisableCrossings {
                // Off (or retuned) mid-wave: the crossing count starts over.
                crissCross = CrissCrossState()
            }
            if config.controlTrigger != oldValue.controlTrigger {
                armFrames = 0
                disarmFrames = 0
                if config.controlTrigger == .openHand {
                    // The hand on screen never showed the trigger, so it does
                    // not get to keep the cursor — or a press — it holds.
                    pendingEvents = forceRelease(at: lastHandTime)
                    armed = false
                } else {
                    armed = true // .anyHand: an in-flight press carries on
                }
            }
        }
    }

    public init(config: GestureConfig = .default) {
        self.config = config
        self.slots = [HandSlot(id: 0, params: config.smoothing),
                      HandSlot(id: 1, params: config.smoothing)]
        self.effectiveInteractionBox = config.interactionBox
        self.armed = config.controlTrigger == .anyHand
    }

    // MARK: - Internal state

    /// sporecaster slot pattern: two persistent identities matched greedily by
    /// raw palm distance, with filters/state reset after a stale gap.
    private struct HandSlot {
        let id: Int
        var filters: [OneEuroFilter2D]
        var lastSeen: TimeInterval = -.infinity
        var matchPalm: Vec2 = .zero

        init(id: Int, params: OneEuroFilter.Params) {
            self.id = id
            self.filters = Array(repeating: OneEuroFilter2D(params: params), count: HandJoint.allCases.count)
        }

        mutating func setFilterParams(_ params: OneEuroFilter.Params) {
            for i in filters.indices { filters[i].params = params }
        }

        mutating func reset() {
            for i in filters.indices { filters[i].reset() }
        }
    }

    private struct PressState {
        var button: MouseButton
        var downAt: Vec2
        var downTime: TimeInterval
        var clickCount: Int
        var dragging = false
    }

    /// One button's hysteresis + debounce state. Left and right run the same
    /// machine over different metrics; only one of them may hold at a time.
    private struct ButtonState {
        var engaged = false
        var engageFrames = 0
        var releaseFrames = 0
    }

    /// The scroll pose's state: the same debounce-both-ways shape
    /// as a button, plus the anchor the next scroll delta is measured from.
    private struct ScrollState {
        var active = false
        var engageFrames = 0
        var releaseFrames = 0
        /// Unclamped pointer y the next delta is measured against; nil until
        /// the first armed frame after activation seeds it. Unclamped so a
        /// hand that sails past the interaction box keeps scrolling.
        var anchorY: Double?
    }

    /// The criss-cross tracking-off wave's state: both hands up, open and
    /// splayed, then traded sides. Engages like every other pose (strict
    /// pose + debounce), then counts debounced side swaps until the
    /// configured number switches tracking off.
    private struct CrissCrossState {
        var engaged = false
        var engageFrames = 0
        /// Consecutive frames a hand showed a positively curled finger — the
        /// deliberate exit.
        var exitFrames = 0
        /// Completed side trades so far.
        var crossings = 0
        /// Which side of each other the palms last confidently sat: +1 when
        /// the right-chirality palm was right of the left-chirality one, -1
        /// once they crossed. 0 = not yet seeded.
        var sideSign = 0
        /// Consecutive well-separated frames on the opposite side — a swap
        /// only counts once it survives the debounce.
        var sideCandidateFrames = 0
        /// When the wave last advanced (engaged or crossed): the stall timeout.
        var lastProgressTime: TimeInterval = -.infinity
        /// When both hands were last tracked, for the mid-wave dropout grace.
        var lastPairTime: TimeInterval = -.infinity
    }

    private static let slotMatchMax = 0.25 // normalized palm travel to keep identity

    /// Joint confidence required to *engage*. Vision reports low confidence
    /// exactly when it is guessing at overlapping or foreshortened joints —
    /// which is when phantom clicks come from. Above `minJointConfidence` so a
    /// shaky joint still holds and releases normally.
    private static let engageConfidenceFloor = 0.40

    /// EMA weight on the measured hand size. Slow on purpose: the box it feeds
    /// is a coordinate transform, so it must react to "the user leaned in",
    /// never to per-frame landmark noise.
    private static let handScaleAlpha = 0.1
    /// Fraction of the remaining gap the auto box closes each frame. At 30 fps
    /// a full refit takes about two seconds — slow enough that the drift never
    /// reads as the cursor swimming under a still hand.
    private static let reachLerp = 0.05

    /// Consecutive open-hand frames before the `.openHand` trigger arms
    /// (~0.1 s at 30 fps): enough that a hand flashing through the pose in
    /// passing doesn't grab the cursor.
    private static let triggerArmFrames = 3
    /// Consecutive closed-hand frames before control disarms (~0.3 s):
    /// comfortably longer than any click gesture's engage transition, so
    /// closing the hand *into* a click can never drop control mid-gesture.
    private static let triggerDisarmFrames = 9

    /// Palms must stand at least this far apart (screen-normalized x) to
    /// count as being on distinct sides for the criss-cross wave. Inside the
    /// band the hands are mid-crossing and their order is ambiguous — frames
    /// there neither count nor reset.
    private static let crissCrossMinSeparation = 0.10
    /// The wave must keep making progress: engaged with no new crossing for
    /// this long resets the gesture, so a static double high-five can't
    /// park the cursor (or block the buttons) forever.
    private static let crissCrossTimeout: TimeInterval = 2.0

    private var slots: [HandSlot]
    private var primarySlotID: Int?
    private var lastHandTime: TimeInterval = -.infinity

    /// Whether the control trigger currently lets the hand drive the cursor.
    /// Always true in `.anyHand` mode.
    private var armed: Bool
    private var armFrames = 0
    private var disarmFrames = 0

    private var cursor: Vec2?
    /// At most one press exists at a time, whichever button owns it.
    private var press: PressState?
    private var leftButton = ButtonState()
    private var rightButton = ButtonState()
    private var scroll = ScrollState()
    private var crissCross = CrissCrossState()
    /// EMA of the primary hand's raw camera-space scale; nil until a hand is
    /// seen (and again once one is truly gone).
    private(set) var smoothedHandScale: Double?
    /// The box actually used for mapping: `config.interactionBox` in `.manual`,
    /// a hand-sized box drifting toward its target in `.auto`.
    private(set) var effectiveInteractionBox: InteractionBox
    /// Events produced outside `process` (a mid-session settings change),
    /// flushed ahead of the next frame's.
    private var pendingEvents: [GestureEvent] = []

    // Double-click chaining.
    private var lastUpTime: TimeInterval = -.infinity
    private var lastUpPos: Vec2 = .zero
    private var lastUpClickCount = 0

    // MARK: - Public API

    /// Release a held press (used on shutdown / tracking disable so no button
    /// is ever left stuck down).
    public func forceRelease(at time: TimeInterval) -> [GestureEvent] {
        var events = pendingEvents
        pendingEvents = []
        if let p = press {
            events.append(.buttonUp(p.button, at: cursor ?? p.downAt, clickCount: p.clickCount))
        }
        press = nil
        leftButton = ButtonState()
        rightButton = ButtonState()
        // A forced release must not chain into a double-click.
        lastUpTime = -.infinity
        _ = time
        return events
    }

    public func reset() {
        _ = forceRelease(at: 0)
        scroll = ScrollState()
        crissCross = CrissCrossState()
        for i in slots.indices { slots[i].reset() }
        primarySlotID = nil
        cursor = nil
        lastHandTime = -.infinity
        smoothedHandScale = nil
        armed = config.controlTrigger == .anyHand
        armFrames = 0
        disarmFrames = 0
    }

    public func process(_ frame: HandFrame) -> (events: [GestureEvent], overlay: OverlayState) {
        var events = pendingEvents
        pendingEvents = []
        var overlay = OverlayState()

        let usableHands = frame.hands.filter { $0.confidence >= config.minHandConfidence }

        guard !usableHands.isEmpty else {
            let (noHandEvents, noHandOverlay) = handleNoHands(at: frame.time)
            return (events + noHandEvents, noHandOverlay)
        }

        // 1. Assign hands to persistent slots, map to screen space, smooth.
        let tracked = assignAndSmooth(hands: usableHands, at: frame.time)
        lastHandTime = frame.time

        // 2. Pick the primary (gesture-driving) hand, sticky across frames.
        var primary: TrackedHand
        if let id = primarySlotID, let match = tracked.first(where: { $0.slotID == id }) {
            primary = match
        } else {
            primary = tracked.max(by: { $0.hand.confidence < $1.hand.confidence })!
            primarySlotID = primary.slotID
        }

        // While waiting for the trigger, prefer whichever hand is showing it:
        // a closed hand that got primary first (resting on the desk, say) must
        // not block the deliberately opened one from taking the cursor.
        if config.controlTrigger == .openHand, !armed,
           !(armFeatures(of: primary.hand)?.isOpenHand() ?? false),
           let open = tracked.first(where: { $0.slotID != primary.slotID
               && (armFeatures(of: $0.hand)?.isOpenHand() ?? false) }) {
            primary = open
            primarySlotID = open.slotID
        }

        let features = HandFeatures(
            hand: primary.hand,
            thresholds: config.poseThresholds,
            minJointConfidence: config.minJointConfidence)

        // 3. The control trigger decides whether this hand gets the cursor.
        updateTrigger(features, hand: primary.hand)

        // 4. The scroll pose's own arm/park state machine. Before the cursor
        // step because an active scroll parks the cursor.
        updateScroll(features)

        // 4½. The criss-cross tracking-off wave watches every tracked hand,
        // armed or not — stopping tracking must not require cursor control.
        // The park flag is sampled *before* the update so the frame that
        // completes the wave doesn't emit one last cursor jump on its way out.
        let crissCrossParked = crissCross.engaged && crissCross.crossings > 0
        if updateCrissCross(tracked, at: frame.time) {
            events.append(.disableTracking)
        }

        if armed, let pointer = pointerPoint(features) {
            // 5. Cursor follows the palm (chosen so the click gesture barely
            // moves it) — unless the scroll pose holds it parked, in which
            // case vertical palm travel becomes wheel events instead.
            let clamped = pointer.clampedToUnit()
            if scroll.active {
                if let anchor = scroll.anchorY {
                    // Deadband against the anchor, like a drag's: shimmer
                    // stays put, and slow travel accumulates until it counts.
                    let travel = pointer.y - anchor
                    if abs(travel) >= config.jitterDeadband {
                        scroll.anchorY = pointer.y
                        // Hand up (y shrinking) = scroll up (positive wheel).
                        events.append(.scroll(deltaY: config.scrollInvert ? travel : -travel))
                    }
                } else {
                    scroll.anchorY = pointer.y
                }
            } else if crissCrossParked {
                // The wave is in progress: the cursor parks so hands trading
                // sides don't fling it across the screen (the scroll park's
                // idea). No press can exist here — engaging required none,
                // and both buttons are blocked while the wave is engaged.
            } else if var p = press {
                // Tap window then micro-movement suppression (see dragThreshold).
                if p.dragging || clamped.distance(to: p.downAt) >= dragThreshold(for: p, at: frame.time) {
                    p.dragging = true
                    press = p
                    // Deadband against the last *emitted* position, which is
                    // what `cursor` holds — so the button-up still lands on the
                    // last place we sent the pointer.
                    if clamped.distance(to: cursor ?? p.downAt) >= config.jitterDeadband {
                        cursor = clamped
                        events.append(.drag(p.button, to: clamped))
                    }
                }
            } else if cursor.map({ clamped.distance(to: $0) >= config.jitterDeadband / 2 }) ?? true {
                cursor = clamped
                events.append(.move(to: clamped))
            }
        }

        // 6. Button state: each button's ratio with hysteresis + debounce.
        // Left runs first, so a frame where both fingers dip reads as a plain
        // click; from then on whichever is held locks the other out — and an
        // active scroll locks out both. Disarmed, the buttons stay untouched
        // (they are at rest — disarming resets them), so no press can ever
        // begin on a parked cursor.
        let ratio = armed ? clickRatio(features) : nil
        if armed {
            let rightHeld = isHeld(.right)
            updateButton(.left, state: &leftButton, ratio: ratio,
                         engage: config.engageRatio, release: config.releaseRatio,
                         confident: engageConfident(primary.hand),
                         blocked: rightHeld || scroll.active || crissCross.engaged,
                         at: frame.time, events: &events)
            let leftHeld = isHeld(.left)
            updateButton(.right, state: &rightButton, ratio: rightRatio(features),
                         engage: config.rightEngageRatio, release: config.rightReleaseRatio,
                         confident: rightEngageConfident(primary.hand),
                         blocked: leftHeld || scroll.active || crissCross.engaged
                             || scrollPoseBlocksRightClick(features),
                         at: frame.time, events: &events)
        }

        // 7. Fit the interaction box to the hand (auto reach). Last, so the
        // box that mapped this frame is the one the press — if any — began in.
        // Runs while disarmed too: the box is fitted by the time control arms.
        updateReach(rawHand: primary.raw)

        // 8. Overlay state.
        overlay.hands = tracked.map { th in
            var oh = OverlayHand()
            oh.isPrimary = th.slotID == primarySlotID
            for (joint, p) in th.hand.fingertips { oh.fingertips[joint] = p }
            return oh
        }
        overlay.armed = armed
        overlay.cursor = cursor
        overlay.grabbed = leftButton.engaged
        overlay.rightGrabbed = rightButton.engaged
        overlay.isDragging = press?.dragging ?? false
        overlay.isScrolling = scroll.active
        overlay.closingProgress = closingProgress(for: ratio)

        return (events, overlay)
    }

    // MARK: - Control trigger

    /// Pose features for the *arm* side of the trigger, on any tracked hand.
    /// Arming demands the same joint confidence that click engagement does:
    /// Vision reports low confidence exactly when it is guessing at
    /// overlapping or foreshortened joints, and a guessed-open hand must not
    /// take the cursor any more than a guessed pinch may click. (The disarm
    /// side keeps the permissive floor — low confidence holds state, never
    /// flaps it.)
    private func armFeatures(of hand: Hand) -> HandFeatures? {
        HandFeatures(hand: hand,
                     thresholds: config.poseThresholds,
                     minJointConfidence: max(config.minJointConfidence, Self.engageConfidenceFloor))
    }

    /// The arm/disarm state machine for `.openHand`: an open hand held
    /// `triggerArmFrames` arms cursor control; a closed hand (3+ fingers
    /// curled) held `triggerDisarmFrames` parks it again. Arming reads the
    /// hand through `armFeatures` — engage-grade joint confidence plus the
    /// openness floor — because that side is where phantoms grab the cursor;
    /// disarming stays on the permissive `features`. Never disarms while
    /// a button is engaged or held — every click gesture closes part of the
    /// hand, and dropping control mid-press would strand the button down.
    /// Missing joints hold the current state, exactly as the button ratios do.
    /// (Clicks themselves are deliberately NOT gated on openness — see
    /// AGENTS.md; only the *arming* of cursor control is.)
    private func updateTrigger(_ features: HandFeatures?, hand: Hand) {
        guard config.controlTrigger == .openHand else {
            armed = true
            armFrames = 0
            disarmFrames = 0
            return
        }
        guard let features else {
            armFrames = 0
            disarmFrames = 0
            return
        }
        if armed {
            armFrames = 0
            let pressing = press != nil || leftButton.engaged || rightButton.engaged
            guard !pressing, features.curledFingerCount() >= 3 else {
                disarmFrames = 0
                return
            }
            disarmFrames += 1
            guard disarmFrames >= Self.triggerDisarmFrames else { return }
            disarmFrames = 0
            armed = false
            // A button mid-engage-debounce must not fire on the next arm.
            leftButton = ButtonState()
            rightButton = ButtonState()
        } else {
            disarmFrames = 0
            guard armFeatures(of: hand)?.isOpenHand() == true else {
                armFrames = 0
                return
            }
            armFrames += 1
            guard armFrames >= Self.triggerArmFrames else { return }
            armFrames = 0
            armed = true
        }
    }

    // MARK: - Click gesture

    /// The scale-normalized quantity the left button thresholds: the index
    /// finger's dip differential. nil (a joint below `minJointConfidence`)
    /// holds the current state, as it always has.
    private func clickRatio(_ features: HandFeatures?) -> Double? {
        features?.indexTapRatio()
    }

    /// The landmark that drives the cursor — the palm, the one part of the
    /// hand no finger gesture moves. (A fingertip centroid shifts ~0.08
    /// screen-normalized when the hand opens to release — enough to smear
    /// every click into a drag.)
    private func pointerPoint(_ features: HandFeatures?) -> Vec2? {
        features?.pointerPoint(.palmCenter)
    }

    /// Whether every joint the click ratio depends on is tracked confidently
    /// enough to *start* a press. Consulted only on the engage side.
    private func engageConfident(_ hand: Hand) -> Bool {
        // The differential needs both fingers' tip and knuckle.
        [HandJoint.indexTip, .indexMCP, .middleTip, .middleMCP].allSatisfy {
            hand.confidence(for: $0) >= Self.engageConfidenceFloor
        }
    }

    // MARK: - Scroll

    /// The scroll pose's arm/park state machine: the strict pose held
    /// for the debounce starts a scroll, drifting out of the loosened hold
    /// pose for the debounce ends it. A press always wins — the pose cannot
    /// engage while any button is down (physically it can't coexist with a
    /// dip anyway: the scroll pose needs the index and little fingers up).
    private func updateScroll(_ features: HandFeatures?) {
        guard config.scrollEnabled, armed else {
            scroll = ScrollState()
            return
        }
        guard press == nil, !leftButton.engaged, !rightButton.engaged else {
            scroll.engageFrames = 0
            return
        }
        guard let features else {
            // Missing joints hold the current state, exactly as the buttons'.
            scroll.engageFrames = 0
            scroll.releaseFrames = 0
            return
        }
        if scroll.active {
            scroll.engageFrames = 0
            guard !features.isScrollPoseHeld() else {
                scroll.releaseFrames = 0
                return
            }
            scroll.releaseFrames += 1
            guard scroll.releaseFrames >= config.pinchDebounceFrames else { return }
            scroll = ScrollState()
        } else {
            scroll.releaseFrames = 0
            guard features.isScrollPose() else {
                scroll.engageFrames = 0
                return
            }
            scroll.engageFrames += 1
            guard scroll.engageFrames >= config.pinchDebounceFrames else { return }
            scroll = ScrollState(active: true) // anchor seeds from the next pointer
        }
    }

    /// With scroll on, a right-click finger that is *half the scroll
    /// pose* (middle or ring) gets one extra engage guard: the pose's other
    /// folding finger must still be extended. Folding middle + ring together
    /// into a scroll can transiently read as one of them dipping ahead of its
    /// tap reference; a genuine dip keeps the rest of the hand up. Engage
    /// only — a held right button still releases normally.
    private func scrollPoseBlocksRightClick(_ features: HandFeatures?) -> Bool {
        guard config.scrollEnabled, let features else { return false }
        switch config.rightClickFinger {
        case .middle: return features.isExtended(.ring) != true
        case .ring: return features.isExtended(.middle) != true
        case .index, .little: return false
        }
    }

    // MARK: - Criss-cross tracking-off wave

    /// Pose features at the permissive joint-confidence floor for any tracked
    /// hand (the primary's are built inline in `process`).
    private func looseFeatures(of hand: Hand) -> HandFeatures? {
        HandFeatures(hand: hand,
                     thresholds: config.poseThresholds,
                     minJointConfidence: config.minJointConfidence)
    }

    /// The criss-cross state machine: both hands open and splayed (a double
    /// high-five), then crossed over each other and back. Each debounced
    /// trade of sides counts one crossing; reaching
    /// `config.crissCrossDisableCrossings` returns true, and the caller
    /// emits `.disableTracking`.
    ///
    /// Chirality — Vision's left/right label — orders the palms, never slot
    /// identity: greedy slot matching swaps identities at exactly the moment
    /// the hands overlap, which is the moment this gesture is about. Frames
    /// whose chirality is unknown or duplicated hold state, like any other
    /// low-confidence signal. The usual shape otherwise: strict engage
    /// (splayed pose at engage-grade confidence, no press in flight), loose
    /// hold (only a positively curled finger, held for the debounce, is a
    /// deliberate exit — splay wobbles and low confidence mid-wave hold),
    /// debounce in both directions, and two escape hatches: the tracking-loss
    /// grace for a partner hand Vision drops mid-crossing, and a stall
    /// timeout so an idle double high-five never parks the cursor for good.
    private func updateCrissCross(_ tracked: [TrackedHand], at time: TimeInterval) -> Bool {
        guard config.crissCrossDisableEnabled else {
            crissCross = CrissCrossState()
            return false
        }

        if !crissCross.engaged {
            guard tracked.count == 2, press == nil,
                  !leftButton.engaged, !rightButton.engaged,
                  tracked.allSatisfy({ armFeatures(of: $0.hand)?.isOpenPalmSplayed() == true })
            else {
                crissCross.engageFrames = 0
                return false
            }
            crissCross.engageFrames += 1
            guard crissCross.engageFrames >= config.pinchDebounceFrames else { return false }
            crissCross = CrissCrossState()
            crissCross.engaged = true
            crissCross.lastProgressTime = time
            crissCross.lastPairTime = time
            return false
        }

        // Stalled: an idle double high-five is not the wave.
        if time - crissCross.lastProgressTime > Self.crissCrossTimeout {
            crissCross = CrissCrossState()
            return false
        }

        guard tracked.count == 2 else {
            // Vision drops a hand exactly when the two overlap mid-crossing,
            // so a missing partner gets the tracking-loss grace, not a reset.
            if time - crissCross.lastPairTime > config.trackingLossGrace {
                crissCross = CrissCrossState()
            }
            return false
        }
        crissCross.lastPairTime = time

        // The deliberate exit: a genuinely curled finger on either hand,
        // held for the debounce. (Splay and extension drifting neutral, or
        // joints going low-confidence, hold — a fast wave blurs fingers.)
        let closing = tracked.contains { th in
            guard let f = looseFeatures(of: th.hand) else { return false }
            return Finger.allCases.contains { f.isCurled($0) == true }
        }
        if closing {
            crissCross.exitFrames += 1
            if crissCross.exitFrames >= config.pinchDebounceFrames {
                crissCross = CrissCrossState()
            }
            return false
        }
        crissCross.exitFrames = 0

        // Order the palms by chirality; unknown or doubled labels hold.
        let lefts = tracked.filter { $0.hand.chirality == .left }
        let rights = tracked.filter { $0.hand.chirality == .right }
        guard lefts.count == 1, rights.count == 1,
              let leftPalm = looseFeatures(of: lefts[0].hand)?.pointerPoint(.palmCenter),
              let rightPalm = looseFeatures(of: rights[0].hand)?.pointerPoint(.palmCenter)
        else { return false }

        let delta = rightPalm.x - leftPalm.x
        // Inside the separation band the crossing is in progress and the
        // ordering ambiguous: neither count nor reset.
        guard abs(delta) >= Self.crissCrossMinSeparation else { return false }
        let sign = delta > 0 ? 1 : -1

        if crissCross.sideSign == 0 {
            crissCross.sideSign = sign
            return false
        }
        if sign == crissCross.sideSign {
            crissCross.sideCandidateFrames = 0
            return false
        }
        crissCross.sideCandidateFrames += 1
        guard crissCross.sideCandidateFrames >= config.pinchDebounceFrames else { return false }
        crissCross.sideSign = sign
        crissCross.sideCandidateFrames = 0
        crissCross.crossings += 1
        crissCross.lastProgressTime = time
        guard crissCross.crossings >= max(config.crissCrossDisableCrossings, 1) else { return false }
        crissCross = CrissCrossState()
        return true
    }

    // MARK: - Right click

    /// The finger whose dip presses the right button, or nil when this
    /// configuration has none: the finger already driving the left button
    /// can't drive both.
    private var activeRightClickFinger: Finger? {
        guard config.rightClickEnabled else { return nil }
        return config.rightClickFinger == .index ? nil : config.rightClickFinger
    }

    /// The dip differential the right button thresholds, in every mode that
    /// has one. nil holds the current state, exactly as the left ratio does.
    private func rightRatio(_ features: HandFeatures?) -> Double? {
        guard let features, let finger = activeRightClickFinger else { return nil }
        return features.fingerTapRatio(finger)
    }

    /// The right-click differential's own engage-side confidence gate: the
    /// dipping finger's tip and knuckle plus its reference neighbor's.
    private func rightEngageConfident(_ hand: Hand) -> Bool {
        guard let finger = activeRightClickFinger else { return false }
        let reference = HandFeatures.tapReference(for: finger)
        return [finger.tip, finger.mcp, reference.tip, reference.mcp].allSatisfy {
            hand.confidence(for: $0) >= Self.engageConfidenceFloor
        }
    }

    /// Whether this button currently owns the press. One press at a time: the
    /// other button's engage counter must not so much as accumulate meanwhile.
    private func isHeld(_ button: MouseButton) -> Bool {
        let state = button == .left ? leftButton : rightButton
        return state.engaged || press?.button == button
    }

    // MARK: - Press detection

    /// One button's state machine: hysteresis band, two-way debounce, and an
    /// engage-only confidence gate. Both buttons share it — they differ only
    /// in which ratio, thresholds, and gate they arrive with.
    private func updateButton(_ button: MouseButton, state: inout ButtonState,
                              ratio: Double?, engage: Double, release: Double,
                              confident: Bool, blocked: Bool,
                              at time: TimeInterval, events: inout [GestureEvent]) {
        guard let ratio else {
            // A joint below the confidence floor must never flap the state:
            // hold it and restart both counters. Real dropouts go through the
            // tracking-loss grace instead.
            state.engageFrames = 0
            state.releaseFrames = 0
            return
        }
        if !state.engaged {
            state.releaseFrames = 0
            guard confident, !blocked else {
                // Reset, not pause: a phantom needs *consecutive* confident
                // frames, and low confidence is where phantoms live. The other
                // button holding the press blocks this one just as hard.
                state.engageFrames = 0
                return
            }
            guard ratio < engage else {
                state.engageFrames = 0 // includes the hysteresis band: no transition there
                return
            }
            state.engageFrames += 1
            guard state.engageFrames >= config.pinchDebounceFrames else { return }
            state.engageFrames = 0
            state.engaged = true
            beginPress(button, at: time, events: &events)
        } else {
            state.engageFrames = 0
            guard ratio > release else {
                state.releaseFrames = 0
                return
            }
            state.releaseFrames += 1
            guard state.releaseFrames >= config.pinchDebounceFrames else { return }
            state.releaseFrames = 0
            state.engaged = false
            endPress(button, at: time, events: &events)
        }
    }

    /// 0 when the hand sits comfortably open, 1 while a button is down.
    private func closingProgress(for ratio: Double?) -> Double {
        if leftButton.engaged || rightButton.engaged { return 1 }
        guard let ratio else { return 0 }
        // The tap differential idles near 1.0; a short ramp keeps the resting
        // ring near zero instead of showing a quarter-closed ring at rest.
        let span = 0.25
        let progress = ((config.releaseRatio + span) - ratio)
            / (config.releaseRatio + span - config.engageRatio)
        return min(max(progress, 0), 1)
    }

    // MARK: - Drag activation

    /// How far the pointer must leave the press point to drag. Inside the tap
    /// window only a deliberate flick qualifies — everything smaller is the
    /// wobble of a hand closing and opening, and used to smear clicks into
    /// one-pixel drags.
    private func dragThreshold(for press: PressState, at time: TimeInterval) -> Double {
        time - press.downTime < config.dragStartDelay
            ? config.dragIntentDistance
            : config.dragActivationDistance
    }

    private func beginPress(_ button: MouseButton, at time: TimeInterval,
                            events: inout [GestureEvent]) {
        guard press == nil, let pos = cursor else { return }
        var clickCount = 1
        // Only the left button chains: a right click is always a single, and
        // never seeds a double-click.
        if button == .left,
           time - lastUpTime <= config.doubleClickInterval,
           pos.distance(to: lastUpPos) <= config.doubleClickSlop,
           lastUpClickCount < 3 { // after a triple, the chain restarts at 1
            clickCount = lastUpClickCount + 1
        }
        press = PressState(button: button, downAt: pos, downTime: time, clickCount: clickCount)
        events.append(.buttonDown(button, at: pos, clickCount: clickCount))
    }

    private func endPress(_ button: MouseButton, at time: TimeInterval,
                          events: inout [GestureEvent]) {
        guard let p = press, p.button == button else { return }
        let pos = cursor ?? p.downAt
        events.append(.buttonUp(button, at: pos, clickCount: p.clickCount))
        if button == .left {
            // A right click in the middle of a double-click must neither chain
            // nor break the chain, so it leaves these untouched.
            lastUpTime = time
            lastUpPos = pos
            lastUpClickCount = p.clickCount
        }
        press = nil
    }

    // MARK: - No-hands path

    private func handleNoHands(at time: TimeInterval) -> (events: [GestureEvent], overlay: OverlayState) {
        var events: [GestureEvent] = []
        var overlay = OverlayState()
        overlay.cursor = cursor

        // Within the grace window, hold all state — a one-frame dropout must
        // not release a drag (sporecaster keeps slots alive 300 ms).
        if time - lastHandTime > config.trackingLossGrace {
            events.append(contentsOf: forceRelease(at: time))
            scroll = ScrollState() // a returning hand re-anchors from scratch
            crissCross = CrissCrossState() // hands truly gone: the wave restarts
            primarySlotID = nil
            // The hand is genuinely gone: the next one sizes the auto box from
            // its own scale rather than inheriting this one's.
            smoothedHandScale = nil
            if config.controlTrigger == .openHand {
                // …and it must show the trigger again to take the cursor back.
                armed = false
                armFrames = 0
                disarmFrames = 0
            }
        } else {
            let held = leftButton.engaged || rightButton.engaged
            overlay.grabbed = leftButton.engaged
            overlay.rightGrabbed = rightButton.engaged
            overlay.isDragging = press?.dragging ?? false
            overlay.isScrolling = scroll.active
            overlay.closingProgress = held ? 1 : 0
        }
        overlay.armed = armed
        return (events, overlay)
    }

    // MARK: - Auto reach

    /// Track the hand's real size and drift the interaction box toward the box
    /// that size wants. `rawHand` is camera-space and unsmoothed — it has to
    /// be, or the measurement would be scaled by the very box it feeds.
    private func updateReach(rawHand: Hand) {
        if let scale = rawScale(of: rawHand) {
            smoothedHandScale = smoothedHandScale.map {
                $0 + (scale - $0) * Self.handScaleAlpha
            } ?? scale // seed on the first sight of a hand, don't ramp up from zero
        }
        guard config.reachMode == .auto else {
            effectiveInteractionBox = config.interactionBox // manual: verbatim, at once
            return
        }
        // Never mid-press: the box is a coordinate transform, so moving it
        // under a held button would slide whatever is being dragged.
        guard press == nil, let scale = smoothedHandScale else { return }
        let target = Self.targetBox(forHandScale: scale)
        func drift(_ edge: Double, toward goal: Double) -> Double {
            edge + (goal - edge) * Self.reachLerp
        }
        effectiveInteractionBox = InteractionBox(
            xMin: drift(effectiveInteractionBox.xMin, toward: target.xMin),
            xMax: drift(effectiveInteractionBox.xMax, toward: target.xMax),
            yMin: drift(effectiveInteractionBox.yMin, toward: target.yMin),
            yMax: drift(effectiveInteractionBox.yMax, toward: target.yMax))
    }

    /// The box a hand of this raw camera-space scale wants. A close (big) hand
    /// gets larger margins — a smaller active box pulled toward frame center —
    /// because its fingers occupy so much of the frame that reaching a fixed
    /// box's edges would push them out of view (the "can't click the top half
    /// of the screen up close" failure). A distant (small) hand gets slim
    /// margins and most of the frame. Every margin is measured in hand scales,
    /// so the whole hand — not just the palm anchor the cursor rides — stays
    /// inside the frame when the cursor is at a screen edge.
    /// At scale 0.15 (a typical laptop-webcam hand) this reproduces the tuned
    /// manual defaults exactly, so switching modes is not a jump.
    static func targetBox(forHandScale scale: Double) -> InteractionBox {
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
        // Sideways: a little over half a hand width of air on each side.
        let xMargin = clamp(0.60 * scale + 0.05, 0.08, 0.40)
        // Up: the fingers reach ~1.3 scales above the palm anchor, and all of
        // them have to stay in frame with the cursor at the top of the screen.
        let yTop = clamp(1.35 * scale + 0.05, 0.10, 0.48)
        // Down: only the wrist trails the anchor, so far less room is needed.
        let yBottom = clamp(0.50 * scale + 0.05, 0.08, 0.30)
        return InteractionBox(xMin: xMargin, xMax: 1 - xMargin,
                              yMin: yTop, yMax: 1 - yBottom)
    }

    /// The hand's size in raw camera space, by exactly the rule HandFeatures
    /// normalizes with (wrist→middle knuckle, else knuckle span / 0.7).
    private func rawScale(of hand: Hand) -> Double? {
        HandFeatures(hand: hand,
                     thresholds: config.poseThresholds,
                     minJointConfidence: config.minJointConfidence)?.scale
    }

    // MARK: - Slot tracking + smoothing

    private struct TrackedHand {
        var slotID: Int
        var hand: Hand // screen-space, smoothed
        var raw: Hand  // camera-space, exactly as tracked (auto reach measures this)
    }

    private func rawPalm(of hand: Hand) -> Vec2 {
        let ids: [HandJoint] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        var pts = ids.compactMap { hand[$0] }
        if pts.isEmpty { pts = HandJoint.allCases.compactMap { hand[$0] } }
        let c = centroid(of: pts)
        // Match in mirrored camera space so identity math matches what the user sees.
        return config.mirrorCamera ? Vec2(1 - c.x, c.y) : c
    }

    private func assignAndSmooth(hands: [Hand], at time: TimeInterval) -> [TrackedHand] {
        // The effective box, not the configured one: in `.auto` they differ.
        let mapper = CoordinateMapper(box: effectiveInteractionBox, mirrored: config.mirrorCamera)
        let capped = Array(hands.prefix(slots.count))
        let palms = capped.map { rawPalm(of: $0) }

        // Greedy nearest-palm matching within the match radius.
        var slotForHand = [Int?](repeating: nil, count: capped.count)
        var slotTaken = [Bool](repeating: false, count: slots.count)
        var candidates: [(dist: Double, hand: Int, slot: Int)] = []
        for h in capped.indices {
            for s in slots.indices {
                candidates.append((palms[h].distance(to: slots[s].matchPalm), h, s))
            }
        }
        for c in candidates.sorted(by: { $0.dist < $1.dist })
        where c.dist < Self.slotMatchMax && slotForHand[c.hand] == nil && !slotTaken[c.slot] {
            slotForHand[c.hand] = c.slot
            slotTaken[c.slot] = true
        }
        for h in capped.indices where slotForHand[h] == nil {
            if let free = slots.indices.first(where: { !slotTaken[$0] }) {
                slotForHand[h] = free
                slotTaken[free] = true
            }
        }

        var result: [TrackedHand] = []
        for h in capped.indices {
            guard let s = slotForHand[h] else { continue }
            // Stale slot → hard reset so filters don't lerp across a reacquisition jump.
            if time - slots[s].lastSeen > config.trackingLossGrace {
                slots[s].reset()
            }
            slots[s].lastSeen = time
            slots[s].matchPalm = palms[h]

            let screenHand = capped[h].mapPointsWithJoint { joint, p in
                let mapped = mapper.map(p, clamped: false)
                return slots[s].filters[joint.rawValue].filter(mapped, at: time)
            }
            result.append(TrackedHand(slotID: slots[s].id, hand: screenHand, raw: capped[h]))
        }
        return result.sorted { $0.slotID < $1.slotID }
    }
}

extension Hand {
    /// Like `mapPoints`, but the transform also receives the joint (needed to
    /// route each joint through its own smoothing filter).
    func mapPointsWithJoint(_ transform: (HandJoint, Vec2) -> Vec2) -> Hand {
        var copy = self
        for joint in HandJoint.allCases {
            if let p = self[joint] {
                copy.setPoint(transform(joint, p), for: joint, confidence: self.confidence(for: joint))
            }
        }
        return copy
    }
}
