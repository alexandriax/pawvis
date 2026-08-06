import Foundation

/// Turns a stream of camera-space `HandFrame`s into mouse events plus overlay
/// render state. Deterministic and clock-free: all timing comes from frame
/// timestamps, so every behavior is unit-testable.
///
/// The gesture model is intentionally minimal:
///   open hand → the cursor follows the hand (palm anchor)
///   close hand → left button down (click; twice quickly = double-click)
///   move while closed → drag
///   open hand → button up
///
/// The palm barely moves while the fingers curl into a fist, so clicking is
/// inherently position-stable — no rollback or anchor correction needed.
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
    private var grabbed = false
    private var grabDebounce = 0
    private var lastOpenness: Double = 1.0

    // Double-click chaining.
    private var lastUpTime: TimeInterval = -.infinity
    private var lastUpPos: Vec2 = .zero
    private var lastUpClickCount = 0

    // MARK: - Public API

    /// Release a held grab (used on shutdown / tracking disable so the button
    /// is never left stuck down).
    public func forceRelease(at time: TimeInterval) -> [GestureEvent] {
        var events: [GestureEvent] = []
        if let p = press {
            events.append(.buttonUp(.left, at: cursor ?? p.downAt, clickCount: p.clickCount))
        }
        press = nil
        grabbed = false
        grabDebounce = 0
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
        lastOpenness = 1.0
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

        // 3. Cursor follows the palm (stable through hand closes).
        if let pointer = features?.pointerPoint(.palmCenter) {
            let clamped = pointer.clampedToUnit()
            if var p = press {
                // Micro-movement suppression: quick clicks shouldn't smear
                // into drags; past the threshold it's a real drag.
                if p.dragging || clamped.distance(to: p.downAt) >= config.dragActivationDistance {
                    p.dragging = true
                    press = p
                    cursor = clamped
                    events.append(.drag(.left, to: clamped))
                }
            } else if cursor != clamped {
                cursor = clamped
                events.append(.move(to: clamped))
            }
        }

        // 4. Grab state: openness with hysteresis + debounce.
        if let openness = features?.openness() {
            lastOpenness = openness
            updateGrab(openness: openness, at: frame.time, events: &events)
        }
        // Missing openness (occluded joints): hold current state; the
        // tracking-loss grace handles real dropouts.

        // 5. Overlay state.
        overlay.hands = tracked.map { th in
            var oh = OverlayHand()
            oh.isPrimary = th.slotID == primarySlotID
            for (joint, p) in th.hand.fingertips { oh.fingertips[joint] = p }
            return oh
        }
        overlay.cursor = cursor
        overlay.grabbed = grabbed
        overlay.isDragging = press?.dragging ?? false
        overlay.closingProgress = closingProgress(for: lastOpenness)

        return (events, overlay)
    }

    // MARK: - Grab detection

    private func updateGrab(openness: Double, at time: TimeInterval, events: inout [GestureEvent]) {
        if !grabbed {
            if openness < config.grabCloseThreshold {
                grabDebounce += 1
                if grabDebounce >= config.grabDebounceFrames {
                    grabbed = true
                    grabDebounce = 0
                    beginPress(at: time, events: &events)
                }
            } else {
                grabDebounce = 0
            }
        } else if openness > config.grabOpenThreshold {
            grabbed = false
            grabDebounce = 0
            endPress(at: time, events: &events)
        }
    }

    /// 0 when comfortably open, 1 at the click threshold.
    private func closingProgress(for openness: Double) -> Double {
        let span = config.grabOpenThreshold - config.grabCloseThreshold
        guard span > 1e-6 else { return grabbed ? 1 : 0 }
        if grabbed { return 1 }
        return min(max((config.grabOpenThreshold - openness) / span, 0), 1)
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
            overlay.grabbed = grabbed
            overlay.isDragging = press?.dragging ?? false
            overlay.closingProgress = grabbed ? 1 : 0
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
