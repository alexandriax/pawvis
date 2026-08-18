import Foundation

/// What a tracked hand must do before it controls the cursor. Tracking itself
/// always runs while enabled — this gates only whether the hand may move the
/// cursor and click.
public enum ControlTrigger: String, Codable, CaseIterable, Sendable {
    /// Show an open hand — all four fingers extended, thumb free — to take
    /// control; close the hand into a fist for a moment to let go. Keeps a
    /// hand that is merely visible (resting, typing, gesturing) from dragging
    /// the cursor around. Default.
    case openHand
    /// Any tracked hand controls the cursor immediately (the original
    /// behavior).
    case anyHand
    /// The cursor is never taken: no pointing, no clicks, no scrolling.
    /// Hands are still tracked and the custom gestures (and the tracking-off
    /// wave) still fire — the hands-as-a-remote mode.
    case gesturesOnly

    public var displayName: String {
        switch self {
        case .openHand: return "Open hand"
        case .anyHand: return "Any detected hand"
        case .gesturesOnly: return "Never — custom gestures only"
        }
    }
}

/// How the interaction box — the slice of the camera view that maps onto the
/// whole screen — is chosen.
public enum ReachMode: String, Codable, CaseIterable, Sendable {
    /// Sized from the hand actually being tracked: a big (close) hand gets a
    /// wide box, a small (far) hand a tight one, so the sweep needed to cross
    /// the screen feels the same at any distance from the camera. Default.
    case auto
    /// `interactionBox` verbatim — the Reach slider, and nothing else.
    case manual
}

/// Tunables for the (deliberately minimal) gesture engine: the palm moves the
/// cursor, dipping the index finger clicks/drags, a second finger's dip
/// right-clicks, and the scroll pose scrolls. Thresholds, smoothing, and
/// slot-tracking defaults come from sporecaster's tuned values.
public struct GestureConfig: Codable, Equatable, Sendable {
    // MARK: Control trigger
    /// What arms cursor control: `.openHand` requires showing an open hand
    /// before the cursor follows; `.anyHand` follows any tracked hand.
    public var controlTrigger: ControlTrigger = .openHand

    // MARK: Click detection
    /// Scale for a *finger dip* ratio: the tip→knuckle differential idles
    /// near 1.0 and drops to ~0.5 when the finger taps down (0.45 × 1.5 =
    /// 0.675 at the default slider position). Shared by the index-tap left
    /// button and the right-click dip, so both buttons stay on the same
    /// sensitivity slider.
    public static let dipEngageFactor = 1.5
    /// The sensitivity slider (the name predates the index-tap model — this
    /// was once a raw thumb–index pinch distance, and keeping the key keeps
    /// everyone's saved tuning). Lower = the finger must dip further before a
    /// click fires.
    public var pinchEngageRatio: Double = 0.45
    /// How much past the engage threshold the ratio must recover to release.
    /// Deliberately small so engaging and releasing feel like the same
    /// distance; just enough band remains to stop boundary chatter, and
    /// smoothing and the debounce handle the rest.
    public var pinchReleaseHysteresis: Double = 0.08
    /// The release threshold tracks the engage threshold (and therefore the
    /// sensitivity slider).
    public var pinchReleaseRatio: Double { pinchEngageRatio + pinchReleaseHysteresis }
    /// What the engine compares the index-tap differential against: the
    /// slider scaled into the dip's range.
    public var engageRatio: Double { pinchEngageRatio * Self.dipEngageFactor }
    /// Release tracks engage by the same hysteresis.
    public var releaseRatio: Double { engageRatio + pinchReleaseHysteresis }
    /// Consecutive frames past a threshold before the transition fires, in
    /// *both* directions. sporecaster needed none on MediaPipe; Vision's
    /// landmarks spike often enough that single-frame noise must not click.
    public var pinchDebounceFrames: Int = 2

