import AVFoundation
import PawvisCore
import SwiftUI

// MARK: - The trainer window
//
// "Train New Gesture" opens this: a live mirror of the camera with the
// tracked landmarks drawn over it (a color per finger, the palm in accent),
// and a take-by-take flow on the right — arm, perform, repeat 3–10 times —
// until the takes agree well enough to become a matchable template. While
// the window is open, Pawvis control is suspended entirely: the cursor,
// clicks, and every other gesture stand down so training can't fight the
// motions it is recording (`PawvisController.beginTraining`).

/// Opening the trainer from code, same pattern (and reason) as GuideWindow.
@MainActor
enum TrainerWindow {
    static let id = "gesture-trainer"

    static var opener: OpenWindowAction?

    static func show() {
        opener?(id: id)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Model

@MainActor
final class GestureTrainerModel: ObservableObject {
    enum Phase: Equatable {
        case setup
        case counting(Int)
        /// Recorder armed: perform the gesture whenever ready.
        case waiting
        case capturing
        case reviewing
    }

    @Published private(set) var phase: Phase = .setup
    @Published var handCount = 1 {
        didSet { if handCount != oldValue { resetTakes() } }
    }
    @Published var name = ""
    @Published private(set) var takes: [GestureTake] = []
    @Published private(set) var verdict: TrainedGestureBuilder.Verdict = .needsMoreTakes(have: 0)
    @Published private(set) var lastDiscard: String?
    @Published private(set) var liveHands: [Hand] = []
    /// Set briefly when the draft gesture matches in the try-it phase.
    @Published private(set) var matchFlashUntil: Date = .distantPast
    @Published private(set) var saved = false

    private let controller: PawvisController
    private let recorder = TakeRecorder()
    private let testDetector = TrainedGestureDetector()
    private var draft: TrainedGestureBuilder.Build?
    private let draftID = UUID()
    private var countdownTimer: Timer?

    init(controller: PawvisController) {
        self.controller = controller
    }

    var isReady: Bool {
        if case .ready = verdict { return true }
        return false
    }

    var canRecord: Bool {
        (phase == .setup || phase == .reviewing) && takes.count < TrainedGestureBuilder.maxTakes
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var statusLine: String {
        switch phase {
        case .setup:
            return "Frame yourself so your hand has room to move, then record your first take."
        case .counting(let n):
            return "Get ready… \(n)"
        case .waiting:
            return "Perform your gesture now (or hold the pose still)."
        case .capturing:
            return "Recording — finish the motion and hold still."
        case .reviewing:
            if let reason = lastDiscard { return reason }
            switch verdict {
            case .needsMoreTakes(let have):
                let more = TrainedGestureBuilder.minTakes - have
                return "Take saved. Record \(more) more so Pawvis can learn what stays the same."
            case .inconsistent(let worst):
                return "Take \(worst + 1) disagrees with the rest — remove it, or record a few more."
            case .ready:
                return "Looking good — try the gesture live, and save when it matches reliably."
            }
        }
    }

    // MARK: Lifecycle

    func start() {
        // The window scene reuses one model across open/close cycles:
        // every opening is a fresh training session.
        phase = .setup
        takes = []
        name = ""
        lastDiscard = nil
        saved = false
        liveHands = []
        reverdict()
        controller.beginTraining()
        controller.trainingFrameTap = { [weak self] hands, time in
            self?.consume(hands: hands, at: time)
        }
    }

    func stop() {
        countdownTimer?.invalidate()
        controller.endTraining()
    }

    // MARK: Takes

    func record() {
        guard canRecord else { return }
        lastDiscard = nil
        phase = .counting(3)
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { return timer.invalidate() }
                guard case .counting(let n) = self.phase else { return timer.invalidate() }
                if n > 1 {
                    self.phase = .counting(n - 1)
                } else {
                    timer.invalidate()
                    self.recorder.begin(handCount: self.handCount, at: CACurrentMediaTime())
                    self.phase = .waiting
                }
            }
        }
    }

    func cancelRecording() {
        countdownTimer?.invalidate()
        recorder.cancel()
        phase = takes.isEmpty ? .setup : .reviewing
    }

    func removeTake(at index: Int) {
        guard takes.indices.contains(index) else { return }
        takes.remove(at: index)
        reverdict()
    }

    private func resetTakes() {
        takes = []
        lastDiscard = nil
        recorder.cancel()
        phase = .setup
        reverdict()
    }

    // MARK: Saving

    /// Append the learned gesture to settings; the Gestures tab picks it up
    /// immediately. Unassigned until the user gives it an action there.
    func save() -> Bool {
        guard case .ready(let build) = verdict else { return false }
        let fallback = "My gesture \(controller.settingsStore.settings.trainedGestures.gestures.count + 1)"
        let gesture = TrainedGesture(
            name: trimmedName.isEmpty ? fallback : trimmedName,
            handCount: handCount,
            template: build.template,
            duration: build.duration,
            baseThreshold: build.baseThreshold)
        controller.settingsStore.settings.trainedGestures.gestures.append(gesture)
        saved = true
        return true
    }

    // MARK: Frames

    private func consume(hands: [Hand], at time: TimeInterval) {
        liveHands = hands
        let minConfidence = controller.settingsStore.settings.gestures.minJointConfidence
        let snapshots = hands.compactMap {
            GestureTrace.snapshot(of: $0, minJointConfidence: minConfidence)
        }

        switch phase {
        case .waiting, .capturing:
            guard let event = recorder.feed(snapshots, at: time) else { return }
            switch event {
            case .started:
                phase = .capturing
            case .finished(let take):
                takes.append(take)
                lastDiscard = nil
                reverdict()
                phase = .reviewing
            case .discarded(let reason):
                lastDiscard = reason
                phase = .reviewing
            }

        case .reviewing:
            // The try-it loop: the draft template runs through the real
            // detector, so "it matches here" means it will match in use.
            guard draft != nil else { return }
            let fired = testDetector.process(
                hands: hands.enumerated().map {
                    TrainedGestureDetector.HandInput(slot: $0.offset, hand: $0.element)
                },
                context: CustomGestureDetector.Context(
                    time: time,
                    thresholds: controller.settingsStore.settings.gestures.poseThresholds,
                    minJointConfidence: minConfidence,
                    trackingLossGrace: 0.3,
                    pressOrScrollActive: false,
                    crissCrossEngaged: false))
            if !fired.isEmpty {
                matchFlashUntil = Date().addingTimeInterval(1.0)
            }

        case .setup, .counting:
            break
        }
    }

    private func reverdict() {
        verdict = TrainedGestureBuilder.verdict(takes: takes)
        if case .ready(let build) = verdict {
            draft = build
            var config = TrainedGestureDetector.Config()
            config.gestures = [TrainedGestureDetector.Compiled(
                id: draftID, handCount: handCount, template: build.template,
                duration: build.duration,
                // The default-sensitivity threshold, same as a fresh save.
                threshold: build.baseThreshold * 1.15)]
            testDetector.config = config
        } else {
            draft = nil
            testDetector.config = TrainedGestureDetector.Config()
        }
    }
}

// MARK: - View

struct GestureTrainerView: View {
    @ObservedObject var controller: PawvisController
    @StateObject private var model: GestureTrainerModel
    @Environment(\.dismiss) private var dismiss

