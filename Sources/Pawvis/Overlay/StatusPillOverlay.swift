import AppKit
import PawvisCore

/// The status notice capsule: voice-control hints ("Say “pawvis …”"), transient
/// confirmations, and the Accessibility warning.
///
/// Notices are advice, not state — each shows for
/// `StatusPillPolicy.defaultAutoDismiss` seconds and then gets out of the way,
/// and the ✕ retires one early. Both paths run through `StatusPillPolicy`
/// because `present` is called from the per-frame render loop: without it a
/// dismissed notice would reappear on the next camera frame.
///
/// It's a panel of its own rather than a layer in the gesture overlay because
/// that window is click-through, and nothing drawn in it can be clicked away.
@MainActor
final class StatusPillOverlay {
    struct Notice: Equatable {
        var text: String
        var background: NSColor
    }

    var showInScreenCapture = false {
        didSet { capsule.showInScreenCapture = showInScreenCapture }
    }

    private var policy = StatusPillPolicy()
    // Sits below the transcript capsule, which owns the strip under the menu bar.
    private let capsule = CapsulePanel(
        font: .systemFont(ofSize: 13, weight: .semibold), topInset: 56, maxLines: 2)

    init() {
        capsule.onDismiss = { [weak self] in
            self?.policy.dismiss()
        }
    }

    /// Called every frame with whatever the overlay wants to say (nil = nothing
    /// to say). `now` is the frame timestamp.
    func present(_ notice: Notice?, now: TimeInterval) {
        guard let notice, let text = policy.display(notice.text, now: now) else {
            capsule.hide()
            return
        }
        capsule.show(text, background: notice.background)
    }

    /// Tracking stopped, or the pill was switched off: clear the slate so the
    /// next notice shows fresh with a full countdown.
    func hide() {
        policy.reset()
        capsule.hide()
    }
}