    // MARK: Right click
    /// Dip a second finger to press the right button. The open index-tap hand
    /// leaves a lone finger's drop unambiguous.
    public var rightClickEnabled: Bool = true
    /// Whose dip right-clicks. The little finger is the one the click doesn't
    /// use, and dropping it barely disturbs the rest of the hand — but it
    /// can never be the finger already pressing the left button, so setting
    /// this to `.index` simply turns right-click off.
    public var rightClickFinger: Finger = .little
    /// The right-click dip rides the same sensitivity slider and dip factor
    /// as the left button.
    public var rightEngageRatio: Double { pinchEngageRatio * Self.dipEngageFactor }
    /// Release tracks engage by the same hysteresis as the left button.
    public var rightReleaseRatio: Double { rightEngageRatio + pinchReleaseHysteresis }

    // MARK: Scroll
    /// Fold the middle and ring fingers in — index and little stay up — and
    /// vertical hand movement scrolls instead of moving the cursor (which
    /// parks while the pose is held).
    public var scrollEnabled: Bool = true
    /// Flip which way the page moves relative to the hand. Off: hand up =
    /// scroll up (`.scroll` deltas are positive-up wheel units).
    public var scrollInvert: Bool = false

    // MARK: Dwell click
    /// Click by holding still: with cursor control armed and no button down,
    /// keeping the cursor inside a small radius for `dwellSeconds` emits one
    /// left click at the settled spot. The cursor must then leave that radius
    /// before another dwell can begin — re-arm by movement, so resting in
    /// place clicks exactly once, never a stream. The accessibility path for
    /// hands that can't manage a crisp index dip; off by default.
    public var dwellClickEnabled: Bool = false
    /// How long the cursor must hold still before the dwell click fires.
    public var dwellSeconds: TimeInterval = 1.0

    // MARK: Tracking-off wave
    /// Hold up both hands open with fingers spread wide (a double high-five)
    /// and cross them over each other back and forth to switch hand tracking
    /// off entirely — the same full stop as the menu bar toggle. Optional,
    /// on by default.
    public var crissCrossDisableEnabled: Bool = true
    /// How many times the hands must trade sides before tracking switches
    /// off. Two is one full wave: cross over, then back.
    public var crissCrossDisableCrossings: Int = 2

    // MARK: Click timing
    /// Two clicks within this interval (and within `doubleClickSlop`) become a
    /// double-click (macOS default ballpark).
    public var doubleClickInterval: TimeInterval = 0.45
    /// Max cursor travel (screen-normalized) between clicks that still chains
    /// into a double-click.
    public var doubleClickSlop: Double = 0.025
    /// Cursor travel (screen-normalized) beyond which a pinch starts dragging.
    /// Below this the cursor holds still, so quick clicks don't micro-drag.
    public var dragActivationDistance: Double = 0.010
    /// Tap window: for this long after the button goes down, nothing drags and
    /// the cursor stays pinned at the press point. Movement alone was starting
    /// drags, which turned nearly every quick click into a micro-drag — a hand
    /// in the air always drifts a little while the fingers close and open.
    public var dragStartDelay: TimeInterval = 0.30
    /// Travel inside the tap window that means the drag is deliberate (a flick,
    /// not press wobble), starting the drag immediately.
    public var dragIntentDistance: Double = 0.030
    /// Minimum travel between emitted drag positions. Overlapping fingertips
    /// confuse Vision, so a held pinch shivers by a fraction of a percent;
    /// re-emitting that shiver reads as a shaking drag. Plain moves use half
    /// this, enough to kill stationary shimmer without feeling sticky.
    public var jitterDeadband: Double = 0.004

    // MARK: Pointer
    /// The landmark the cursor rides. The palm is the default because it is
    /// the one part of the hand no click gesture moves (see AGENTS.md); the
    /// fingertip sources are more direct but wobble whenever a finger dips,
    /// so they suit control styles whose clicks move no fingers — dwell
    /// clicking above all.
    public var pointerSource: PointerSource = .palmCenter
    /// sporecaster's landmark tuning, applied to every joint. Vision is noisier
    /// than MediaPipe, so this is the floor for smoothing, not the ceiling.
    public var smoothing: OneEuroFilter.Params = .landmark

