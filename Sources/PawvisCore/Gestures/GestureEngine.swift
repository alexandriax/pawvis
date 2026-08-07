import Foundation

/// Turns a stream of camera-space `HandFrame`s into mouse events plus overlay
/// render state. Deterministic and clock-free: all timing comes from frame
/// timestamps, so every behavior is unit-testable.
///
/// The gesture model is intentionally minimal:
///   hand tracked        → the cursor follows the click gesture's pointer
///   the gesture closes  → left button down (click; twice quickly = double-click)
///   move while closed   → drag
///   the gesture opens   → button up
///
/// Which shape clicks is `config.clickGesture`; every mode reduces to one
/// scale-normalized ratio crossing a threshold, and each pairs with a pointer
/// the gesture itself barely moves — so a click doesn't shift the cursor.
///
/// Input hands are in **camera space**: normalized [0,1], x right, y down,
/// unmirrored. The engine mirrors, maps through the interaction box, and
/// smooths (One Euro per joint, sporecaster-style slot tracking with stale
/// reset) before running gesture logic in screen-normalized space.
public final class GestureEngine {

    public var config: GestureConfig {
        didSet {
            if config.smoothing != oldValue.smoothing {
                for i in slots.indices { slots[i].setFilterParams(config.smoothing) }
            }
            if config.clickGesture != oldValue.clickGesture {
                // The new mode's ratio says nothing about the old mode's hold,
                // so switching mid-pinch would strand the button down. The up
                // rides out with the next frame (or the next forceRelease).
                pendingEvents = forceRelease(at: lastHandTime)
            }
        }
    }

    public init(config: GestureConfig = .default) {
        self.config = config
        self.slots = [HandSlot(id: 0, params: config.smoothing),
                      HandSlot(id: 1, params: config.smoothing)]
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
        var downAt: Vec2
        var downTime: TimeInterval
        var clickCount: Int
        var dragging = false
    }

    private static let slotMatchMax = 0.25 // normalized palm travel to keep identity

    /// sporecaster's pinch-strength ramp for the overlay ring: 0 at a ratio of
    /// `strengthCeiling`, 1 once the tips are `strengthSpan` closer.
    private static let strengthCeiling = 0.9
    private static let strengthSpan = 0.5
    /// The other modes' ratios sit in a narrower band than the thumb–index gap,
    /// so their ring ramps over this much above their own engage threshold.
    private static let modeStrengthSpan = 0.45

    /// Joint confidence required to *engage*. Vision reports low confidence
    /// exactly when it is guessing at overlapping or foreshortened joints —
    /// which is when phantom clicks come from. Above `minJointConfidence` so a
    /// shaky joint still holds and releases normally.
    private static let engageConfidenceFloor = 0.40

    private var slots: [HandSlot]
    private var primarySlotID: Int?
    private var lastHandTime: TimeInterval = -.infinity

    private var cursor: Vec2?
    private var press: PressState?
    private var pinched = false
    private var engageFrames = 0
    private var releaseFrames = 0
    /// Events produced outside `process` (a mid-session mode switch), flushed
    /// ahead of the next frame's.
    private var pendingEvents: [GestureEvent] = []

    // Double-click chaining.
    private var lastUpTime: TimeInterval = -.infinity
    private var lastUpPos: Vec2 = .zero
    private var lastUpClickCount = 0

    // MARK: - Public API

    /// Release a held pinch (used on shutdown / tracking disable so the button
    /// is never left stuck down).
    public func forceRelease(at time: TimeInterval) -> [GestureEvent] {
        var events = pendingEvents
        pendingEvents = []
        if let p = press {
            events.append(.buttonUp(.left, at: cursor ?? p.downAt, clickCount: p.clickCount))
        }
        press = nil
        pinched = false
        engageFrames = 0
        releaseFrames = 0
        // A forced release must not chain into a double-click.
        lastUpTime = -.infinity
        _ = time
        return events
    }

