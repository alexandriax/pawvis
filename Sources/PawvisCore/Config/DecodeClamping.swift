import Foundation

/// The shared guard every tolerant settings decoder applies to a numeric
/// field right after decoding it, so a hand-edited or corrupted settings
/// file can only ever produce a value the field's own settings-UI slider
/// (or, where none exists, its documented semantics) would have allowed.
///
/// Field-tolerant decoding (`GestureConfig`, `CustomGestureSettings`,
/// `VoiceControlConfig`, …) exists to survive a bad settings file: an
/// unknown, missing, or mistyped key keeps its default instead of failing
/// the whole tree. But a *well-typed, out-of-range* number used to decode
/// cleanly and hand the raw value straight to the engine — and the engine
/// never validates its own tuning, because that is what the tolerant
/// decoder was supposed to have done. `pinchEngageRatio: 5.0` is the
/// measured case: it decoded fine, and the resulting release threshold
/// became physically unreachable, wedging the left mouse button down for
/// the rest of the session. Clamping once, here, at decode time, is
/// cheaper than teaching every consumer in the engine to defend itself
/// against a setting no slider could ever have produced.
extension Comparable {
    /// `self`, pulled inside `range` if it falls outside it.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
