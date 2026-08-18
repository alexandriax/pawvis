import Foundation

/// A portable snapshot of trained gestures: `Export…` in the Gestures tab
/// writes one of these, `Import…` reads one back. Trained templates
/// otherwise live only inside the settings blob — no backup, no sharing —
/// so this format doubles as both.
public struct PawvisGestureFile: Codable, Equatable, Sendable {
    /// Bumped only when the payload changes in a way an older Pawvis cannot
    /// read. A file written by a newer Pawvis refuses to decode instead of
    /// being silently misread.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var exportedAt: Date
    /// Bound actions travel with the export on purpose: a shared "gesture
    /// pack" wants them ready to use, and a wary importer can always unbind
    /// one afterwards in the Gestures tab. An action naming an app or shell
    /// command that doesn't exist on the importing machine is inert, not
    /// destructive — `GestureActionRunner` already reports "Couldn't find
    /// …" rather than failing loudly when a target is missing.
    public var gestures: [TrainedGesture]

    public init(gestures: [TrainedGesture], exportedAt: Date = Date()) {
        self.formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        self.gestures = gestures
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion, exportedAt, gestures
    }

    /// A file written by a Pawvis newer than this one — the honest refusal
    /// instead of a silent partial read.
    public enum DecodeError: Error, LocalizedError, Equatable, Sendable {
        case newerFormat(fileVersion: Int)

        public var errorDescription: String? {
            switch self {
            case .newerFormat(let fileVersion):
                return "This file (format \(fileVersion)) was made by a newer version of Pawvis. Update Pawvis to import it."
            }
        }
    }

    /// `formatVersion` decodes strictly and gates the whole read: it's the
    /// one field that must be trusted before anything else is. The gesture
    /// list is element-tolerant, the same lossy-list pattern
    /// `TrainedGestureSettings` uses for its own persisted list — one
    /// unreadable record (hand-edited, truncated, from a future build) drops
    /// alone rather than failing the whole file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .formatVersion)
        guard version <= Self.currentFormatVersion else {
            throw DecodeError.newerFormat(fileVersion: version)
        }
        formatVersion = version
        exportedAt = (try? c.decodeIfPresent(Date.self, forKey: .exportedAt)) ?? Date()
        gestures = []
        if let wrapped = try? c.decodeIfPresent([Lossy<TrainedGesture>].self, forKey: .gestures) {
            var seen: Set<UUID> = []
            gestures = wrapped.compactMap(\.value).filter { seen.insert($0.id).inserted }
        }
    }

    // MARK: - Reading and writing

    /// Pretty-printed, key-sorted, ISO 8601 dates: this file is meant to be
    /// inspected, diffed and shared, not just round-tripped by the app.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func encoded() throws -> Data {
        try Self.encoder().encode(self)
    }

    public static func decoded(from data: Data) throws -> PawvisGestureFile {
        try decoder().decode(PawvisGestureFile.self, from: data)
    }
}

/// Wraps an element so a failed decode yields nil instead of failing the
/// whole array (the unkeyed container still advances past the element).
/// Deliberately a file-local copy of the same helper in `TrainedGesture.swift`
/// and `CustomGestureSettings.swift` rather than a shared internal type —
/// matching how this codebase already duplicates it per file.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) {
        value = try? T(from: decoder)
    }
}
