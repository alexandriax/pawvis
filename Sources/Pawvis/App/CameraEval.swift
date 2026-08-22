import AVFoundation
import Foundation
import PawvisCore

/// `Pawvis --cameras [uniqueID]` — list every camera macOS offers this
/// binary, typed the way `CameraSelectionPolicy` sees it, with what macOS
/// currently calls its preferred camera and where Automatic (or the given
/// pick) would land. The eyes-on hook for Continuity Camera, and two of its
/// answers come only from the machine: whether an iPhone shows up as
/// `continuity` depends on the bundle's `NSCameraUseContinuityCameraDeviceType`
/// opt-in, so run `build/Pawvis.app/Contents/MacOS/Pawvis --cameras` rather
/// than a bare `swift run` (which reports the phone as `other`); and whether
/// macOS prefers the phone depends on how it is physically positioned.
func runCameraList(_ args: [String]) -> Int32 {
    let optedIn = Bundle.main.object(forInfoDictionaryKey: "NSCameraUseContinuityCameraDeviceType") as? Bool ?? false
    print("bundle: \(Bundle.main.bundleIdentifier ?? "none (bare binary)") · Continuity Camera opt-in: \(optedIn ? "yes" : "no")")
    // A binary launched from a terminal is judged by the terminal's camera
    // grant, not the app's (measured: "not determined" from Terminal,
    // "granted" via `open`), which decides whether capture itself would
    // work. The readings below do not depend on it.
    let authorization: String
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: authorization = "granted"
    case .denied: authorization = "denied"
    case .restricted: authorization = "restricted"
    case .notDetermined: authorization = "not determined"
    @unknown default: authorization = "unknown"
    }
    print("camera access: \(authorization) (launch via `open` to be judged as the app, not as the terminal)")

    let devices = CameraManager.discover()
    if devices.isEmpty {
        print("no cameras")
    }
    for device in devices {
        var line = "\(device.localizedName)  [\(CameraManager.kind(of: device))]  \(device.deviceType.rawValue)  \(device.uniqueID)"
        if !device.modelID.isEmpty { line += "  (\(device.modelID))" }
        print(line)
    }

    // The system's preference arrives by key-value observation, the same
    // way `CameraManager` learns of a mounted iPhone: read it at once, then
    // watch for a couple of seconds and report what the watch delivered, so
    // "none" at launch and "FaceTime HD Camera" a moment later both show.
    let watch = PreferredCameraWatch()
    print("system preferred at launch: \(AVCaptureDevice.systemPreferredCamera?.localizedName ?? "none")")
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    print("system preferred after 2 s: \(AVCaptureDevice.systemPreferredCamera?.localizedName ?? "none")")
    print("observed: \(watch.seen.isEmpty ? "(no change delivered)" : watch.seen.joined(separator: " → "))")
    print("automatic would use: \(CameraManager.chosenDevice(forPick: nil)?.localizedName ?? "nothing")")
    if let pick = args.first {
        print("pick \(pick) resolves to: \(CameraManager.chosenDevice(forPick: pick)?.localizedName ?? "nothing")")
    }
    return 0
}

/// The same observation `CameraManager` keeps for its lifetime: KVO on the
/// `AVCaptureDevice` class object's `systemPreferredCamera`.
private final class PreferredCameraWatch: NSObject {
    private static let context = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    private(set) var seen: [String] = []

    override init() {
        super.init()
        (AVCaptureDevice.self as AnyObject).addObserver(
            self, forKeyPath: "systemPreferredCamera", options: [.new], context: Self.context)
    }

    deinit {
        (AVCaptureDevice.self as AnyObject).removeObserver(
            self, forKeyPath: "systemPreferredCamera", context: Self.context)
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard context == Self.context else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        seen.append(AVCaptureDevice.systemPreferredCamera?.localizedName ?? "none")
    }
}
