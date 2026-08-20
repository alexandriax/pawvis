import CoreMedia
import Foundation
import PawvisCore
import Vision

/// Runs Vision's face detector on camera frames and reduces the result to
/// the one question the attention gate asks: is someone facing the screen,
/// and how far off-axis is their head?
///
/// Face *rectangles*, not landmarks: revision 3 reports roll/yaw/pitch on
/// the detection itself, and head pose is the robust proxy for "looking at
/// the screen" — pupil-level gaze from the landmarks request is noisy at
/// webcam distance and costs far more per frame.
final class FaceAttentionService {
    private let request: VNDetectFaceRectanglesRequest

    /// Same single reused sequence handler as `HandTrackingService`, for the
    /// same reason: a fresh `VNImageRequestHandler` re-pays its setup cost
    /// every frame.
    private let sequenceHandler = VNSequenceRequestHandler()

    init() {
        request = VNDetectFaceRectanglesRequest()
        // Pinned, not defaulted: revision 3 is the one that reports pitch,
        // and the gate treats a missing axis as facing.
        request.revision = VNDetectFaceRectanglesRequestRevision3
    }

    /// Synchronous detection (call on the camera queue, like the hand pass).
    /// Returns nil when Vision itself errored — "I couldn't look" must hold
    /// the gate's last verdict, never read as "nobody is facing the screen".
    func observe(in sampleBuffer: CMSampleBuffer) -> AttentionGate.Observation? {
        do {
            try sequenceHandler.perform([request], on: sampleBuffer, orientation: .up)
        } catch {
            Log.tracking.error("Vision face error: \(error.localizedDescription)")
            return nil
        }
        // The largest face is the operator: whoever sits closest to the
        // camera owns the gate, so a bystander facing the screen from behind
        // can't hold it open while the user turns away.
        guard let face = request.results?.max(by: {
            $0.boundingBox.width * $0.boundingBox.height
                < $1.boundingBox.width * $1.boundingBox.height
        }) else {
            return .noFace
        }
        return AttentionGate.Observation(
            faceSeen: true,
            yaw: face.yaw?.doubleValue,
            pitch: face.pitch?.doubleValue)
    }
}
