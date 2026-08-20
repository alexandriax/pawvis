import AVFoundation
import Foundation
import PawvisCore

/// `Pawvis --attention-eval <video…> [--sensitivity 0.5] [--verbose]` — run
/// the real face-detection + attention-gate pipeline over recorded video and
/// print every open/close transition. The ground-truth harness for
/// look-to-control, same reasoning as `--gesture-eval`: synthetic tests
/// can't tell you what Vision's face detector reports for a real head
/// mid-turn (angles, dropouts, the profile where the face vanishes), but a
/// webcam recording of the actual motion can. The sensitivity mapping was
/// sanity-checked against such clips; retune the same way.
///
/// Observations are sampled one frame in `AttentionGateBox.observationStride`
/// to match the live tap; `--verbose` prints each sampled yaw/pitch (in
/// degrees, for human eyes) and the verdict it fed.
func runAttentionEval(_ args: [String]) -> Int32 {
    let verbose = args.contains("--verbose")
    var sensitivity = 0.5
    if let flagIndex = args.firstIndex(of: "--sensitivity"), args.indices.contains(flagIndex + 1),
       let value = Double(args[flagIndex + 1]) {
        sensitivity = value
    }
    let paths = args.filter { !$0.hasPrefix("--") && Double($0) == nil }
    guard !paths.isEmpty else {
        print("usage: Pawvis --attention-eval <video-file…> [--sensitivity 0…1] [--verbose]")
        return 2
    }

    var failures = 0
    for path in paths {
        print("=== \(path)")
        if !evalAttention(at: URL(fileURLWithPath: path),
                          sensitivity: sensitivity, verbose: verbose) {
            failures += 1
        }
    }
    return failures == 0 ? 0 : 1
}

private func evalAttention(at url: URL, sensitivity: Double, verbose: Bool) -> Bool {
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

    var config = AttentionConfig()
    config.enabled = true
    config.sensitivity = sensitivity
    var gate = AttentionGate(config: config.gateConfig())
    let faces = FaceAttentionService()
    let degrees = 180.0 / .pi

    print(String(format: "  sensitivity %.2f → off-angle limit %.1f°",
                 sensitivity, gate.config.maxOffAngle * degrees))

    var frames = 0
    var sampled = 0
    var faceFrames = 0
    var transitions: [(TimeInterval, Bool)] = []
    var wasAttentive = true

    while let buffer = output.copyNextSampleBuffer() {
        let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        frames += 1
        // Sample at the live tap's stride so the clip sees the cadence the
        // camera would produce.
        guard frames % AttentionGateBox.observationStride == 0 else { continue }
        sampled += 1
        guard let observation = faces.observe(in: buffer) else { continue }
        if observation.faceSeen { faceFrames += 1 }
        let attentive = gate.assess(observation, interacting: false, at: time)
        if verbose {
            let yaw = observation.yaw.map { String(format: "%+6.1f°", $0 * degrees) } ?? "  —  "
            let pitch = observation.pitch.map { String(format: "%+6.1f°", $0 * degrees) } ?? "  —  "
            print(String(format: "  %6.2fs  face %@  yaw %@  pitch %@  → %@",
                         time, observation.faceSeen ? "✓" : "✗", yaw, pitch,
                         attentive ? "attentive" : "AWAY"))
        }
        if attentive != wasAttentive {
            transitions.append((time, attentive))
            wasAttentive = attentive
        }
    }

    print("  \(frames) frames, \(sampled) sampled, \(faceFrames) with a face")
    if transitions.isEmpty {
        print("  no transitions — \(wasAttentive ? "attentive" : "away") throughout")
    }
    for (time, attentive) in transitions {
        print(String(format: "  %6.2fs  %@", time,
                     attentive ? "→ attentive (control resumes)" : "→ AWAY (control pauses)"))
    }
    return frames > 0
}
