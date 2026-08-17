import PawvisCore
import SwiftUI

// MARK: - The Custom tab
//
// Every bindable gesture, listed — no add/remove ceremony. A gesture with no
// action simply isn't listened to, so the list itself is the whole mental
// model: pick an action to turn a gesture on, set it back to "Not assigned"
// to turn it off. Each row carries a collapsed Tuning accordion with its
// family's thresholds, which is also the debugging story: when a gesture
// won't trigger (or triggers too easily), the dials for exactly that
// behavior are on the gesture itself. Built from the shared SettingRow/
// SettingToggle/CaptionText helpers per the AGENTS.md settings-UI rules.

struct CustomGesturesTab: View {
    @ObservedObject var store: SettingsStore

    private static let familyOrder: [CustomGesture.Family] = [.wiggle, .holdPose, .grabFling]

    var body: some View {
        SettingsPage {
            CaptionText("Every gesture below can run an action of your choice: switch desktops, snap windows, press shortcuts, open apps, run commands. A gesture without an action is ignored entirely — assign one to switch it on. Tuning for each lives in its row.")

            SettingToggle(
                title: "Enable custom gestures",
                caption: "Off pauses all of them without losing your setup.",
                isOn: $store.settings.customGestures.enabled)

            ForEach(Self.familyOrder, id: \.self) { family in
                Divider()
                familySection(family)
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Button("Open Gesture Guide") { GuideWindow.show() }
                CaptionText("Gestures you've assigned appear there too, illustrated alongside the built-in set.")
            }
        }
    }