    public func reset() {
        _ = forceRelease(at: 0)
        for i in slots.indices { slots[i].reset() }
        primarySlotID = nil
        cursor = nil
        lastHandTime = -.infinity
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
        let primary: TrackedHand
        if let id = primarySlotID, let match = tracked.first(where: { $0.slotID == id }) {
            primary = match
        } else {
            primary = tracked.max(by: { $0.hand.confidence < $1.hand.confidence })!
            primarySlotID = primary.slotID
        }

        let features = HandFeatures(
            hand: primary.hand,
            thresholds: config.poseThresholds,
            minJointConfidence: config.minJointConfidence)

        // 3. Cursor follows the mode's pointer (chosen so closing the gesture
        // barely moves it).
        if let pointer = pointerPoint(features, hand: primary.hand) {
            let clamped = pointer.clampedToUnit()
            if var p = press {
                // Tap window then micro-movement suppression (see dragThreshold).
                if p.dragging || clamped.distance(to: p.downAt) >= dragThreshold(for: p, at: frame.time) {
                    p.dragging = true
                    press = p
                    // Deadband against the last *emitted* position, which is
                    // what `cursor` holds — so the button-up still lands on the
                    // last place we sent the pointer.
                    if clamped.distance(to: cursor ?? p.downAt) >= config.jitterDeadband {
                        cursor = clamped
                        events.append(.drag(.left, to: clamped))
                    }
                }
            } else if cursor.map({ clamped.distance(to: $0) >= config.jitterDeadband / 2 }) ?? true {
                cursor = clamped
                events.append(.move(to: clamped))
            }
        }

        // 4. Gesture state: the mode's ratio with hysteresis + debounce.
        let ratio = modeRatio(features)
        if let ratio {
            updatePinch(ratio: ratio,
                        confident: engageConfident(primary.hand),
                        at: frame.time,
                        events: &events)
        } else {
            // A tip below the confidence floor must never flap the state: hold
            // it and restart both counters. Real dropouts go through the
            // tracking-loss grace instead.
            engageFrames = 0
            releaseFrames = 0
        }

        // 5. Overlay state.
        overlay.hands = tracked.map { th in
            var oh = OverlayHand()
            oh.isPrimary = th.slotID == primarySlotID
            for (joint, p) in th.hand.fingertips { oh.fingertips[joint] = p }
            return oh
        }
        overlay.cursor = cursor
        overlay.grabbed = pinched
        overlay.isDragging = press?.dragging ?? false
        overlay.closingProgress = closingProgress(for: ratio)

        return (events, overlay)
    }

    // MARK: - Click gesture modes

    /// The scale-normalized quantity this mode thresholds. nil (a joint below
    /// `minJointConfidence`) holds the current state, as it always has.
    private func modeRatio(_ features: HandFeatures?) -> Double? {
        guard let features else { return nil }
        switch config.clickGesture {
        case .pinch: return features.pinchRatio(to: .index)
        case .wholeHandPinch: return features.wholeHandPinchRatio()
        case .thumbCurl: return features.thumbCurlRatio()
        case .indexTap: return features.indexTapRatio()
        }
    }

    /// The landmark that drives the cursor in this mode — always one the click
    /// motion itself doesn't move.
    private func pointerPoint(_ features: HandFeatures?, hand: Hand) -> Vec2? {
        guard let features else { return nil }
        switch config.clickGesture {
        case .pinch:
            return features.pointerPoint(.pinchMidpoint)
        case .wholeHandPinch, .thumbCurl, .indexTap:
            // Both gestures are all-finger motion; only the palm holds still
            // through them. (A fingertip centroid shifts ~0.08 screen-normalized
            // when the hand opens to release — enough to smear every click
            // into a drag.)
            return features.pointerPoint(.palmCenter)
        }
    }

