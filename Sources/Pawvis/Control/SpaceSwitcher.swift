import AppKit
import CoreGraphics
import Foundation
import PawvisCore

/// Moves to the neighboring virtual desktop.
///
/// Not by pressing ⌃← / ⌃→: on current macOS the Spaces-switching hotkeys
/// ignore synthetic keyboard events outright — measured on macOS 26 with
/// every variant (flags-only, real modifier key events, fn/numpad flags,
/// System Events), while other symbolic hotkeys (Spotlight, Mission
/// Control, show desktop) respond fine. Clicking Mission Control's spaces
/// bar synthetically is equally inert, even though clicking its *window*
/// thumbnails works. The one thing that actually switches a space is the
/// window server's own call:
///
///   SLSManagedDisplaySetCurrentSpace(connection, displayUUID, spaceID)
///
/// which is private SkyLight API — the same call the popular spaces tools
/// lean on. It is resolved at runtime with dlsym, used for exactly this one
/// feature, and every switch is verified against SLSGetActiveSpace; if a
/// future macOS removes or breaks the symbols, the action reports that
/// honestly instead of pretending ("Desktop switching isn't available on
/// this macOS"). Nothing else in Pawvis depends on it.
@MainActor
final class SpaceSwitcher {
    enum Direction {
        case left, right
    }

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias ActiveSpaceFn = @convention(c) (Int32) -> UInt64
    private typealias SetSpaceFn = @convention(c) (Int32, CFString, UInt64) -> Void

    private struct SkyLight {
        let connection: Int32
        let copySpaces: CopySpacesFn
        let activeSpace: ActiveSpaceFn
        let setSpace: SetSpaceFn
    }

    /// Resolved once; nil when the private symbols are gone.
    private lazy var skyLight: SkyLight? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
            return nil
        }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let main = symbol("SLSMainConnectionID", as: MainConnectionFn.self),
              let copy = symbol("SLSCopyManagedDisplaySpaces", as: CopySpacesFn.self),
              let active = symbol("SLSGetActiveSpace", as: ActiveSpaceFn.self),
              let set = symbol("SLSManagedDisplaySetCurrentSpace", as: SetSpaceFn.self) else {
            return nil
        }
        return SkyLight(connection: main(), copySpaces: copy, activeSpace: active, setSpace: set)
    }()

    private var busy = false

    /// Perform the switch; the returned line is the status-pill outcome.
    func switchDesktop(_ direction: Direction) async -> String {
        guard !busy else { return "Still switching…" }
        busy = true
        defer { busy = false }

        guard let sky = skyLight else {
            return "Desktop switching isn't available on this macOS"
        }
        let active = sky.activeSpace(sky.connection)
        guard let displays = sky.copySpaces(sky.connection)?
            .takeRetainedValue() as? [[String: Any]] else {
            return "Couldn't read the desktop layout"
        }
        for display in displays {
            guard let identifier = display["Display Identifier"] as? String,
                  let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            let ids = spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
            guard let current = ids.firstIndex(of: active) else { continue }

            let target = direction == .left ? current - 1 : current + 1
            guard target >= 0 else { return "No desktop to the left" }
            guard target < ids.count else { return "No desktop to the right" }

            sky.setSpace(sky.connection, identifier as CFString, ids[target])

            // Verified, not assumed: poll the active space briefly.
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 120_000_000)
                if sky.activeSpace(sky.connection) == ids[target] {
                    return direction == .left ? "Desktop left" : "Desktop right"
                }
            }
            return "Desktop didn't switch"
        }
        return "Couldn't find the active desktop"
    }
}
