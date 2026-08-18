import PawvisCore
import SwiftUI

/// A trained gesture's icon: its own recorded motion, replayed. The palm dot
/// rides the learned trajectory (drawn as a faint trail) with the five
/// fingertip dots around it in the finger colors — the same dots the trainer
/// showed while recording, so a gesture is recognizable as *yours* at a
/// glance in a way no stock glyph could be.
struct TrainedGestureBadge: View {
    let gesture: TrainedGesture
    var size: CGFloat = 44

    /// Template-space bounds, computed once per gesture so every keyframe
    /// fits the badge box.
    private let fit: Fit

    init(gesture: TrainedGesture, size: CGFloat = 44) {
        self.gesture = gesture
        self.size = size
        self.fit = Fit(gesture: gesture)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, canvasSize in
                let cycle = max(gesture.duration, 0.8)
                let period = cycle + 0.7 // a beat of rest between replays
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period)
                let progress = min(elapsed / cycle, 1)

                // The palm's whole path first, as a faint trail per hand.
                for hand in 0..<gesture.handCount {
                    var trail = Path()
                    var started = false
                    for frame in gesture.template {
                        guard let palm = fit.palm(in: frame, hand: hand) else { continue }
                        let point = place(palm, in: canvasSize)
                        if started {
                            trail.addLine(to: point)
                        } else {
                            trail.move(to: point)
                            started = true
                        }
                    }
                    context.stroke(trail, with: .color(PawvisTheme.accentUI.opacity(0.35)),
                                   lineWidth: 1)
                }

                // The moving frame: palm ring + fingertip dots.
                let frame = interpolatedFrame(at: progress)
                for hand in 0..<gesture.handCount {
                    guard let palm = fit.palm(in: frame, hand: hand),
                          let points = GestureTrace.handPoints(
                              in: frame, hand: hand, handCount: gesture.handCount) else { continue }
                    let palmPoint = place(palm, in: canvasSize)
                    let ring = 0.16 * size
                    context.stroke(
                        Path(ellipseIn: CGRect(x: palmPoint.x - ring / 2, y: palmPoint.y - ring / 2,
                                               width: ring, height: ring)),
                        with: .color(PawvisTheme.accentUI), lineWidth: max(size / 30, 1.2))
                    for (index, tip) in points.tips.enumerated() {
                        let dot = place(palm + tip, in: canvasSize)
                        let radius = 0.055 * size
                        context.fill(
                            Path(ellipseIn: CGRect(x: dot.x - radius, y: dot.y - radius,
                                                   width: radius * 2, height: radius * 2)),
                            with: .color(PawvisTheme.fingerDotsUI[index]))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(gesture.name), a recorded gesture")
    }

    private func interpolatedFrame(at progress: Double) -> [Double] {
        let template = gesture.template
        guard template.count > 1 else { return template.first ?? [] }
        let raw = progress * Double(template.count - 1)
        let index = min(Int(raw), template.count - 2)
        let fraction = raw - Double(index)
        let a = template[index], b = template[index + 1]
        return (0..<min(a.count, b.count)).map { a[$0] + (b[$0] - a[$0]) * fraction }
    }

    private func place(_ point: Vec2, in canvasSize: CGSize) -> CGPoint {
        let normalized = fit.normalize(point)
        return CGPoint(x: normalized.x * canvasSize.width,
                       y: normalized.y * canvasSize.height)
    }

    /// Template-space framing: every palm position and fingertip across
    /// every keyframe, padded, mapped to the unit square.
    private struct Fit {
        private var center = Vec2(0, 0)
        private var extent = 1.0
        private let handCount: Int

        init(gesture: TrainedGesture) {
            handCount = gesture.handCount
            var minX = Double.infinity, minY = Double.infinity
            var maxX = -Double.infinity, maxY = -Double.infinity
            for frame in gesture.template {
                for hand in 0..<gesture.handCount {
                    guard let palm = Self.palmPosition(in: frame, hand: hand,
                                                       handCount: gesture.handCount),
                          let points = GestureTrace.handPoints(
                              in: frame, hand: hand, handCount: gesture.handCount) else { continue }
                    for tip in points.tips {
                        let p = palm + tip
                        minX = min(minX, p.x); maxX = max(maxX, p.x)
                        minY = min(minY, p.y); maxY = max(maxY, p.y)
                    }
                    minX = min(minX, palm.x); maxX = max(maxX, palm.x)
                    minY = min(minY, palm.y); maxY = max(maxY, palm.y)
                }
            }
            guard minX < maxX else { return }
            center = Vec2((minX + maxX) / 2, (minY + maxY) / 2)
            extent = max(maxX - minX, maxY - minY, 0.5) * 1.25
        }

        func normalize(_ point: Vec2) -> Vec2 {
            Vec2((point.x - center.x) / extent + 0.5,
                 (point.y - center.y) / extent + 0.5)
        }

        func palm(in frame: [Double], hand: Int) -> Vec2? {
            Self.palmPosition(in: frame, hand: hand, handCount: handCount)
        }

        static func palmPosition(in frame: [Double], hand: Int, handCount: Int) -> Vec2? {
            guard let own = GestureTrace.handPoints(in: frame, hand: hand,
                                                    handCount: handCount) else { return nil }
            guard hand == 1 else { return own.palmTravel }
            // The second hand sits at the pair separation from the first.
            let separationBase = 2 * GestureTrace.dimsPerHand
            guard frame.count >= separationBase + 2,
                  let first = GestureTrace.handPoints(in: frame, hand: 0, handCount: handCount)
            else { return own.palmTravel }
            return first.palmTravel + Vec2(frame[separationBase], frame[separationBase + 1])
        }
    }
}
