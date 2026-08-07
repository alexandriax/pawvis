import Foundation
@testable import PawvisCore

/// Builds anatomically-plausible synthetic hands in camera space (normalized,
/// y down) for driving HandFeatures and GestureEngine tests. The wrist sits at
/// `wrist`; the hand points "up" (fingers toward smaller y). `scale` is the
/// wrist→middleMCP distance, the engine's normalizer.
enum SyntheticHand {
    struct Pose {
        /// Directions are unit-ish vectors per finger; fingers are straight
        /// (extended) unless listed in `curled`.
        var fingerDirs: [Finger: Vec2]
        var curled: Set<Finger> = []
        /// Half-bent fingers (~120° at the PIP): neither extended nor curled —
        /// the natural relaxed curl people hold while pinching.
        var semiCurled: Set<Finger> = []
        /// Thumb tip offset from the wrist, in scale units. Extended thumb is
        /// far from the index knuckle; tucked thumb is close to it.
        var thumbTipOffset: Vec2
        /// When set, overrides the thumb tip to an absolute pinch position and
        /// pulls the index (or given finger) tip next to it.
        var pinch: (finger: Finger, gap: Double)?
    }

    static let relaxedDirs: [Finger: Vec2] = [
        // Slightly convergent, like a natural open hand — tips nearly touching.
        .index: Vec2(0.06, -0.998),
        .middle: Vec2(0, -1),
        .ring: Vec2(-0.03, -1),
        .little: Vec2(-0.10, -0.995),
    ]

    static let splayedDirs: [Finger: Vec2] = [
        .index: Vec2(-0.42, -0.91),
        .middle: Vec2(-0.05, -1),
        .ring: Vec2(0.25, -0.97),
        .little: Vec2(0.52, -0.86),
    ]

    static func mcpOffset(_ finger: Finger) -> Vec2 {
        switch finger {
        case .index: return Vec2(-0.25, -0.95)
        case .middle: return Vec2(0, -1.0)
        case .ring: return Vec2(0.22, -0.95)
        case .little: return Vec2(0.42, -0.85)
        }
    }

    static let thumbExtendedOffset = Vec2(-0.95, -0.70)
    static let thumbTuckedOffset = Vec2(-0.20, -0.65) // close to the index MCP

    static func build(
        pose: Pose,
        wrist: Vec2 = Vec2(0.5, 0.7),
        scale: Double = 0.15,
        chirality: Hand.Chirality = .right,
        confidence: Double = 1.0
    ) -> Hand {
        var joints: [HandJoint: Vec2] = [:]
        joints[.wrist] = wrist

        for finger in Finger.allCases {
            let mcp = wrist + mcpOffset(finger) * scale
            joints[finger.mcp] = mcp
            let dir = pose.fingerDirs[finger] ?? Vec2(0, -1)
            if pose.curled.contains(finger) {
                // Proximal segment out, then fold the tip back toward the palm.
                let pip = mcp + dir * (0.45 * scale)
                let tip = pip + Vec2(-dir.x * 0.30 + 0.10, -dir.y * 0.35) * scale
                joints[finger.pip] = pip
                joints[finger.dip] = pip.midpoint(with: tip)
                joints[finger.tip] = tip
            } else if pose.semiCurled.contains(finger) {
                // ~120° bend at the PIP — in the neutral band between the
                // extended (>2.15 rad) and curled (<1.75 rad) thresholds.
                let pip = mcp + dir * (0.45 * scale)
                let bent = Vec2(dir.x * 0.5 - dir.y * 0.8660254,
                                dir.x * 0.8660254 + dir.y * 0.5)
                let tip = pip + bent * (0.35 * scale)
                joints[finger.pip] = pip
                joints[finger.dip] = pip.midpoint(with: tip)
                joints[finger.tip] = tip
            } else {
                joints[finger.pip] = mcp + dir * (0.45 * scale)
                joints[finger.dip] = mcp + dir * (0.70 * scale)
                joints[finger.tip] = mcp + dir * (0.95 * scale)
            }
        }

        // Thumb chain.
        let thumbTip = wrist + pose.thumbTipOffset * scale
        joints[.thumbCMC] = wrist + Vec2(-0.35, -0.25) * scale
        joints[.thumbMP] = wrist.lerp(to: thumbTip, t: 0.45)
        joints[.thumbIP] = wrist.lerp(to: thumbTip, t: 0.72)
        joints[.thumbTip] = thumbTip

        if let pinch = pose.pinch {
            // Bring thumb tip and the pinching fingertip together around a
            // point matching the open pose's thumb/index midpoint, so an
            // open→pinch transition barely moves the pinch-midpoint pointer
            // (as with a real hand, where the tips converge symmetrically).
            let pinchCenter = wrist + Vec2(-0.57, -1.30) * scale
            let half = pinch.gap * scale / 2
            joints[.thumbTip] = pinchCenter + Vec2(-half, 0)
            joints[pinch.finger.tip] = pinchCenter + Vec2(half, 0)
            joints[.thumbIP] = wrist.lerp(to: joints[.thumbTip]!, t: 0.72)
            joints[.thumbMP] = wrist.lerp(to: joints[.thumbTip]!, t: 0.45)
            // Bend the pinching finger toward the thumb.
            let mcp = joints[pinch.finger.mcp]!
            joints[pinch.finger.pip] = mcp.lerp(to: joints[pinch.finger.tip]!, t: 0.55)
            joints[pinch.finger.dip] = mcp.lerp(to: joints[pinch.finger.tip]!, t: 0.8)
        }

        return Hand(chirality: chirality, confidence: confidence, joints: joints)
    }