    // MARK: Pose classification thresholds (used by hand features)
    public var poseThresholds: PoseThresholds = PoseThresholds()

    // MARK: Tracking robustness
    public var minHandConfidence: Double = 0.30
    public var minJointConfidence: Double = 0.25
    /// If tracking drops out mid-pinch, keep state alive this long before
    /// releasing the button (sporecaster resets slots at 300 ms).
    public var trackingLossGrace: TimeInterval = 0.30

    // MARK: Mapping
    /// The manual box, and the starting point the automatic one drifts from.
    public var interactionBox: InteractionBox = .default
    /// Whether the engine sizes the box to the hand it can see (`.auto`) or
    /// uses `interactionBox` verbatim (`.manual`).
    public var reachMode: ReachMode = .auto
    public var mirrorCamera: Bool = true

    public init() {}

    public static let `default` = GestureConfig()

    enum CodingKeys: String, CodingKey {
        case controlTrigger
        case pinchEngageRatio, pinchReleaseHysteresis, pinchDebounceFrames
        case rightClickEnabled, rightClickFinger
        case scrollEnabled, scrollInvert
        case dwellClickEnabled, dwellSeconds
        case crissCrossDisableEnabled, crissCrossDisableCrossings
        case doubleClickInterval, doubleClickSlop, dragActivationDistance
        case dragStartDelay, dragIntentDistance, jitterDeadband
        case pointerSource, smoothing, poseThresholds
        case minHandConfidence, minJointConfidence, trackingLossGrace
        case interactionBox, reachMode, mirrorCamera
    }

