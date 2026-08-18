import Foundation

/// One per-app exception to a gesture's binding: when the frontmost app's
/// bundle identifier matches, this action fires instead of the gesture's
/// base action. Shared by the built-in library and trained gestures, so
/// "thumbs up means one thing in Keynote and another in the browser" works
/// the same way everywhere.
public struct AppActionOverride: Codable, Equatable, Sendable, Identifiable {
    /// The match key: the app's bundle identifier.
    public var bundleID: String
    /// The app's display name, captured when it was picked, so the row
    /// still reads sensibly if the app is later uninstalled.
    public var appName: String
    /// What the gesture does in this app; nil while the row sits in
    /// Settings waiting for an action. An unassigned override changes
    /// nothing, exactly like an unassigned gesture.
    public var action: GestureAction?

    /// One override per app on a gesture, so the bundle ID is the identity.
    public var id: String { bundleID }

    public init(bundleID: String, appName: String, action: GestureAction? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.action = action
    }

    enum CodingKeys: String, CodingKey {
        case bundleID, appName, action
    }

    /// `bundleID` decodes strictly: without the match key there is no
    /// override, and the lossy list drops the record alone. The display
    /// name falls back to the bundle ID, and an unreadable action (a newer
    /// build's kind) just leaves the override unassigned.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        appName = (try? c.decodeIfPresent(String.self, forKey: .appName)) ?? bundleID
        action = try? c.decodeIfPresent(GestureAction.self, forKey: .action)
    }
}

/// The per-app resolution rule, pure so "which action fires in which app"
/// is unit-testable. Both gesture kinds resolve through here; the app layer
/// only supplies the frontmost bundle ID, read once at fire time.
public enum PerAppAction {
    /// The action a fired gesture should perform given what's frontmost.
    /// A matching override with an action assigned wins; anything else
    /// falls back to the base action. A nil base with overrides present is
    /// the app-gated gesture: it fires in the listed apps and nowhere else.
    public static func resolve(base: GestureAction?,
                               overrides: [AppActionOverride],
                               frontmostBundleID: String?) -> GestureAction? {
        if let bundleID = frontmostBundleID,
           let match = overrides.first(where: { $0.bundleID == bundleID }),
           let action = match.action {
            return action
        }
        return base
    }

    /// Whether the binding does anything in any app at all. This is the
    /// detector gate: a gesture with no base action but a per-app action
    /// must still be watched, because the frontmost check happens at fire
    /// time, not at detection time.
    public static func firesAnywhere(base: GestureAction?,
                                     overrides: [AppActionOverride]) -> Bool {
        base != nil || overrides.contains { $0.action != nil }
    }
}