    init(controller: PawvisController) {
        self.controller = controller
        _model = StateObject(wrappedValue: GestureTrainerModel(controller: controller))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            preview
                .frame(minWidth: 430, maxWidth: .infinity)
            controls
                .frame(width: 270)
        }
        .padding(14)
        .frame(minWidth: 760, minHeight: 480)
        .tint(PawvisTheme.accentUI)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: Camera side

    private var preview: some View {
        GeometryReader { geometry in
            let videoRect = Self.videoRect(in: geometry.size)
            ZStack {
                CameraPreview(controller: controller)
                LandmarkDots(hands: model.liveHands, videoRect: videoRect)
            }
            // One flip mirrors the video and the dots together — the
            // preview behaves like a mirror, and the two can't disagree.
            .scaleEffect(x: -1)
            .overlay(statusOverlay(videoRect: videoRect))
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.85)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .aspectRatio(16 / 9, contentMode: .fit)
    }

    /// Where the aspect-fit 16:9 video lands inside the view.
    static func videoRect(in size: CGSize) -> CGRect {
        let aspect: CGFloat = 16 / 9
        var rect = CGRect(origin: .zero, size: size)
        if size.width / size.height > aspect {
            let width = size.height * aspect
            rect = CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        } else {
            let height = size.width / aspect
            rect = CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        }
        return rect
    }

