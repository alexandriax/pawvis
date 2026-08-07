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
    /// AVCaptureDevice uniqueID; nil = system default camera.
    public var cameraDeviceID: String? = nil
    /// Map hand space across all displays instead of just the main one.
    public var controlAllDisplays: Bool = false
    /// Live tracking numbers (fps, pinch ratio, tip confidences) in the
    /// on-screen pill — for diagnosing flaky detection.
    public var showDiagnostics: Bool = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case startTrackingOnLaunch, cameraDeviceID, controlAllDisplays, showDiagnostics
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .startTrackingOnLaunch) { startTrackingOnLaunch = v }
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
    public var dictation: DictationConfig = DictationConfig()
    public var overlay: OverlayConfig = OverlayConfig()
    public var general: GeneralConfig = GeneralConfig()

    public init() {}

    public static let `default` = PawvisSettings()

    enum CodingKeys: String, CodingKey {
        case gestures, dictation, overlay, general
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gestures = (try? c.decodeIfPresent(GestureConfig.self, forKey: .gestures)) ?? .default
        dictation = (try? c.decodeIfPresent(DictationConfig.self, forKey: .dictation)) ?? DictationConfig()
        overlay = (try? c.decodeIfPresent(OverlayConfig.self, forKey: .overlay)) ?? OverlayConfig()
        general = (try? c.decodeIfPresent(GeneralConfig.self, forKey: .general)) ?? GeneralConfig()
    }
}
