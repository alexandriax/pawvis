import Foundation

/// Overlay appearance switches.
public struct OverlayConfig: Codable, Equatable, Sendable {
    public var showFingertipDots: Bool = true
    /// Show all five fingertips instead of just the pinch pair (thumb+index).
    /// Off by default — a screenful of dots obscured which mark was the cursor.
    public var showAllFingertips: Bool = false
    public var showPinchRing: Bool = true
    public var showCursorHalo: Bool = true
    public var showStatusPill: Bool = true
    /// Dot diameter multiplier (1.0 = default sizes).
    public var dotScale: Double = 1.0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case showFingertipDots, showAllFingertips, showPinchRing
        case showCursorHalo, showStatusPill, dotScale
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .showFingertipDots) { showFingertipDots = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .showAllFingertips) { showAllFingertips = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .showPinchRing) { showPinchRing = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .showCursorHalo) { showCursorHalo = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .showStatusPill) { showStatusPill = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .dotScale) { dotScale = v }
    }
}

/// App-level behavior.
public struct GeneralConfig: Codable, Equatable, Sendable {
    public var startTrackingOnLaunch: Bool = true
    /// AVCaptureDevice uniqueID; nil = system default camera.
    public var cameraDeviceID: String? = nil
    /// Map hand space across all displays instead of just the main one.
    public var controlAllDisplays: Bool = false

    public init() {}
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
