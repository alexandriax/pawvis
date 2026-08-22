import Foundation

/// Which camera feeds the capture session. Pure, like `LaunchAtLoginPolicy`
/// and `FirstRunPolicy`: the app enumerates the cameras macOS can see and
/// this decides, so the rule is unit-tested and lives in one place.
///
/// The rules:
///   - **An explicit pick wins.** Settings → General and the menu bar store
///     an `AVCaptureDevice.uniqueID`; while that camera is present, it is
///     the camera, whatever else is around.
///   - **Automatic is the built-in camera.** It faces the user by
///     construction. An iPhone macOS offers as a Continuity Camera, a USB
///     webcam, a virtual camera: all of them are picker entries, never
///     adopted unasked. Pawvis does not switch cameras on its own, because
///     a hand tracker that changes its own viewpoint goes blind, or keeps
///     pointing from a camera the user is not in front of.
///   - **A pick that walked away is Automatic until it returns.** Unplug
///     the chosen camera and tracking rides the built-in one instead of a
///     dead input; the app re-adopts the pick the moment it reconnects.
///   - **Something beats nothing.** No built-in camera (a Mac mini, a Mac
///     Studio) means the first camera at all, so an external-only setup
///     still works out of the box.
public enum CameraSelectionPolicy {
    /// What a camera is, as far as choosing one goes.
    public enum Kind: Equatable, Sendable {
        /// The camera built into the Mac or its display.
        case builtIn
        /// An iPhone (or iPad) that macOS offers as a Continuity Camera.
        /// Only reported once the app opts in with
        /// `NSCameraUseContinuityCameraDeviceType`; without that key macOS
        /// files the phone under `.other`. The rule treats it exactly like
        /// `.other`; the kind exists so diagnostics can say what a device
        /// is.
        case continuity
        /// Anything else: a USB webcam, a capture card, a virtual camera.
        case other
    }

    public struct Candidate: Equatable, Sendable {
        public var id: String
        public var kind: Kind

        public init(id: String, kind: Kind) {
            self.id = id
            self.kind = kind
        }
    }

    /// The camera to run on, or nil when there is none at all.
    ///
    /// - Parameters:
    ///   - pick: the persisted explicit choice (`general.cameraDeviceID`);
    ///     nil is Automatic.
    ///   - available: every camera macOS can see right now, in discovery
    ///     order.
    public static func choose(pick: String?, available: [Candidate]) -> String? {
        if let pick, available.contains(where: { $0.id == pick }) {
            return pick
        }
        return (available.first(where: { $0.kind == .builtIn }) ?? available.first)?.id
    }

    /// Whether `choose` is currently on the built-in-camera rule rather
    /// than an explicit pick: no pick, or a pick that is not present.
    public static func isAutomatic(pick: String?, available: [Candidate]) -> Bool {
        guard let pick else { return true }
        return !available.contains(where: { $0.id == pick })
    }
}