    private func familySection(_ family: CustomGesture.Family) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(family.displayName).font(.title3.bold())
            CaptionText(family.blurb)
            ForEach(CustomGesture.allCases.filter { $0.family == family }, id: \.self) { gesture in
                CustomGestureRow(store: store, gesture: gesture)
                    .opacity(store.settings.customGestures.enabled ? 1 : 0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - One gesture

private struct CustomGestureRow: View {
    @ObservedObject var store: SettingsStore
    let gesture: CustomGesture
    @State private var showTuning = false

    private var action: GestureAction? {
        store.settings.customGestures.binding(for: gesture)?.action
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GestureGlyphView(gesture: gesture, size: 40)
                .frame(width: 44)
                .opacity(action == nil ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(gesture.displayName)
                    .font(.headline)
                    .foregroundStyle(action == nil ? .secondary : .primary)
                CaptionText(gesture.howTo)

                Picker("", selection: kindSelection) {
                    Text("Not assigned").tag(GestureAction.Kind?.none)
                    ForEach(GestureAction.Category.allCases, id: \.self) { category in
                        Section(category.displayName) {
                            ForEach(kinds(in: category), id: \.self) { kind in
                                Text(kind.displayName).tag(GestureAction.Kind?.some(kind))
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 340, alignment: .leading)

                if let action, action.kind.needsArgument {
                    TextField(argumentPlaceholder(for: action.kind), text: argumentBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 340)
                    if let hint = argumentHint(for: action) {
                        CaptionText(hint)
                    }
                }

                DisclosureGroup(isExpanded: $showTuning) {
                    VStack(alignment: .leading, spacing: 12) {
                        tuning
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Tuning")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    // MARK: Tuning (family-wide dials, surfaced on every member)

    @ViewBuilder
    private var tuning: some View {
        switch gesture.family {
        case .wiggle:
            SettingRow(
                title: "Wiggle vigor",
                caption: "Direction changes each finger must make. Left: a brief flutter fires. Right: a longer, more emphatic wiggle. Shared by both wiggle gestures."
            ) {
                HStack(spacing: 10) {
                    Text("\(store.settings.customGestures.wiggleReversals)×")
                        .font(.callout)
                        .monospacedDigit()
                    Stepper("", value: $store.settings.customGestures.wiggleReversals, in: 2...5)
                }
            }
        case .holdPose:
            LabeledSlider(
                label: "Hold time",
                caption: String(format: "The pose must dwell %.1f s before it fires. Shared by all held poses.",
                                store.settings.customGestures.holdSeconds),
                value: $store.settings.customGestures.holdSeconds,
                range: 0.2...0.8)
        case .grabFling:
            LabeledSlider(
                label: "Grab tightness",
                caption: "How snugly your fingertips must bunch to count as a grab. Left: only a tight pinch. Right: a looser bunch counts — try moving this right if grabs won't register.",
                value: $store.settings.customGestures.gatherSpread,
                range: 0.22...0.50)
            LabeledSlider(
                label: "Fling distance",
                caption: "How far the grabbed bunch must travel. Left: a small tug fires. Right: a full fling. Both dials are shared by all grab & fling directions.",
                value: $store.settings.customGestures.flingTravel,
                range: 0.10...0.30)
        }
    }

    // MARK: Action plumbing

    private func kinds(in category: GestureAction.Category) -> [GestureAction.Kind] {
        GestureAction.Kind.allCases.filter { $0.category == category }
    }

    private var kindSelection: Binding<GestureAction.Kind?> {
        Binding(
            get: { action?.kind },
            set: { kind in
                guard let kind else {
                    setAction(nil)
                    return
                }
                // Keep the typed argument when re-picking the same kind;
                // start fresh when the kind changes.
                let argument = action?.kind == kind ? (action?.argument ?? "") : ""
                setAction(GestureAction(kind: kind, argument: argument))
            })
    }

    private var argumentBinding: Binding<String> {
        Binding(
            get: { action?.argument ?? "" },
            set: { text in
                guard let action else { return }
                setAction(GestureAction(kind: action.kind, argument: text))
            })
    }

    private func argumentPlaceholder(for kind: GestureAction.Kind) -> String {
        switch kind {
        case .openApp: return "App name — Safari, Notes, Terminal…"
        case .runShellCommand: return "Shell command — open -a 'Notes', say hi, …"
        case .keyboardShortcut: return "Shortcut — cmd+shift+t or ⌘⇧T"
        default: return ""
        }
    }

    private func argumentHint(for action: GestureAction) -> String? {
        let trimmed = action.argument.trimmingCharacters(in: .whitespaces)
        switch action.kind {
        case .keyboardShortcut:
            guard !trimmed.isEmpty else { return "Modifiers plus one key: cmd+t, ctrl+alt+delete, ⌘⇧4." }
            guard let chord = ShortcutParser.chord(from: trimmed) else {
                return "Not understood yet — try something like cmd+shift+t."
            }
            return "Presses \(ShortcutParser.display(chord))."
        case .runShellCommand:
            return "Runs in zsh as you, exactly as typed, the moment the gesture fires."
        case .openApp:
            return trimmed.isEmpty ? nil : "Fuzzy-matched against your installed apps, like the voice command."
        default:
            return nil
        }
    }

    private func setAction(_ newAction: GestureAction?) {
        var bindings = store.settings.customGestures.bindings
        if let newAction {
            if let index = bindings.firstIndex(where: { $0.gesture == gesture }) {
                bindings[index].action = newAction
            } else {
                bindings.append(CustomGestureBinding(gesture: gesture, action: newAction))
            }
        } else {
            bindings.removeAll { $0.gesture == gesture }
        }
        store.settings.customGestures.bindings = bindings
    }
}

// MARK: - Glyphs

/// A custom gesture's posed-hand picture, tinted like the guide's; falls back
/// to its SF Symbol for runs without a bundle (bare `swift run`).
struct GestureGlyphView: View {
    let gesture: CustomGesture
    var size: CGFloat = 40

    var body: some View {
        if let art = CustomGestureArt.image(gesture.glyphName, size: size) {
            Image(nsImage: art)
                .renderingMode(.template)
                .foregroundStyle(.tint)
        } else {
            Image(systemName: gesture.symbolName)
                .font(.title2)
                .foregroundStyle(.tint)
        }
    }
}

/// Loaded once per name+size — same reasoning as the guide's cache: these
/// views re-render on every settings change.
@MainActor
private enum CustomGestureArt {
    private static var cache: [String: NSImage?] = [:]

    static func image(_ name: String, size: CGFloat) -> NSImage? {
        let key = "\(name)@\(Int(size))"
        if let cached = cache[key] { return cached }
        let image = PawvisGlyph.gesture(name, size: size)
        cache[key] = image
        return image
    }
}