    // MARK: - Canonical poses

    /// Open hand, fingers together — the neutral pointing pose.
    static func openRelaxed(wrist: Vec2 = Vec2(0.5, 0.7), scale: Double = 0.15,
                            confidence: Double = 1.0) -> Hand {
        build(pose: Pose(fingerDirs: relaxedDirs, thumbTipOffset: thumbExtendedOffset),
              wrist: wrist, scale: scale, confidence: confidence)
    }

    /// Open hand, fingers spread wide — the dictation-toggle splay.
    static func openSplayed(wrist: Vec2 = Vec2(0.5, 0.7), scale: Double = 0.15,
                            confidence: Double = 1.0) -> Hand {
        build(pose: Pose(fingerDirs: splayedDirs, thumbTipOffset: thumbExtendedOffset),
              wrist: wrist, scale: scale, confidence: confidence)
    }

    /// Closed fist — the clutch pose.
    static func fist(wrist: Vec2 = Vec2(0.5, 0.7), scale: Double = 0.15) -> Hand {
        build(pose: Pose(fingerDirs: relaxedDirs,
                         curled: [.index, .middle, .ring, .little],
                         thumbTipOffset: thumbTuckedOffset),
              wrist: wrist, scale: scale)
    }

    /// Thumb–index pinch with the given tip gap (in scale units).
    /// gap 0.1 → deep in the engage zone; gap 1.0 → fully released.
    static func pinchIndex(gap: Double, wrist: Vec2 = Vec2(0.5, 0.7),
                           scale: Double = 0.15) -> Hand {
        build(pose: Pose(fingerDirs: relaxedDirs,
                         thumbTipOffset: thumbExtendedOffset,
                         pinch: (.index, gap)),
              wrist: wrist, scale: scale)
    }

    /// Thumb–index pinch with the other three fingers casually half-curled —
    /// the natural way people actually pinch. (An earlier openness-based
    /// engagement guard wrongly blocked exactly this pose.)
    static func pinchIndexCasual(gap: Double, wrist: Vec2 = Vec2(0.5, 0.7),
                                 scale: Double = 0.15) -> Hand {
        build(pose: Pose(fingerDirs: relaxedDirs,
                         semiCurled: [.middle, .ring, .little],
                         thumbTipOffset: thumbExtendedOffset,
                         pinch: (.index, gap)),
              wrist: wrist, scale: scale)
    }

