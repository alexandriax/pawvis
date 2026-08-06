import Foundation

/// Turns a stream of camera-space `HandFrame`s into mouse/gesture events plus
/// overlay render state. Deterministic and clock-free: all timing comes from
/// frame timestamps, so every behavior is unit-testable.
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
        var button: MouseButton
        var downAt: Vec2
        var downTime: TimeInterval
        var clickCount: Int
        var dragging = false
    }

    private static let slotMatchMax = 0.25 // normalized palm travel to keep identity

    private var slots: [HandSlot]
    private var primarySlotID: Int?
    private var lastHandTime: TimeInterval = -.infinity

    private var cursor: Vec2?
    private var press: PressState?
    private var leftEngaged = false
    private var rightEngaged = false

    // Double-click chaining.
    private var lastUpTime: TimeInterval = -.infinity
    private var lastUpPos: Vec2 = .zero
    private var lastUpButton: MouseButton?
    private var lastUpClickCount = 0

    // Pose debouncing.
    private var scrollPoseFrames = 0
    private var fistPoseFrames = 0
    private var scrolling = false
    private var clutching = false
    private var lastScrollPointer: Vec2?

    // Clutch: making a fist freezes the cursor; reopening re-anchors hand
    // position to the frozen cursor (like lifting and repositioning a mouse).
    // The accumulated offset shifts all screen-space hand points so cursor,
    // dots, and gestures stay coherent.
    private var clutchOffset = Vec2.zero
    private var frozenCursor: Vec2?
    private var clutchJustEnded = false
    private var clutchJustBegan = false

    /// Recent cursor positions (one per processed frame). Forming a fist drags
    /// the pointer for the few debounce frames before the clutch engages, so on
    /// engage we roll the cursor back to where it was before the pose began.
    private var cursorHistory: [Vec2] = []
    private static let cursorHistoryLimit = 16

    // Dictation toggle hold.
    private var dictationHoldStart: TimeInterval?
    private var dictationLatched = false

    // MARK: - Public API

    /// Release any held button (used on shutdown / tracking disable so buttons
    /// are never left stuck down).
    public func forceRelease(at time: TimeInterval) -> [GestureEvent] {
        var events: [GestureEvent] = []
        if let p = press {
            events.append(.buttonUp(p.button, at: cursor ?? p.downAt, clickCount: p.clickCount))
        }
        press = nil
        leftEngaged = false
        rightEngaged = false
        scrolling = false
        clutching = false
        scrollPoseFrames = 0
        fistPoseFrames = 0
        lastScrollPointer = nil
        dictationHoldStart = nil
        dictationLatched = false
        frozenCursor = nil
        clutchJustEnded = false
        // A forced release must not chain into a double-click.
        lastUpTime = -.infinity
        return events
    }

    public func reset() {
        _ = forceRelease(at: 0)
        for i in slots.indices { slots[i].reset() }
        primarySlotID = nil
        cursor = nil
        lastHandTime = -.infinity
        clutchOffset = .zero
        frozenCursor = nil
        clutchJustEnded = false
        cursorHistory.removeAll()
    }

    public func process(_ frame: HandFrame) -> (events: [GestureEvent], overlay: OverlayState) {
        var events: [GestureEvent] = []
        var overlay = OverlayState()

        let usableHands = frame.hands.filter { $0.confidence >= config.minHandConfidence }

        guard !usableHands.isEmpty else {
            return handleNoHands(at: frame.time)
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

        let allFeatures = tracked.compactMap {
            HandFeatures(hand: $0.hand, thresholds: config.poseThresholds,
                         minJointConfidence: config.minJointConfidence)
        }

        // 3. Dictation-toggle pose (independent of pointer/pinch logic).
        let togglePose = dictationPoseActive(allFeatures: allFeatures, handCount: tracked.count)
        if togglePose {
            if dictationHoldStart == nil, !dictationLatched {
                dictationHoldStart = frame.time
            }
            if let start = dictationHoldStart, !dictationLatched,
               frame.time - start >= config.dictationHoldSeconds {
                events.append(.dictationToggle)
                dictationLatched = true
                dictationHoldStart = nil
            }
        } else {
            dictationHoldStart = nil
            dictationLatched = false
        }

        // 4. Mode poses on the primary hand (debounced; never while pressing).
        updateModePoses(features: features)

        // 5. Pointer / cursor / press-drag / scroll.
        let pointer = features?.pointerPoint(config.pointerSource)
        processPointer(pointer, at: frame.time, events: &events)

        // 6. Pinch → button transitions (not in scroll/clutch modes).
        if let features, !scrolling, !clutching {
            processPinches(features: features, at: frame.time, events: &events)
        }

        // 7. Build overlay state.
        overlay.hands = tracked.map { th in
            var oh = OverlayHand()
            oh.isPrimary = th.slotID == primarySlotID
            for (joint, p) in th.hand.fingertips { oh.fingertips[joint] = p }
            if oh.isPrimary, let f = features {
                if let ratio = f.pinchRatio(to: .index) {
                    oh.leftPinchStrength = Self.pinchStrength(ratio: ratio)
                    oh.leftPinchPoint = f.pinchPoint(with: .index)
                }
                if let ratio = f.pinchRatio(to: config.rightClickFinger) {
                    oh.rightPinchStrength = Self.pinchStrength(ratio: ratio)
                    oh.rightPinchPoint = f.pinchPoint(with: config.rightClickFinger)
                }
            }
            return oh
        }
        overlay.cursor = cursor
        overlay.leftEngaged = leftEngaged
        overlay.rightEngaged = rightEngaged
        overlay.isDragging = press?.dragging ?? false
        overlay.mode = scrolling ? .scrolling : (clutching ? .clutch : .pointing)
        if let start = dictationHoldStart, !dictationLatched {
            overlay.dictationHoldProgress = min((frame.time - start) / config.dictationHoldSeconds, 1)
        }

        if let c = cursor {
            cursorHistory.append(c)
            if cursorHistory.count > Self.cursorHistoryLimit {
                cursorHistory.removeFirst(cursorHistory.count - Self.cursorHistoryLimit)
            }
        }

        return (events, overlay)
    }

    // MARK: - No-hands path

    private func handleNoHands(at time: TimeInterval) -> (events: [GestureEvent], overlay: OverlayState) {
        var events: [GestureEvent] = []
        var overlay = OverlayState()
        overlay.cursor = cursor
        overlay.mode = .none

        // Within the grace window, hold all state — a one-frame dropout must
        // not release a drag (sporecaster keeps slots alive 300 ms).
        if time - lastHandTime > config.trackingLossGrace {
            events.append(contentsOf: forceRelease(at: time))
            primarySlotID = nil
            // A real disappearance also drops the clutch re-anchor: the hand
            // may re-enter anywhere, so a stale offset would skew everything.
            clutchOffset = .zero
            frozenCursor = nil
            cursorHistory.removeAll()
        } else {
            overlay.leftEngaged = leftEngaged
            overlay.rightEngaged = rightEngaged
            overlay.isDragging = press?.dragging ?? false
        }
        dictationHoldStart = nil
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

            let offset = clutchOffset
            let screenHand = capped[h].mapPointsWithJoint { joint, p in
                let mapped = mapper.map(p, clamped: false)
                return slots[s].filters[joint.rawValue].filter(mapped, at: time) + offset
            }
            result.append(TrackedHand(slotID: slots[s].id, hand: screenHand))
        }
        return result.sorted { $0.slotID < $1.slotID }
    }

    // MARK: - Poses

    private func dictationPoseActive(allFeatures: [HandFeatures], handCount: Int) -> Bool {
        switch config.dictationToggle {
        case .off:
            return false
        case .oneHandSplayHold:
            return allFeatures.contains { $0.isOpenPalmSplayed() }
        case .twoHandSplay:
            return handCount >= 2 && allFeatures.count >= 2
                && allFeatures.allSatisfy { $0.isOpenPalmSplayed() }
        case .shakaHold:
            return allFeatures.contains { $0.isShaka() }
        }
    }

    private func updateModePoses(features: HandFeatures?) {
        let wasClutching = clutching

        defer {
            if !wasClutching, clutching {
                // Roll back past the fist-formation frames (debounce + a couple
                // of frames of finger curl) to the pre-fist cursor position.
                let rollback = config.poseHoldFrames + 2
                let idx = cursorHistory.count - 1 - rollback
                frozenCursor = idx >= 0 ? cursorHistory[idx] : (cursorHistory.first ?? cursor)
                clutchJustBegan = true
            } else if wasClutching, !clutching {
                clutchJustEnded = true
            }
        }

        guard press == nil, let features else {
            scrollPoseFrames = 0
            fistPoseFrames = 0
            scrolling = false
            clutching = false
            lastScrollPointer = nil
            return
        }

        if config.scrollEnabled, features.isTwoFingerPoint() {
            scrollPoseFrames += 1
        } else {
            scrollPoseFrames = 0
        }
        let wasScrolling = scrolling
        scrolling = scrollPoseFrames >= config.poseHoldFrames
        if !scrolling || !wasScrolling { lastScrollPointer = nil }

        if config.clutchEnabled, !scrolling, features.isFist() {
            fistPoseFrames += 1
        } else {
            fistPoseFrames = 0
        }
        clutching = !scrolling && fistPoseFrames >= config.poseHoldFrames
    }

    // MARK: - Pointer / drag / scroll

    private func processPointer(_ rawPointer: Vec2?, at time: TimeInterval, events: inout [GestureEvent]) {
        guard var pointer = rawPointer else { return }

        if clutching {
            // On engage, snap back to the pre-fist position (undoing the drift
            // from the fingers curling), then hold there.
            if clutchJustBegan {
                clutchJustBegan = false
                if let frozen = frozenCursor, frozen != cursor {
                    cursor = frozen
                    events.append(.move(to: frozen))
                }
            }
            return // cursor frozen, like a lifted mouse
        }

        // Coming out of a clutch: re-anchor so the cursor continues from where
        // it froze instead of jumping to the hand's new absolute position.
        if clutchJustEnded {
            clutchJustEnded = false
            if let frozen = frozenCursor {
                clutchOffset = clutchOffset + (frozen - pointer)
                pointer = frozen
            }
            frozenCursor = nil
        }

        let clamped = pointer.clampedToUnit()

        if scrolling {
            if let last = lastScrollPointer {
                let dNorm = pointer - last
                // Engine convention: natural scroll → hand up gives positive dy.
                // The platform layer maps sign onto CGEvent's wheel convention.
                let sign: Double = config.naturalScroll ? -1 : 1
                let dx = dNorm.x * config.scrollGainPixels * sign
                let dy = dNorm.y * config.scrollGainPixels * sign
                if abs(dx) > 0.01 || abs(dy) > 0.01 {
                    events.append(.scroll(dxPixels: dx, dyPixels: dy, at: cursor ?? clamped))
                }
            }
            lastScrollPointer = pointer
            return // cursor stays put while scrolling
        }

        if var p = press {
            // Suppress micro-movement while pressed so quick clicks don't smear
            // into drags; past the threshold it's a real drag.
            if !p.dragging, clamped.distance(to: p.downAt) < config.dragActivationDistance {
                return
            }
            p.dragging = true
            press = p
            cursor = clamped
            events.append(.drag(p.button, to: clamped))
            return
        }

        if cursor != clamped {
            cursor = clamped
            events.append(.move(to: clamped))
        }
    }

    // MARK: - Pinches

    /// sporecaster's continuous pinch ramp: 1.0 at ratio ≤ 0.4, 0 at ratio ≥ 0.9.
    static func pinchStrength(ratio: Double) -> Double {
        min(max((0.9 - ratio) / 0.5, 0), 1)
    }

    private func processPinches(features: HandFeatures, at time: TimeInterval, events: inout [GestureEvent]) {
        let leftRatio = features.pinchRatio(to: .index)
        let rightRatio = features.pinchRatio(to: config.rightClickFinger)

        // A closing fist sweeps the index tip past the thumb, which looks
        // exactly like a pinch for a few frames. A real pinch keeps the other
        // fingers up, so a mostly-closed hand may not *start* a press
        // (releases are always honored).
        let opennessOK = (features.openness() ?? 1.0) > 0.30

        // Hysteresis (0.45 engage / 0.68 release by default). Missing joints
        // hold the previous state; the tracking-loss grace handles real dropouts.
        if let r = leftRatio {
            if !leftEngaged, r < config.pinchEngageRatio, opennessOK,
               !rightEngaged { // one button at a time
                leftEngaged = true
                beginPress(button: .left, at: time, events: &events)
            } else if leftEngaged, r > config.pinchReleaseRatio {
                leftEngaged = false
                endPress(button: .left, at: time, events: &events)
            }
        }

        if let r = rightRatio {
            // The right-click finger's tip passes near the thumb during an index
            // pinch; only engage when the index is clearly open.
            let indexClearlyOpen = (leftRatio ?? .infinity) > config.pinchReleaseRatio
            if !rightEngaged, r < config.pinchEngageRatio, opennessOK, !leftEngaged, indexClearlyOpen {
                rightEngaged = true
                beginPress(button: .right, at: time, events: &events)
            } else if rightEngaged, r > config.pinchReleaseRatio {
                rightEngaged = false
                endPress(button: .right, at: time, events: &events)
            }
        }
    }

    private func beginPress(button: MouseButton, at time: TimeInterval, events: inout [GestureEvent]) {
        guard press == nil, let pos = cursor else {
            // No cursor yet (first frames) — engage without a press.
            return
        }
        var clickCount = 1
        if button == .left, lastUpButton == .left,
           time - lastUpTime <= config.doubleClickInterval,
           pos.distance(to: lastUpPos) <= config.doubleClickSlop,
           lastUpClickCount < 3 { // after a triple, the chain restarts at 1
            clickCount = lastUpClickCount + 1
        }
        press = PressState(button: button, downAt: pos, downTime: time, clickCount: clickCount)
        events.append(.buttonDown(button, at: pos, clickCount: clickCount))
    }

    private func endPress(button: MouseButton, at time: TimeInterval, events: inout [GestureEvent]) {
        guard let p = press, p.button == button else { return }
        let pos = cursor ?? p.downAt
        events.append(.buttonUp(button, at: pos, clickCount: p.clickCount))
        lastUpTime = time
        lastUpPos = pos
        lastUpButton = button
        lastUpClickCount = p.clickCount
        press = nil
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
