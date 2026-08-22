import Foundation

/// Which camera feeds the capture session. Pure, like `LaunchAtLoginPolicy`
/// and `FirstRunPolicy`: the app enumerates the cameras macOS can see and
/// reads which one macOS currently calls its preferred camera, and this
/// decides. The app never guesses at a device type or a discovery order
/// itself, because each guess below was once wrong on a real machine.
///
/// The rules:
///   - **An explicit pick wins, and wins silently.** Settings → General and
///     the menu bar store an `AVCaptureDevice.uniqueID`; while that camera
///     is present, the system's opinion is ignored entirely. Apple's own
///     guidance for apps with a manual camera mode: set the choice, then
///     stop listening to `systemPreferredCamera`.
///   - **Automatic means the built-in camera, except for a mounted
///     iPhone.** `AVCaptureDevice.systemPreferredCamera` is how macOS says
///     "this iPhone is positioned as a webcam now" (landscape, locked,
///     stationary, near the Mac, cable or not), the same signal FaceTime
///     switches on. Automatic follows it, but only to a Continuity Camera:
///     the built-in camera faces the user by construction, while a USB
///     webcam or a virtual camera that macOS happens to rank first could be
///     pointing anywhere, and a hand tracker switching to it unasked would
///     simply go blind. Those stay one pick away.
///   - **A pick that walked away is Automatic until it returns.** Unplug
///     the chosen webcam and tracking rides the built-in camera (or the
///     mounted iPhone) instead of a dead input; the app re-adopts the pick
///     the moment it reconnects.
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
        /// files the phone under `.other`.
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
    ///   - systemPreferred: the `uniqueID` of
    ///     `AVCaptureDevice.systemPreferredCamera`, if macOS names one.
    public static func choose(
        pick: String?,
        available: [Candidate],
        systemPreferred: String?
    ) -> String? {
        if let pick, available.contains(where: { $0.id == pick }) {
            return pick
        }
        if let systemPreferred,
           let offered = available.first(where: { $0.id == systemPreferred }),
           offered.kind == .continuity {
            return offered.id
        }
        return (available.first(where: { $0.kind == .builtIn }) ?? available.first)?.id
    }

    /// Whether `choose` is currently following the system rather than an
    /// explicit pick — the menu and settings copy say so, and the app only
    /// re-evaluates on `systemPreferredCamera` changes while this is true.
    public static func isAutomatic(pick: String?, available: [Candidate]) -> Bool {
        guard let pick else { return true }
        return !available.contains(where: { $0.id == pick })
    }
}
