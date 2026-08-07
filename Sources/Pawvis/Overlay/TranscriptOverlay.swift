import AppKit
import Foundation

/// A floating capsule at the top of the screen that shows what voice control
/// is hearing, live — white text on a rounded purple background. Independent
/// of the gesture overlay (which only renders while hand tracking runs).
///
/// Lifecycle: the text updates as an utterance streams in, then auto-hides a
/// configurable few seconds after the utterance completes — or stays until
/// dismissed, in manual-dismiss mode. Clicking it (or its ✕) always dismisses.
@MainActor
final class TranscriptOverlay {
    /// Seconds to keep the text up after an utterance completes.
    var timeout: TimeInterval = 3.0
    /// Keep the text up until it's dismissed.
    var manualDismiss = false
    /// Master switch (Settings → Voice).
    var enabled = true

    private let capsule = CapsulePanel(
        font: .systemFont(ofSize: 15, weight: .medium), topInset: 10)
    private var hideTimer: Timer?

    /// Include the capsule in screenshots/recordings (mirrors the gesture
    /// overlay's privacy default).
    var showInScreenCapture = false {
        didSet { capsule.showInScreenCapture = showInScreenCapture }
    }

    init() {
        capsule.onDismiss = { [weak self] in
            self?.hideTimer?.invalidate()
            self?.hideTimer = nil
        }
    }

    // MARK: - API

    /// Live utterance text (streaming). Stays up while speech continues.
    func showLive(_ text: String) {
        guard enabled, !text.isEmpty else { return }
        hideTimer?.invalidate()
        hideTimer = nil
        display(text)
    }

    /// The utterance finished: keep the final text up, then auto-hide
    /// (unless manual dismissal is on).
    func complete(_ text: String? = nil) {
        guard enabled else { return }
        if let text, !text.isEmpty {
            display(text)
        }
        guard capsule.isVisible else { return }
        scheduleHide(after: timeout)
    }

    /// A transient status message ("→ reddit.com", "⚠️ …") using the same
    /// capsule; auto-hides even in manual mode (it's feedback, not a record).
    func flash(_ text: String) {
        guard enabled, !text.isEmpty else { return }
        display(text)
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: max(2.0, timeout), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        capsule.hide()
    }

    // MARK: - Internals

    private func scheduleHide(after delay: TimeInterval) {
        hideTimer?.invalidate()
        hideTimer = nil
        guard !manualDismiss else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    private func display(_ text: String) {
        capsule.show(text, background: PawvisTheme.purple.withAlphaComponent(0.94))
    }
}
