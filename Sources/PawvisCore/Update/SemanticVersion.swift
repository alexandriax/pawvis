import Foundation

/// A comparable `major.minor.patch[-prerelease]` version.
///
/// Lenient on input (a leading "v" and missing components are fine, so both
/// "v1.2" and "1.2.0" parse) and strict on ordering: a pre-release sorts
/// *before* its release, so 1.2.0-beta.1 < 1.2.0.
public struct SemanticVersion: Equatable, Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Dot-separated pre-release identifiers; empty for a release build.
    public let prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        guard !text.isEmpty else { return nil }

        // Build metadata (+sha) never affects ordering — drop it.
        let withoutBuild = text.split(separator: "+", maxSplits: 1).first.map(String.init) ?? text
        let parts = withoutBuild.split(separator: "-", maxSplits: 1).map(String.init)
        let core = parts[0]
        let pre = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []

        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !numbers.isEmpty, numbers.count <= 3 else { return nil }
        var values = [0, 0, 0]
        for (i, raw) in numbers.enumerated() {
            guard let value = Int(raw), value >= 0 else { return nil }
            values[i] = value
        }
        self.init(major: values[0], minor: values[1], patch: values[2], prerelease: pre)
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // Equal cores: a pre-release precedes the release it leads to.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false // release > prerelease
        case (false, true): return true  // prerelease < release
        case (false, false): break
        }

        for (l, r) in zip(lhs.prerelease, rhs.prerelease) where l != r {
            // Numeric identifiers compare numerically and rank below alphanumerics.
            switch (Int(l), Int(r)) {
            case let (ln?, rn?): return ln < rn
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return l < r
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
