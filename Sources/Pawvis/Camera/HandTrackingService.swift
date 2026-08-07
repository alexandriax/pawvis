import CoreMedia
import Foundation
import PawvisCore
import Vision

/// Runs Vision's hand pose detection on camera frames and converts the
/// observations into PawvisCore `Hand`s (camera space: normalized, y down,
/// unmirrored — the gesture engine handles mirroring and mapping).
final class HandTrackingService {
    private let request: VNDetectHumanHandPoseRequest

    /// Vision ↔ PawvisCore joint mapping (same 21 landmarks as MediaPipe).
    private static let jointMap: [(VNHumanHandPoseObservation.JointName, HandJoint)] = [
        (.wrist, .wrist),
        (.thumbCMC, .thumbCMC), (.thumbMP, .thumbMP), (.thumbIP, .thumbIP), (.thumbTip, .thumbTip),
        (.indexMCP, .indexMCP), (.indexPIP, .indexPIP), (.indexDIP, .indexDIP), (.indexTip, .indexTip),
        (.middleMCP, .middleMCP), (.middlePIP, .middlePIP), (.middleDIP, .middleDIP), (.middleTip, .middleTip),
        (.ringMCP, .ringMCP), (.ringPIP, .ringPIP), (.ringDIP, .ringDIP), (.ringTip, .ringTip),
        (.littleMCP, .littleMCP), (.littlePIP, .littlePIP), (.littleDIP, .littleDIP), (.littleTip, .littleTip),
    ]

    /// One handler reused across frames: VNImageRequestHandler is a
    /// single-image object that re-pays its setup cost every frame, while the
    /// sequence handler may cache intermediate state between frames. (The hand
    /// pose request itself is stateless either way — this is latency, not
    /// accuracy.)
    private let sequenceHandler = VNSequenceRequestHandler()

    init() {
        request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
    }

    /// Synchronous detection (call on the camera queue — its serial nature plus
    /// `alwaysDiscardsLateVideoFrames` provides natural backpressure).
    func detectHands(in sampleBuffer: CMSampleBuffer) -> [Hand] {
        do {
            try sequenceHandler.perform([request], on: sampleBuffer, orientation: .up)
        } catch {
            Log.tracking.error("Vision error: \(error.localizedDescription)")
            return []
        }
        guard let observations = request.results, !observations.isEmpty else { return [] }
        return observations.map { Self.hand(from: $0) }
    }

    static func hand(from observation: VNHumanHandPoseObservation) -> Hand {
        let chirality: Hand.Chirality
        switch observation.chirality {
        case .left: chirality = .left
        case .right: chirality = .right
        default: chirality = .unknown
        }

        var hand = Hand(chirality: chirality, confidence: Double(observation.confidence))
        guard let points = try? observation.recognizedPoints(.all) else { return hand }

        for (visionJoint, coreJoint) in jointMap {
            guard let point = points[visionJoint], point.confidence > 0 else { continue }
            // Vision: normalized, origin bottom-left → camera space (y down).
            hand.setPoint(
                Vec2(Double(point.location.x), 1.0 - Double(point.location.y)),
                for: coreJoint,
                confidence: Double(point.confidence))
        }
        return hand
    }
}
