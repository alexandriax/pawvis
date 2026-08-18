import Foundation
import XCTest
@testable import PawvisCore

/// The trained-gesture pipeline, end to end on synthetic hands: recording
/// takes, building templates, judging consistency, matching live — and the
/// guards (press stand-down, refractory, latch, hand-count).
final class TrainedGestureTests: XCTestCase {
    private let dt = 1.0 / 30

    // MARK: - Synthetic performances

    /// A rightward palm sweep with the hand open: `progress` 0→1.
    private func swipeHand(progress: Double) -> Hand {
        SyntheticHand.openRelaxed(wrist: Vec2(0.30 + 0.28 * progress, 0.60))
    }

    /// A fist pumped up and back down — a clearly different gesture.
    private func pumpHand(progress: Double) -> Hand {
        let lift = 0.22 * (progress < 0.5 ? progress * 2 : (1 - progress) * 2)
        return SyntheticHand.fist(wrist: Vec2(0.5, 0.62 - lift))
    }

    /// The static scroll pose, held — a pose gesture, no travel at all.
    private func poseHand() -> Hand {
        SyntheticHand.scrollPose(wrist: Vec2(0.5, 0.6))
    }

    private func snapshots(_ hands: [Hand]) -> [GestureTrace.HandSnapshot] {
        hands.compactMap { GestureTrace.snapshot(of: $0, minJointConfidence: 0.25) }
    }

    /// Record one take through the real recorder: still, perform, still.
    private func recordTake(motionFrames: Int = 15, speed: Double = 1.0,
                            hands: (Double) -> [Hand]) -> GestureTake? {
        let recorder = TakeRecorder()
        var t = 0.0
        let handCount = hands(0).count
        recorder.begin(handCount: handCount, at: t)
        var finished: GestureTake?
        for _ in 0..<8 { // settle
            _ = recorder.feed(snapshots(hands(0)), at: t)
            t += dt
        }
        let frames = max(Int(Double(motionFrames) / speed), 2)
        for i in 0..<frames {
            let event = recorder.feed(snapshots(hands(Double(i) / Double(frames - 1))), at: t)
            if case .finished(let take) = event { finished = take }
            t += dt
        }
        for _ in 0..<30 where finished == nil { // stillness ends the take
            let event = recorder.feed(snapshots(hands(1)), at: t)
            if case .finished(let take) = event { finished = take }
            t += dt
        }
        return finished
    }

    private func swipeTakes(_ count: Int) -> [GestureTake] {
        (0..<count).compactMap { i in
            recordTake(speed: 1.0 + Double(i % 3 - 1) * 0.18) { [self.swipeHand(progress: $0)] }
        }
    }

    // MARK: - Trace fundamentals

    func testSnapshotReadsTheHand() {
        let snapshot = GestureTrace.snapshot(of: SyntheticHand.openRelaxed(), minJointConfidence: 0.25)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.tipOffsets.count, 5)

        let vectors = GestureTrace.vectorize([[snapshot!]])
        XCTAssertEqual(vectors.first?.count, GestureTrace.dimsPerHand)

