import Foundation

/// Overlay appearance switches.
public struct OverlayConfig: Codable, Equatable, Sendable {
    /// Small dots on every detected fingertip.
    public var showFingertipDots: Bool = true
    /// The closing-progress ring around the claw cursor.
    public var showPinchRing: Bool = true
    /// The claw cursor itself.
    public var showCursorHalo: Bool = true
    public var showStatusPill: Bool = true
    /// Dot diameter multiplier (1.0 = default sizes).
    public var dotScale: Double = 1.0
    /// Include the overlay (claw, dots, ring, pill) in screenshots and screen
    /// recordings. Off by default for privacy; turn on to demo Pawvis.
    public var showInScreenCapture: Bool = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case showFingertipDots, showPinchRing, showCursorHalo, showStatusPill
        case dotScale, showInScreenCapture
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .showFingertipDots) { showFingertipDots = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .showPinchRing) { showPinchRing = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .showCursorHalo) { showCursorHalo = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .showStatusPill) { showStatusPill = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .dotScale) { dotScale = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .showInScreenCapture) { showInScreenCapture = v }
    }
}

/// App-level behavior.
public struct GeneralConfig: Codable, Equatable, Sendable {
    public var startTrackingOnLaunch: Bool = true
    /// Register Pawvis as a login item so it's running after every restart.
    /// On by default — a menu bar app you have to remember to launch is a
    /// menu bar app you stop using. See `LaunchAtLoginPolicy`.
    public var launchAtLogin: Bool = true
    /// AVCaptureDevice uniqueID; nil = system default camera.
    public var cameraDeviceID: String? = nil
    /// Map hand space across all displays instead of just the main one.
    public var controlAllDisplays: Bool = false
    /// Live tracking numbers (fps, pinch ratio, tip confidences) in the
    /// on-screen pill — for diagnosing flaky detection.
    public var showDiagnostics: Bool = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case startTrackingOnLaunch, launchAtLogin, cameraDeviceID
        case controlAllDisplays, showDiagnostics
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .startTrackingOnLaunch) { startTrackingOnLaunch = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) { launchAtLogin = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .cameraDeviceID) { cameraDeviceID = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .controlAllDisplays) { controlAllDisplays = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .showDiagnostics) { showDiagnostics = v }
    }
}

/// The complete persisted settings tree. Each section decodes independently
/// with defaults, so adding fields (or corrupting one section) never loses the
/// whole settings file.
public struct PawvisSettings: Codable, Equatable, Sendable {
    public var gestures: GestureConfig = .default
    public var customGestures: CustomGestureSettings = CustomGestureSettings()
    public var trainedGestures: TrainedGestureSettings = TrainedGestureSettings()
    public var voiceControl: VoiceControlConfig = VoiceControlConfig()
    public var overlay: OverlayConfig = OverlayConfig()
    public var general: GeneralConfig = GeneralConfig()
    public var attention: AttentionConfig = AttentionConfig()

    public init() {}

    public static let `default` = PawvisSettings()

    enum CodingKeys: String, CodingKey {
        case gestures, customGestures, trainedGestures, voiceControl, overlay, general
        case attention
        case dictation // legacy (pre-voice-control builds)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(gestures, forKey: .gestures)
        try c.encode(customGestures, forKey: .customGestures)
        try c.encode(trainedGestures, forKey: .trainedGestures)
        try c.encode(voiceControl, forKey: .voiceControl)
        try c.encode(overlay, forKey: .overlay)
        try c.encode(general, forKey: .general)
        try c.encode(attention, forKey: .attention)
        // The legacy `dictation` key is read-only (decode migration) and is
        // deliberately not re-encoded.
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gestures = (try? c.decodeIfPresent(GestureConfig.self, forKey: .gestures)) ?? .default
        customGestures = (try? c.decodeIfPresent(CustomGestureSettings.self, forKey: .customGestures))
            ?? CustomGestureSettings()
        trainedGestures = (try? c.decodeIfPresent(TrainedGestureSettings.self, forKey: .trainedGestures))
            ?? TrainedGestureSettings()
        overlay = (try? c.decodeIfPresent(OverlayConfig.self, forKey: .overlay)) ?? OverlayConfig()
        general = (try? c.decodeIfPresent(GeneralConfig.self, forKey: .general)) ?? GeneralConfig()
        attention = (try? c.decodeIfPresent(AttentionConfig.self, forKey: .attention))
            ?? AttentionConfig()
        if let v = try? c.decodeIfPresent(VoiceControlConfig.self, forKey: .voiceControl) {
            voiceControl = v
        } else if let legacy = try? c.decodeIfPresent(LegacyDictationConfig.self, forKey: .dictation) {
            // Settings written by dictation-era builds: carry over what still
            // applies; wake words and engine choice are superseded.
            voiceControl.enabled = legacy.enabled ?? voiceControl.enabled
            voiceControl.language = legacy.language ?? voiceControl.language
            voiceControl.vadSilenceMs = legacy.vadSilenceMs ?? voiceControl.vadSilenceMs
        }
    }
}

/// Just the fields of the old DictationConfig that map onto voice control.
private struct LegacyDictationConfig: Codable {
    var enabled: Bool?
    var language: String?
    var vadSilenceMs: Int?
}