    @ViewBuilder
    private func statusOverlay(videoRect: CGRect) -> some View {
        VStack {
            if case .counting(let n) = model.phase {
                Text("\(n)")
                    .font(.system(size: 90, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .transition(.scale)
            } else if model.phase == .capturing {
                Label("Recording", systemImage: "record.circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(PawvisTheme.attentionUI.opacity(0.85)))
            } else if model.phase == .waiting {
                Text("Go ahead — perform your gesture")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.55)))
            } else if Date() < model.matchFlashUntil {
                Label("Matched!", systemImage: "checkmark.circle.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.green.opacity(0.8)))
            }
            Spacer()
            if model.liveHands.isEmpty {
                Text("Show your hand\(model.handCount == 2 ? "s" : "") to the camera")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.bottom, 12)
            }
        }
        .padding(.top, 18)
        .animation(.easeOut(duration: 0.15), value: model.phase)
    }

    // MARK: Controls side

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Train a Gesture").font(.title2.bold())

            Picker("", selection: $model.handCount) {
                Text("One hand").tag(1)
                Text("Two hands").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!model.takes.isEmpty)

            TextField("Name — e.g. Finger snap", text: $model.name)
                .textFieldStyle(.roundedBorder)

            Text(model.statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 48, alignment: .top)

            if model.phase == .waiting || model.phase == .capturing {
                Button("Cancel this take") { model.cancelRecording() }
            } else {
                Button(model.takes.isEmpty ? "Record first take" : "Record another take") {
                    model.record()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRecord)
            }

            if !model.takes.isEmpty {
                takeChips
            }

            Spacer()

            if model.isReady {
                Label("Try it live — perform the gesture and watch for the match flash.",
                      systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Save Gesture") {
                    if model.save() { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isReady)
                Button("Cancel") { dismiss() }
            }

            Text("Pawvis control is paused while this window is open. Assign an action to the saved gesture in Settings → Gestures.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var takeChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Takes (\(model.takes.count) of \(TrainedGestureBuilder.maxTakes))")
                .font(.caption)
                .foregroundStyle(.secondary)
            FlowLayoutLite(spacing: 6) {
                ForEach(Array(model.takes.enumerated()), id: \.offset) { index, take in
                    HStack(spacing: 4) {
                        Text("Take \(index + 1) · \(String(format: "%.1fs", take.duration))")
                            .font(.caption)
                        Button {
                            model.removeTake(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.quaternary.opacity(0.6)))
                }
            }
        }
    }
}

/// A minimal wrapping layout for the take chips.
private struct FlowLayoutLite: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 260
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Camera preview + landmarks

/// The AVCaptureVideoPreviewLayer host. Unmirrored — the SwiftUI parent
/// flips the whole stack.
private struct CameraPreview: NSViewRepresentable {
    let controller: PawvisController

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.attach(layer: controller.makeTrainingPreviewLayer())
        return view
    }

    func updateNSView(_ nsView: PreviewHostView, context: Context) {}

    final class PreviewHostView: NSView {
        private var previewLayer: AVCaptureVideoPreviewLayer?

        func attach(layer: AVCaptureVideoPreviewLayer) {
            wantsLayer = true
            self.layer = CALayer()
            self.layer?.addSublayer(layer)
            previewLayer = layer
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}

/// The tracked landmarks over the video: one color per fingertip, the palm
/// in the accent — the same dots the trained-gesture badge animates.
private struct LandmarkDots: View {
    let hands: [Hand]
    let videoRect: CGRect

    private static let tips: [HandJoint] = [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]

    var body: some View {
        Canvas { context, _ in
            for hand in hands {
                for (index, joint) in Self.tips.enumerated() {
                    guard let point = hand.point(for: joint, minConfidence: 0.2) else { continue }
                    let center = place(point)
                    context.fill(
                        Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)),
                        with: .color(PawvisTheme.fingerDotsUI[index]))
                }
                if let wrist = hand.point(for: .wrist, minConfidence: 0.2),
                   let knuckle = hand.point(for: .middleMCP, minConfidence: 0.2) {
                    let palm = place(wrist.midpoint(with: knuckle))
                    context.stroke(
                        Path(ellipseIn: CGRect(x: palm.x - 7, y: palm.y - 7, width: 14, height: 14)),
                        with: .color(PawvisTheme.accentUI), lineWidth: 3)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func place(_ point: Vec2) -> CGPoint {
        CGPoint(x: videoRect.minX + point.x * videoRect.width,
                y: videoRect.minY + point.y * videoRect.height)
    }
}