        let decoded = GestureTrace.handPoints(in: vectors[0], hand: 0, handCount: 1)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.tips.count, 5)
        XCTAssertEqual(decoded!.tips[1].x, snapshot!.tipOffsets[1].x, accuracy: 1e-9)
    }

    func testResampleIsUniformInTime() {
        // Two segments at very different frame rates still resample evenly.
        let vectors: [[Double]] = [[0], [0.1], [1.0]]
        let times: [TimeInterval] = [0, 0.1, 1.0]
        let resampled = GestureTrace.resample(vectors, times: times, to: 11)
        XCTAssertEqual(resampled.count, 11)
        XCTAssertEqual(resampled[5][0], 0.5, accuracy: 0.02) // halfway in time
    }

    // MARK: - Recorder

    func testRecorderSegmentsAMotionTake() {
        let recorder = TakeRecorder()
        var t = 0.0
        recorder.begin(handCount: 1, at: t)
        var events: [TakeRecorder.Event] = []
        for _ in 0..<10 { // still: nothing starts
            if let e = recorder.feed(snapshots([swipeHand(progress: 0)]), at: t) { events.append(e) }
            t += dt
        }
        XCTAssertTrue(events.isEmpty)
        for i in 0..<15 { // the sweep
            if let e = recorder.feed(snapshots([swipeHand(progress: Double(i) / 14)]), at: t) {
                events.append(e)
            }
            t += dt
        }
        XCTAssertEqual(events.first, .started)
        for _ in 0..<30 { // stillness ends it
            if let e = recorder.feed(snapshots([swipeHand(progress: 1)]), at: t) { events.append(e) }
            t += dt
        }
        guard case .finished(let take)? = events.last else {
            return XCTFail("expected a finished take, got \(events)")
        }
        XCTAssertEqual(take.handCount, 1)
        XCTAssertGreaterThan(take.duration, 0.3)
        XCTAssertLessThan(take.duration, 1.5)
    }

    func testRecorderCapturesAStaticPose() {
        // No motion ever: the held pose becomes the take after the grace.
        let recorder = TakeRecorder()
        var t = 0.0
        recorder.begin(handCount: 1, at: t)
        var finished: GestureTake?
        for _ in 0..<60 {
            if case .finished(let take)? = recorder.feed(snapshots([poseHand()]), at: t) {
                finished = take
                break
            }
            t += dt
        }
        XCTAssertNotNil(finished, "a held pose is a take too")
    }

    func testRecorderCapturesAStaticPoseAtLowFrameRate() {
        // Below ~17 fps, the old 0.35s pre-roll cap held too few frames for
        // `finish` to ever accept a static take — no matter how long the
        // pose was held, holding longer could never help. Regression for
        // that: a pose held the full static grace at 12 fps must still
        // finish with at least `minFrames` frames.
        let lowDt = 1.0 / 12
        let recorder = TakeRecorder()
        var t = 0.0
        recorder.begin(handCount: 1, at: t)
        var finished: GestureTake?
        for _ in 0..<30 {
            if case .finished(let take)? = recorder.feed(snapshots([poseHand()]), at: t) {
                finished = take
                break
            }
            t += lowDt
        }
        guard let take = finished else {
            return XCTFail("a held pose at low fps must still finish as a take")
        }
        XCTAssertGreaterThanOrEqual(take.frames.count, TakeRecorder.minFrames)
    }

    func testMotionTakeStartsNearMotionAtLowFrameRate() {
        // The waiting-phase buffer now grows all the way to the static
        // grace so a still pose can finish at low fps (above) — but a
        // motion take must still begin near the motion, not carry that
        // whole buffered window as a bloated pre-roll.
        let lowDt = 1.0 / 12
        let recorder = TakeRecorder()
        var t = 0.0
        recorder.begin(handCount: 1, at: t)
        for _ in 0..<10 { // still: short of the 1.5s static grace
            _ = recorder.feed(snapshots([swipeHand(progress: 0)]), at: t)
            t += lowDt
        }
        var startedAt: TimeInterval?
        for i in 0..<15 { // the sweep
            if case .started? = recorder.feed(snapshots([swipeHand(progress: Double(i) / 14)]), at: t) {
                startedAt = t
            }
            t += lowDt
        }
        guard let started = startedAt else { return XCTFail("expected the sweep to start the take") }
        var finished: GestureTake?
        for _ in 0..<30 where finished == nil { // stillness ends it
            if case .finished(let take)? = recorder.feed(snapshots([swipeHand(progress: 1)]), at: t) {
                finished = take
            }
            t += lowDt
        }
        guard let take = finished else { return XCTFail("expected a finished take") }
        XCTAssertLessThanOrEqual(started - take.times.first!, 0.35 + 1e-6,
            "leading stillness must be trimmed to the short pre-roll, not the full static grace")
    }

    func testRecorderDiscardsWhenTheHandVanishes() {
        let recorder = TakeRecorder()
        var t = 0.0
        recorder.begin(handCount: 1, at: t)
        _ = recorder.feed(snapshots([swipeHand(progress: 0)]), at: t)
        for i in 0..<4 { // start moving
            t += dt
            _ = recorder.feed(snapshots([swipeHand(progress: Double(i) * 0.1)]), at: t)
        }
        var discarded = false
        for _ in 0..<12 { // hand gone mid-take
            t += dt
            if case .discarded? = recorder.feed([], at: t) { discarded = true }
        }
        XCTAssertTrue(discarded)
    }

    // MARK: - Builder

    func testVerdictNeedsThreeTakes() {
        let takes = swipeTakes(2)
        XCTAssertEqual(takes.count, 2)
        XCTAssertEqual(TrainedGestureBuilder.verdict(takes: takes), .needsMoreTakes(have: 2))
    }

    func testConsistentTakesAreReady() {
        let takes = swipeTakes(4)
        XCTAssertEqual(takes.count, 4)
        guard case .ready(let build) = TrainedGestureBuilder.verdict(takes: takes) else {
            return XCTFail("consistent takes must be ready")
        }
        XCTAssertEqual(build.template.count, GestureTrace.keyframes)
        XCTAssertGreaterThanOrEqual(build.baseThreshold, 0.06)
    }

    func testOutlierTakeIsCalledOut() {
        var takes = swipeTakes(3)
        if let pump = recordTake(hands: { [self.pumpHand(progress: $0)] }) {
            takes.append(pump)
        }
        XCTAssertEqual(takes.count, 4)
        guard case .inconsistent(let worst) = TrainedGestureBuilder.verdict(takes: takes) else {
            return XCTFail("a foreign take must read as inconsistent")
        }
        XCTAssertEqual(worst, 3)
    }

    // MARK: - Live matching

    private func compiled(from takes: [GestureTake], handCount: Int = 1,
                          sensitivity: Double = 0.5,
                          holdSeconds: Double = 0) -> TrainedGestureDetector.Compiled? {
        guard let build = TrainedGestureBuilder.build(takes: takes) else { return nil }
        let gesture = TrainedGesture(
            name: "Test", handCount: handCount, template: build.template,
            duration: build.duration, baseThreshold: build.baseThreshold,
            sensitivity: sensitivity, holdSeconds: holdSeconds)
        return TrainedGestureDetector.Compiled(
            id: gesture.id, handCount: handCount, template: gesture.template,
            duration: gesture.duration, threshold: gesture.threshold,
            holdSeconds: holdSeconds)
    }

    private func context(at time: TimeInterval, press: Bool = false,
                         crissCross: Bool = false) -> CustomGestureDetector.Context {
        CustomGestureDetector.Context(
            time: time, thresholds: PoseThresholds(), minJointConfidence: 0.25,
            trackingLossGrace: 0.30, pressOrScrollActive: press, crissCrossEngaged: crissCross)
    }

    /// Feed a live performance into a detector: still lead-in, the motion,
    /// still tail. Returns every fired id.
    private func perform(_ detector: TrainedGestureDetector,
                         motionFrames: Int = 15, startAt t0: TimeInterval = 0,
                         press: Bool = false,
                         hands: (Double) -> [Hand]) -> [UUID] {
        var fired: [UUID] = []
        var t = t0
        for _ in 0..<20 {
            fired += detector.process(
                hands: snapshotInputs(hands(0)), context: context(at: t, press: press))
            t += dt
        }
        for i in 0..<motionFrames {
            fired += detector.process(
                hands: snapshotInputs(hands(Double(i) / Double(motionFrames - 1))),
                context: context(at: t, press: press))
            t += dt
        }
        for _ in 0..<25 {
            fired += detector.process(
                hands: snapshotInputs(hands(1)), context: context(at: t, press: press))
            t += dt
        }
        return fired
    }

    private func snapshotInputs(_ hands: [Hand]) -> [TrainedGestureDetector.HandInput] {
        hands.enumerated().map { TrainedGestureDetector.HandInput(slot: $0.offset, hand: $0.element) }
    }

    func testTrainedSwipeMatchesLive() {
        guard let gesture = compiled(from: swipeTakes(3)) else { return XCTFail("no build") }
        var config = TrainedGestureDetector.Config()
        config.gestures = [gesture]
        let detector = TrainedGestureDetector(config: config)

        let fired = perform(detector) { [self.swipeHand(progress: $0)] }
        XCTAssertEqual(fired, [gesture.id], "one performance, one fire")
    }

    func testDifferentMotionDoesNotMatch() {
        guard let gesture = compiled(from: swipeTakes(3)) else { return XCTFail("no build") }
        var config = TrainedGestureDetector.Config()
        config.gestures = [gesture]
        let detector = TrainedGestureDetector(config: config)

        let fired = perform(detector) { [self.pumpHand(progress: $0)] }
        XCTAssertEqual(fired, [], "a different gesture must stay silent")
    }

    func testHeldPoseFiresOnceThroughTheLatch() {
        let takes = (0..<3).compactMap { _ in recordTake { _ in [self.poseHand()] } }
        guard let gesture = compiled(from: takes) else { return XCTFail("no build") }
        var config = TrainedGestureDetector.Config()
        config.gestures = [gesture]
        let detector = TrainedGestureDetector(config: config)

        var fired: [UUID] = []
        var t = 0.0
        for _ in 0..<120 { // held for 4 s — far past the refractory
            fired += detector.process(hands: snapshotInputs([poseHand()]), context: context(at: t))
            t += dt
        }
        XCTAssertEqual(fired.count, 1, "a held pose fires once, not once per refractory")
    }

    func testPressStandsMatchingDown() {
        guard let gesture = compiled(from: swipeTakes(3)) else { return XCTFail("no build") }
        var config = TrainedGestureDetector.Config()
        config.gestures = [gesture]
        let detector = TrainedGestureDetector(config: config)

        let fired = perform(detector, press: true) { [self.swipeHand(progress: $0)] }
        XCTAssertEqual(fired, [], "presses always win")
    }

    func testMouseOverrideMatchesThroughPresses() {
        // The priority toggle: with it on, a press no longer cancels the
        // match — the fix for gestures whose own finger curl clicks.
        guard let gesture = compiled(from: swipeTakes(3)) else { return XCTFail("no build") }
        var config = TrainedGestureDetector.Config()
        config.gestures = [gesture]
        config.overridesMouse = true
        let detector = TrainedGestureDetector(config: config)

        let fired = perform(detector, press: true) { [self.swipeHand(progress: $0)] }
        XCTAssertEqual(fired, [gesture.id])
    }

    func testHoldToConfirmGatesTheFire() {
        let takes = (0..<3).compactMap { _ in recordTake { _ in [self.poseHand()] } }
        guard let gesture = compiled(from: takes, holdSeconds: 0.5) else {
            return XCTFail("no build")
        }
        var config = TrainedGestureDetector.Config()
        config.gestures = [gesture]
        let detector = TrainedGestureDetector(config: config)

        // Held only briefly: the dwell never completes, nothing fires —
        // and the dwell is visible while it runs.
        var fired: [UUID] = []
        var t = 0.0
        var sawDwell = false
        for _ in 0..<15 { // 0.5 s of pose: coverage ~0.3 s in, dwell barely starts
            fired += detector.process(hands: snapshotInputs([poseHand()]), context: context(at: t))
            if detector.holdProgress != nil { sawDwell = true }
            t += dt
        }
        for _ in 0..<20 { // hand gone
            fired += detector.process(hands: [], context: context(at: t))
            t += dt
        }
        XCTAssertEqual(fired, [], "a hold released early must not fire")
        XCTAssertTrue(sawDwell, "the dwell must be visible while it runs")

        // Held properly: exactly one fire once the dwell elapses.
        detector.reset()
        for _ in 0..<60 { // 2 s
            fired += detector.process(hands: snapshotInputs([poseHand()]), context: context(at: t))
            t += dt
        }
        XCTAssertEqual(fired.count, 1, "the completed hold fires once")
    }

    func testTwoHandGestureNeedsBothHands() {
        // Both hands sweep apart; trained as a two-hand gesture.
        func pair(_ progress: Double) -> [Hand] {
            [SyntheticHand.openRelaxed(wrist: Vec2(0.40 - 0.15 * progress, 0.6)),
             SyntheticHand.openRelaxed(wrist: Vec2(0.60 + 0.15 * progress, 0.6))]
        }
        let takes = (0..<3).compactMap { _ in recordTake { pair($0) } }
        XCTAssertEqual(takes.count, 3)
        XCTAssertEqual(takes.first?.handCount, 2)
        guard let gesture = compiled(from: takes, handCount: 2) else { return XCTFail("no build") }
        var config = TrainedGestureDetector.Config()
        config.gestures = [gesture]
        let detector = TrainedGestureDetector(config: config)

        let oneHanded = perform(detector) { [pair($0)[0]] }
        XCTAssertEqual(oneHanded, [], "half the pair is not the gesture")

        detector.reset()
        let bothHands = perform(detector) { pair($0) }
        XCTAssertEqual(bothHands, [gesture.id])
    }

    // MARK: - Settings

    func testTrainedGestureSettingsRoundTrip() {
        var settings = PawvisSettings()
        guard let build = TrainedGestureBuilder.build(takes: swipeTakes(3)) else {
            return XCTFail("no build")
        }
        settings.trainedGestures.gestures = [TrainedGesture(
            name: "Sweep right", handCount: 1, template: build.template,
            duration: build.duration, baseThreshold: build.baseThreshold,
            sensitivity: 0.7, action: GestureAction(kind: .desktopRight))]

        let data = try! JSONEncoder().encode(settings)
        let decoded = try! JSONDecoder().decode(PawvisSettings.self, from: data)
        XCTAssertEqual(decoded, settings)

        let config = decoded.trainedGestures.detectorConfig(enabled: true)
        XCTAssertEqual(config.gestures.count, 1)
        XCTAssertEqual(decoded.trainedGestures.detectorConfig(enabled: false).gestures.count, 0)
    }

    func testUnreadableTrainedRecordDropsAlone() {
        let json = """
        {"gestures": [
            {"broken": true},
            {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "Good",
             "handCount": 1, "template": [[0.1, 0.2]], "duration": 0.5,
             "baseThreshold": 0.1}
        ]}
        """
        let decoded = try! JSONDecoder().decode(TrainedGestureSettings.self,
                                                from: json.data(using: .utf8)!)
        XCTAssertEqual(decoded.gestures.count, 1)
        XCTAssertEqual(decoded.gestures.first?.name, "Good")
        XCTAssertEqual(decoded.gestures.first?.sensitivity, 0.5, "missing extras take defaults")
    }
}
