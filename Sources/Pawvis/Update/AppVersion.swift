import Foundation
import PawvisCore

/// The running app's version, from the bundle's Info.plist (CI stamps it from
/// the release tag; local `make app` builds carry the placeholder).
enum AppVersion {
    static let current: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0-dev"
    }()

    static var semantic: SemanticVersion {
        SemanticVersion(current) ?? SemanticVersion(major: 0, minor: 0, patch: 0)
    }

    /// Build number (CI uses the run number; local builds use 1).
    static let build: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }()
}