    /// Thumb pinching a non-index finger (right-click and configurable),
    /// with the index finger held clearly extended and away from the thumb.
    static func pinchFinger(_ finger: Finger, gap: Double,
                            wrist: Vec2 = Vec2(0.5, 0.7), scale: Double = 0.15) -> Hand {
        var dirs = relaxedDirs
        dirs[.index] = Vec2(0.35, -0.94) // index angled away from the pinch point
        return build(pose: Pose(fingerDirs: dirs,
                                thumbTipOffset: thumbExtendedOffset,
                                pinch: (finger, gap)),
                     wrist: wrist, scale: scale)
    }

    /// All four fingertips gathered onto the thumb tip — the whole-hand pinch.
    /// Every tip sits exactly `gap`·scale from the thumb in a small fan, so the
    /// mean (what `wholeHandPinchRatio` measures) is exactly `gap`. The cluster
    /// sits where `pinchIndex` closes, so the two poses share a pointer spot.
    static func wholeHandPinch(gap: Double, wrist: Vec2 = Vec2(0.5, 0.7),
                               scale: Double = 0.15) -> Hand {
        var hand = build(pose: Pose(fingerDirs: relaxedDirs, thumbTipOffset: thumbExtendedOffset),
                         wrist: wrist, scale: scale)
        let cluster = wrist + Vec2(-0.57, -1.30) * scale
        hand.setPoint(cluster, for: .thumbTip)
        hand.setPoint(wrist.lerp(to: cluster, t: 0.72), for: .thumbIP)
        hand.setPoint(wrist.lerp(to: cluster, t: 0.45), for: .thumbMP)

        // Fan the tips back toward the knuckles they came from (index widest,
        // little tightest) so the fingers reach in without crossing.
        let base = 0.485 // cluster → middleMCP, radians in y-down space
        let spread: [Finger: Double] = [.index: 0.45, .middle: 0.15, .ring: -0.15, .little: -0.45]
        for finger in Finger.allCases {
            let angle = base + spread[finger]!
            let tip = cluster + Vec2(cos(angle), sin(angle)) * (gap * scale)
            let mcp = hand[finger.mcp]!
            hand.setPoint(tip, for: finger.tip)
            hand.setPoint(mcp.lerp(to: tip, t: 0.55), for: finger.pip)
            hand.setPoint(mcp.lerp(to: tip, t: 0.8), for: finger.dip)
        }
        return hand
    }

    /// Flat "high-five" hand for the thumb-curl click mode: fingers extended,
    /// thumb either out to the side (open) or tucked across the index knuckle
    /// (clicked). Untucked it is the same shape as `openRelaxed`.
    static func highFive(thumbTucked: Bool, wrist: Vec2 = Vec2(0.5, 0.7),
                         scale: Double = 0.15) -> Hand {
        build(pose: Pose(fingerDirs: relaxedDirs,
                         thumbTipOffset: thumbTucked ? thumbTuckedOffset : thumbExtendedOffset),
              wrist: wrist, scale: scale)
    }

    /// Shaka: thumb + little out, middle three curled.
    static func shaka(wrist: Vec2 = Vec2(0.5, 0.7), scale: Double = 0.15) -> Hand {
        build(pose: Pose(fingerDirs: relaxedDirs,
                         curled: [.index, .middle, .ring],
                         thumbTipOffset: thumbExtendedOffset),
              wrist: wrist, scale: scale)
    }

    /// Index + middle extended, ring + little curled — the scroll pose.
    static func twoFingerPoint(wrist: Vec2 = Vec2(0.5, 0.7), scale: Double = 0.15) -> Hand {
        build(pose: Pose(fingerDirs: relaxedDirs,
                         curled: [.ring, .little],
                         thumbTipOffset: thumbExtendedOffset),
              wrist: wrist, scale: scale)
    }

    /// All four fingers half-bent — openness lands between a fist and an open
    /// hand (the grab hysteresis band).
    static func halfClosed(wrist: Vec2 = Vec2(0.5, 0.7), scale: Double = 0.15) -> Hand {
        build(pose: Pose(fingerDirs: relaxedDirs,
                         semiCurled: [.index, .middle, .ring, .little],
                         thumbTipOffset: thumbTuckedOffset),
              wrist: wrist, scale: scale)
    }
}
