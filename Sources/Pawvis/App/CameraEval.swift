import AVFoundation
import Foundation
import PawvisCore

/// `Pawvis --cameras [uniqueID]` — list every camera macOS offers this
/// binary, typed the way `CameraSelectionPolicy` sees it, and where
/// Automatic (or the given pick) lands. The eyes-on hook for Continuity
/// Camera: whether an iPhone shows up as `continuity` depends on the
/// bundle's `NSCameraUseContinuityCameraDeviceType` opt-in, so run
/// `build/Pawvis.app/Contents/MacOS/Pawvis --cameras` rather than a bare
/// `swift run` (which reports the phone as `other`).
func runCameraList(_ args: [String]) -> Int32 {
    let optedIn = Bundle.main.object(forInfoDictionaryKey: "NSCameraUseContinuityCameraDeviceType") as? Bool ?? false
    print("bundle: \(Bundle.main.bundleIdentifier ?? "none (bare binary)") · Continuity Camera opt-in: \(optedIn ? "yes" : "no")")
    // A binary launched from a terminal is judged by the terminal's camera
    // grant, not the app's (measured: "not determined" from Terminal,
    // "granted" via `open`), which decides whether capture itself would
    // work. The listing below does not depend on it.
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
    print("automatic would use: \(CameraManager.chosenDevice(forPick: nil)?.localizedName ?? "nothing")")
    if let pick = args.first {
        print("pick \(pick) resolves to: \(CameraManager.chosenDevice(forPick: pick)?.localizedName ?? "nothing")")
    }
    return 0
}