    /// Whether every joint this mode's ratio depends on is tracked confidently
    /// enough to *start* a press. Consulted only on the engage side.
    private func engageConfident(_ hand: Hand) -> Bool {
        func confident(_ joint: HandJoint) -> Bool {
            hand.confidence(for: joint) >= Self.engageConfidenceFloor
        }
        switch config.clickGesture {
        case .pinch:
            return confident(.thumbTip) && confident(.indexTip)
        case .wholeHandPinch:
            guard confident(.thumbTip) else { return false }
            // Only the tips that fed the mean this frame have to be trustworthy.
            let used = Finger.allCases.filter {
                hand.point(for: $0.tip, minConfidence: config.minJointConfidence) != nil
            }
            return !used.isEmpty && used.allSatisfy { confident($0.tip) }
        case .thumbCurl:
            return confident(.thumbTip) && confident(.indexMCP)
        case .indexTap:
            // The differential needs both fingers' tip and knuckle.
            return confident(.indexTip) && confident(.indexMCP)
                && confident(.middleTip) && confident(.middleMCP)
        }
    }

    // MARK: - Pinch detection

    private func updatePinch(ratio: Double, confident: Bool, at time: TimeInterval,
                             events: inout [GestureEvent]) {
        if !pinched {
            releaseFrames = 0
            guard confident else {
                // Reset, not pause: a phantom needs *consecutive* confident
                // frames, and low confidence is where phantoms live.
                engageFrames = 0
                return
            }
            guard ratio < config.engageRatio else {
                engageFrames = 0 // includes the hysteresis band: no transition there
                return
            }
            engageFrames += 1
            guard engageFrames >= config.pinchDebounceFrames else { return }
            engageFrames = 0
            pinched = true
            beginPress(at: time, events: &events)
        } else {
            engageFrames = 0
            guard ratio > config.releaseRatio else {
                releaseFrames = 0
                return
            }
            releaseFrames += 1
            guard releaseFrames >= config.pinchDebounceFrames else { return }
            releaseFrames = 0
            pinched = false
            endPress(at: time, events: &events)
        }
    }

    /// 0 when the hand sits comfortably open, 1 while pinched.
    private func closingProgress(for ratio: Double?) -> Double {
        if pinched { return 1 }
        guard let ratio else { return 0 }
        let progress: Double
        switch config.clickGesture {
        case .pinch:
            progress = (Self.strengthCeiling - ratio) / Self.strengthSpan
        case .wholeHandPinch, .thumbCurl:
            // Anchored on this mode's own engage threshold: their ratios never
            // reach sporecaster's thumb–index range, so the fixed ramp would
            // read full long before the click.
            progress = ((config.engageRatio + Self.modeStrengthSpan) - ratio) / Self.modeStrengthSpan
        case .indexTap:
            // Idles near 1.0; a shorter ramp keeps the resting ring near zero
            // instead of showing a quarter-closed ring at rest.
            let span = 0.25
            progress = ((config.releaseRatio + span) - ratio) / (config.releaseRatio + span - config.engageRatio)
        }
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

    private func beginPress(at time: TimeInterval, events: inout [GestureEvent]) {
        guard press == nil, let pos = cursor else { return }
        var clickCount = 1
        if time - lastUpTime <= config.doubleClickInterval,
           pos.distance(to: lastUpPos) <= config.doubleClickSlop,
           lastUpClickCount < 3 { // after a triple, the chain restarts at 1
            clickCount = lastUpClickCount + 1
        }
        press = PressState(downAt: pos, downTime: time, clickCount: clickCount)
        events.append(.buttonDown(.left, at: pos, clickCount: clickCount))
    }

    private func endPress(at time: TimeInterval, events: inout [GestureEvent]) {
        guard let p = press else { return }
        let pos = cursor ?? p.downAt
        events.append(.buttonUp(.left, at: pos, clickCount: p.clickCount))
        lastUpTime = time
        lastUpPos = pos
        lastUpClickCount = p.clickCount
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
            primarySlotID = nil
        } else {
            overlay.grabbed = pinched
            overlay.isDragging = press?.dragging ?? false
            overlay.closingProgress = pinched ? 1 : 0
        }
        return (events, overlay)
    }

    // MARK: - Slot tracking + smoothing

    private struct TrackedHand {
        var slotID: Int
        var hand: Hand // screen-space, smoothed
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
        let mapper = config.mapper
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
            result.append(TrackedHand(slotID: slots[s].id, hand: screenHand))
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
