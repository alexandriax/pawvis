import Foundation

/// Folds an imported gesture list into the ones already trained. Pure and
/// side-effect free on purpose: the panel-driving UI code that calls this
/// can't be exercised headlessly (AppKit's save/open panels have no
/// programmatic driver), so the logic that actually decides what lands in
/// settings lives here, where a test can call it directly.
public enum TrainedGestureImport {
    public struct Result: Equatable, Sendable {
        /// The full list to store: `existing`, untouched, followed by the
        /// imported gestures (re-identified/renamed as needed below).
        public var gestures: [TrainedGesture]
        /// Just the gestures that were added, in import order — what the UI
        /// reports on.
        public var added: [TrainedGesture]
        /// How many of `added` got a suffixed name because of a collision.
        public var renamedCount: Int
    }

    /// Imported gestures are always copies, never overwrites: an id already
    /// present in `existing` gets a fresh one before the record is appended,
    /// and a name already in use — in `existing`, or earlier in this same
    /// import — gets " 2", " 3", … suffixed until it's unique. Everything
    /// else on the gesture (its action, sensitivity, hold time) is carried
    /// over untouched.
    public static func merge(existing: [TrainedGesture], importing: [TrainedGesture]) -> Result {
        var ids = Set(existing.map(\.id))
        var names = Set(existing.map(\.name))
        var merged = existing
        var added: [TrainedGesture] = []
        var renamedCount = 0

        for var gesture in importing {
            if ids.contains(gesture.id) {
                gesture.id = UUID()
            }
            if names.contains(gesture.name) {
                gesture.name = uniqueName(gesture.name, avoiding: names)
                renamedCount += 1
            }
            ids.insert(gesture.id)
            names.insert(gesture.name)
            merged.append(gesture)
            added.append(gesture)
        }
        return Result(gestures: merged, added: added, renamedCount: renamedCount)
    }

    /// `base` itself is already known to collide, so the search starts at
    /// " 2" and climbs until it clears every name seen so far.
    private static func uniqueName(_ base: String, avoiding: Set<String>) -> String {
        var suffix = 2
        var candidate = "\(base) \(suffix)"
        while avoiding.contains(candidate) {
            suffix += 1
            candidate = "\(base) \(suffix)"
        }
        return candidate
    }
}