    /// Field-tolerant decoding: unknown/missing/mistyped fields (including
    /// keys from retired gestures) keep defaults instead of failing the tree.
    ///
    /// Every *numeric* field is additionally clamped to a sane range after
    /// decoding — a well-typed value still isn't validated by `Codable`, and
    /// an out-of-range one can wedge the engine rather than merely fail to
    /// apply (measured: `pinchEngageRatio: 5.0` clicks an idle hand
    /// immediately and makes the release threshold physically unreachable,
    /// so the button never comes back up). Ranges come from the matching
    /// settings-UI slider where `SettingsView` has one; where it doesn't,
    /// from the field's own doc comment above. See `Comparable.clamped(to:)`.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(ControlTrigger.self, forKey: .controlTrigger) { controlTrigger = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .pinchEngageRatio) {
            // Settings → Mouse → "Sensitivity" slider (`range: 0.30...0.60`).
            // This is the reproduced bug: unclamped, 5.0 makes engageRatio
            // (×1.5) exceed any real hand's idle ratio, so every hand reads
            // as already-clicked, and releaseRatio becomes unreachable.
            pinchEngageRatio = v.clamped(to: 0.30...0.60)
        }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .pinchReleaseHysteresis) {
            // No slider. `pinchReleaseRatio` = engage + this, and it must
            // stay reachable by a real hand (idle ratio ~1.0) even at the
            // engage slider's max (0.90) — the same "unreachable release"
            // hazard as pinchEngageRatio, one field over. 0 is a legal
            // (if chattery) floor; 0.2 keeps the worst case at 1.10.
            pinchReleaseHysteresis = v.clamped(to: 0...0.2)
        }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .pinchDebounceFrames) {
            // No slider (fixed at 2). Must stay ≥ 1: "0 or negative disables
            // all debounce" is this field's own version of the same hazard.
            // Capped at 10 (~0.33 s at 30 fps) so a runaway value can't
            // silently disable clicking, scrolling and the criss-cross wave
            // in the other direction (frame counts that can never accrue).
            pinchDebounceFrames = v.clamped(to: 1...10)
        }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .rightClickEnabled) { rightClickEnabled = v }
        if let v = try? c.decodeIfPresent(Finger.self, forKey: .rightClickFinger) { rightClickFinger = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .scrollEnabled) { scrollEnabled = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .scrollInvert) { scrollInvert = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .dwellClickEnabled) { dwellClickEnabled = v }
        if let v = try? c.decodeIfPresent(TimeInterval.self, forKey: .dwellSeconds) {
            // Settings → Mouse → "Dwell time" slider (`range: 0.5...3.0`).
            // A negative or zero dwell would fire the instant the cursor
            // settles — the wedge class the sibling clamps exist for.
            dwellSeconds = v.clamped(to: 0.5...3.0)
        }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .crissCrossDisableEnabled) { crissCrossDisableEnabled = v }
        // The pointer source is an enum: an unknown raw value already fails
        // decode and keeps the palm default, so there is no range to clamp.
        if let v = try? c.decodeIfPresent(PointerSource.self, forKey: .pointerSource) { pointerSource = v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .crissCrossDisableCrossings) {
            // Settings → Tracking → "Crossings required" stepper (`in: 1...6`).
            crissCrossDisableCrossings = v.clamped(to: 1...6)
        }
        if let v = try? c.decodeIfPresent(TimeInterval.self, forKey: .doubleClickInterval) {
            // No slider. "macOS default ballpark" per the doc comment above;
            // 0.1...1.5 s is a generous margin around that ballpark without
            // letting the window collapse to zero or run away indefinitely.
            doubleClickInterval = v.clamped(to: 0.1...1.5)
        }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .doubleClickSlop) {
            // No slider. Screen-normalized travel; 0.2 (a fifth of the
            // screen) is already far past any useful slop over the 0.025
            // default, and 0 is a legal (strict) floor.
            doubleClickSlop = v.clamped(to: 0...0.2)
        }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .dragActivationDistance) {
            // No slider. Screen-normalized travel; same reasoning as
            // doubleClickSlop, generous headroom over the 0.010 default.
            dragActivationDistance = v.clamped(to: 0...0.1)
        }
        if let v = try? c.decodeIfPresent(TimeInterval.self, forKey: .dragStartDelay) {
            // Settings → Mouse → "Click vs. grab" slider (`range: 0...0.6`).
            dragStartDelay = v.clamped(to: 0...0.6)
        }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .dragIntentDistance) {
            // No slider. Screen-normalized travel, generous headroom over
            // the 0.030 default (kept above dragActivationDistance's own
            // ceiling, matching the "further than activation" semantics).
            dragIntentDistance = v.clamped(to: 0...0.15)
        }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .jitterDeadband) {
            // No slider. The reproduced bug's sibling hazard: "negative
            // jitterDeadband floods move events." 0.05 keeps the ceiling
            // well short of making the cursor feel stuck (default 0.004).
            jitterDeadband = v.clamped(to: 0...0.05)
        }
        if let v = try? c.decodeIfPresent(OneEuroFilter.Params.self, forKey: .smoothing) { smoothing = v }
        if let v = try? c.decodeIfPresent(PoseThresholds.self, forKey: .poseThresholds) { poseThresholds = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .minHandConfidence) {
            // No slider. A Vision confidence score, physically bounded to
            // [0, 1] — `frame.hands.filter { $0.confidence >= … }` drops
            // every hand forever if this decodes above 1.0.
            minHandConfidence = v.clamped(to: 0...1)
        }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .minJointConfidence) {
            // No slider. Same [0, 1] confidence semantics as minHandConfidence.
            minJointConfidence = v.clamped(to: 0...1)
        }
        if let v = try? c.decodeIfPresent(TimeInterval.self, forKey: .trackingLossGrace) {
            // No slider. The reproduced bug's other sibling: "negative
            // trackingLossGrace releases held buttons on every one-frame
            // dropout." Capped at 5 s so a runaway value can't leave a
            // button held long after the hand — and the user — are gone.
            trackingLossGrace = v.clamped(to: 0...5)
        }
        if let v = try? c.decodeIfPresent(InteractionBox.self, forKey: .interactionBox) { interactionBox = v }
        if let v = try? c.decodeIfPresent(ReachMode.self, forKey: .reachMode) { reachMode = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .mirrorCamera) { mirrorCamera = v }
    }
}
