import Foundation

/// The 21 hand landmarks shared by MediaPipe Hands and Apple's Vision
/// `VNDetectHumanHandPoseRequest` (Vision omits none of these; naming follows
/// anatomical convention: MCP = knuckle, PIP/DIP = middle joints, tip = fingertip).
public enum HandJoint: Int, CaseIterable, Codable, Sendable {
    case wrist = 0

    case thumbCMC = 1
    case thumbMP = 2
    case thumbIP = 3
    case thumbTip = 4

    case indexMCP = 5
    case indexPIP = 6
    case indexDIP = 7
    case indexTip = 8

    case middleMCP = 9
    case middlePIP = 10
    case middleDIP = 11
    case middleTip = 12

    case ringMCP = 13
    case ringPIP = 14
    case ringDIP = 15
    case ringTip = 16

    case littleMCP = 17
    case littlePIP = 18
    case littleDIP = 19
    case littleTip = 20
}

/// A non-thumb finger (the thumb has different anatomy and is handled separately).
public enum Finger: String, CaseIterable, Codable, Sendable {
    case index, middle, ring, little

    public var mcp: HandJoint {
        switch self {
        case .index: return .indexMCP
        case .middle: return .middleMCP
        case .ring: return .ringMCP
        case .little: return .littleMCP
        }
    }

    public var pip: HandJoint {
        switch self {
        case .index: return .indexPIP
        case .middle: return .middlePIP
        case .ring: return .ringPIP
        case .little: return .littlePIP
        }
    }

    public var dip: HandJoint {
        switch self {
        case .index: return .indexDIP
        case .middle: return .middleDIP
        case .ring: return .ringDIP
        case .little: return .littleDIP
        }
    }

    public var tip: HandJoint {
        switch self {
        case .index: return .indexTip
        case .middle: return .middleTip
        case .ring: return .ringTip
        case .little: return .littleTip
        }
    }
}
