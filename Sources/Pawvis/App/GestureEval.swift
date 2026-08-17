import AVFoundation
import Foundation
import PawvisCore

/// `Pawvis --gesture-eval <video…> [--verbose]` — run the real hand-tracking
/// and gesture pipeline over recorded video and print every custom gesture
/// that fires. The ground-truth harness for the motion gestures: synthetic
/// unit tests can't tell you what Vision does to a real hand mid-swipe
/// (it blurs, drops frames, loses joints), but a webcam recording of the
/// actual gesture can. Record a clip of the gesture, then ask the machine.
///
/// Every custom gesture is enabled at default sensitivity; the engine runs
/// its live default configuration (mirroring included, so directions come
/// out as the user would experience them for an unmirrored recording).
func runGestureEval(_ args: [String]) -> Int32 {
    let verbose = args.contains("--verbose")
    let paths = args.filter { !$0.hasPrefix("--") }
    guard !paths.isEmpty else {
        print("usage: Pawvis --gesture-eval <video-file…> [--verbose]")
        return 2
    }

    var failures = 0
    for path in paths {
        print("=== \(path)")
        if !evalVideo(at: URL(fileURLWithPath: path), verbose: verbose) {
            failures += 1
        }
    }
    return failures == 0 ? 0 : 1
}

private func evalVideo(at url: URL, verbose: Bool) -> Bool {
    let asset = AVURLAsset(url: url)
    guard let reader = try? AVAssetReader(asset: asset) else {
        print("  can't read"); return false
    }
    // Synchronous loading is fine here: this is a CLI tool, not the app path.
    guard let track = asset.tracks(withMediaType: .video).first else {
        print("  no video track"); return false
    }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    reader.add(output)
    reader.startReading()

    let tracking = HandTrackingService()
    let engine = GestureEngine(config: .default)
    var custom = CustomGestureDetector.Config()
    custom.enabled = Set(CustomGesture.allCases)
    engine.customConfig = custom

    var frames = 0
    var handFrames = 0
    var fired: [(TimeInterval, CustomGesture)] = []
    var presses = 0

    while let buffer = output.copyNextSampleBuffer() {
        let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        let hands = tracking.detectHands(in: buffer)
        frames += 1
        if !hands.isEmpty { handFrames += 1 }

        let (events, _) = engine.process(HandFrame(time: time, hands: hands))
        for event in events {
            switch event {
            case .customGesture(let gesture):
                fired.append((time, gesture))
                print(String(format: "  %6.2fs  FIRED %@", time, gesture.rawValue))
            case .buttonDown:
                presses += 1
                if verbose { print(String(format: "  %6.2fs  (buttonDown)", time)) }
            default:
                break
            }
        }

        if verbose, let hand = hands.first,
           let features = HandFeatures(hand: hand, thresholds: PoseThresholds(),
                                       minJointConfidence: 0.25) {
            let openness = features.openness().map { String(format: "%.2f", $0) } ?? "–"
            let splay = features.splayAmount().map { String(format: "%.2f", $0) } ?? "–"
            let palm = features.pointerPoint(.palmCenter)
                .map { String(format: "(%.2f,%.2f)", $0.x, $0.y) } ?? "–"
            print(String(format: "  %6.2fs  hands=%d open=%@ splay=%@ palm=%@ thumbV=%@",
                         time, hands.count, openness, splay, palm,
                         features.thumbVerticalSign().map(String.init) ?? "–"))
        }
    }

    print("  frames \(frames), with hands \(handFrames), presses \(presses)")
    if fired.isEmpty {
        print("  no custom gestures fired")
    } else {
        let summary = fired.map(\.1.rawValue).joined(separator: ", ")
        print("  fired: \(summary)")
    }
    return true
}
