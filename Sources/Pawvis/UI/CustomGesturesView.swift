import AppKit
import PawvisCore
import SwiftUI
import UniformTypeIdentifiers

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

            VStack(alignment: .leading, spacing: 5) {
                Button("Open Gesture Guide") { GuideWindow.show() }
                CaptionText("Every gesture illustrated in full, with what it's currently set to do.")
            }

            SettingToggle(
                title: "Enable custom gestures",
                caption: "Off pauses all of them — trained ones included — without losing your setup.",
                isOn: $store.settings.customGestures.enabled)

            Divider()
            trainedSection

            ForEach(Self.familyOrder, id: \.self) { family in
                Divider()
                familySection(family)
            }
        }
    }

    // MARK: Your trained gestures

    private var trainedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your Trained Gestures").font(.title3.bold())
            CaptionText("Gestures you record yourself: Pawvis watches you perform one a few times, learns what stays the same, and matches it live. The badge replays the motion it learned — your palm and fingertips, in their tracking colors.")
            VStack(alignment: .leading, spacing: 5) {
                Button("Train New Gesture…") { TrainerWindow.show() }
                CaptionText("Opens the camera. Pawvis control pauses while you train.")
            }
            TrainedGestureImportExportRow(store: store)
            SettingToggle(
                title: "Trained gestures take priority over clicks",
                caption: "Matching keeps running through clicks and scrolls, and once a match is recognized and dwelling, finger dips can't click. A dip that lands before recognition can still click — give the gesture a hold time and the block covers the rest. Off: the mouse always wins, and a gesture that curls your index finger may click instead of firing.",
                isOn: $store.settings.trainedGestures.mouseOverride)
            if store.settings.trainedGestures.gestures.isEmpty {
                CaptionText("Nothing trained yet.")
            }
            ForEach(store.settings.trainedGestures.gestures) { gesture in
                TrainedGestureRow(store: store, id: gesture.id)
                    .opacity(store.settings.customGestures.enabled ? 1 : 0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

                GestureActionPicker(action: actionBinding)

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

    private var actionBinding: Binding<GestureAction?> {
        Binding(get: { action }, set: { setAction($0) })
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

// MARK: - The action picker (shared by built-in and trained rows)

/// "What does this gesture do": the categorized action menu plus, for the
/// argument-taking kinds, the argument field and its live hint. One
/// component for the built-in library and the trained gestures, so the two
/// can never drift.
struct GestureActionPicker: View {
    @Binding var action: GestureAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
        }
    }

    private func kinds(in category: GestureAction.Category) -> [GestureAction.Kind] {
        GestureAction.Kind.allCases.filter { $0.category == category }
    }

    private var kindSelection: Binding<GestureAction.Kind?> {
        Binding(
            get: { action?.kind },
            set: { kind in
                guard let kind else {
                    action = nil
                    return
                }
                // Keep the typed argument when re-picking the same kind;
                // start fresh when the kind changes.
                let argument = action?.kind == kind ? (action?.argument ?? "") : ""
                action = GestureAction(kind: kind, argument: argument)
            })
    }

    private var argumentBinding: Binding<String> {
        Binding(
            get: { action?.argument ?? "" },
            set: { text in
                guard let current = action else { return }
                action = GestureAction(kind: current.kind, argument: text)
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
}

// MARK: - Export / import

/// Trained templates live only in this settings blob — there's no other copy
/// anywhere, and no way to recreate one short of re-recording. Export writes
/// every trained gesture (bound action included) to a `.pawvisgestures`
/// file; Import reads one back and merges it into the current library as
/// copies, never overwrites. Quiet by design: two buttons and a caption that
/// doubles as the outcome report, matching how the rest of this tab reports
/// state inline rather than with alerts.
private struct TrainedGestureImportExportRow: View {
    @ObservedObject var store: SettingsStore
    @State private var feedback: String?

    private static let fileType = UTType(filenameExtension: "pawvisgestures") ?? .data

    private static let defaultCaption =
        "Export saves every trained gesture, with its assigned action, to a file you can back up or share. Import merges another file's gestures into yours as copies: a name already in use gets renumbered, and nothing here is ever overwritten."

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Button("Export…") { exportGestures() }
                    .disabled(store.settings.trainedGestures.gestures.isEmpty)
                Button("Import…") { importGestures() }
            }
            CaptionText(feedback ?? Self.defaultCaption)
        }
    }

    private func exportGestures() {
        let gestures = store.settings.trainedGestures.gestures
        guard !gestures.isEmpty else { return }
        guard let data = try? PawvisGestureFile(gestures: gestures).encoded() else {
            feedback = "Couldn't prepare the export"
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Trained Gestures"
        panel.nameFieldStringValue = "Pawvis Gestures.pawvisgestures"
        panel.allowedContentTypes = [Self.fileType]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                feedback = "Exported \(gestures.count) gesture\(gestures.count == 1 ? "" : "s")"
            } catch {
                feedback = "Couldn't write the file: \(error.localizedDescription)"
            }
        }
    }

    private func importGestures() {
        let panel = NSOpenPanel()
        panel.title = "Import Trained Gestures"
        panel.allowedContentTypes = [Self.fileType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let file = try PawvisGestureFile.decoded(from: data)
                guard !file.gestures.isEmpty else {
                    feedback = "No gestures found in that file"
                    return
                }
                let result = TrainedGestureImport.merge(
                    existing: store.settings.trainedGestures.gestures,
                    importing: file.gestures)
                store.settings.trainedGestures.gestures = result.gestures
                feedback = summary(for: result)
            } catch {
                feedback = "Couldn't import: \(error.localizedDescription)"
            }
        }
    }

    private func summary(for result: TrainedGestureImport.Result) -> String {
        let count = result.added.count
        let noun = count == 1 ? "gesture" : "gestures"
        guard result.renamedCount > 0 else { return "Imported \(count) \(noun)" }
        return "Imported \(count) \(noun) (\(result.renamedCount) renamed)"
    }
}

// MARK: - One trained gesture

/// A trained gesture's settings row: the animated badge, an editable name,
/// the shared action picker, and the match-tolerance dial. Removal is a
/// two-step (the takes behind a trained gesture can't be recovered).
private struct TrainedGestureRow: View {
    @ObservedObject var store: SettingsStore
    let id: UUID
    @State private var showTuning = false
    @State private var confirmingRemoval = false
    @State private var editingName = false

    private var gesture: TrainedGesture? {
        store.settings.trainedGestures.gesture(withID: id)
    }

    var body: some View {
        if let gesture {
            HStack(alignment: .top, spacing: 12) {
                TrainedGestureBadge(gesture: gesture, size: 44)
                    .frame(width: 44)
                    .opacity(gesture.action == nil ? 0.55 : 1)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        // Display + pencil rather than a bare text field: a
                        // field here becomes the tab's first responder, and
                        // stray keystrokes silently rename the gesture.
                        if editingName {
                            TextField("Name", text: binding(\.name))
                                .textFieldStyle(.roundedBorder)
                                .font(.headline)
                                .frame(maxWidth: 240)
                                .onSubmit { editingName = false }
                        } else {
                            Text(gesture.name).font(.headline)
                            Button {
                                editingName = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Rename")
                        }
                        Spacer()
                        Text(gesture.handCount == 2 ? "Two hands" : "One hand")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            confirmingRemoval = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove this gesture")
                    }

                    GestureActionPicker(action: binding(\.action))

                    DisclosureGroup(isExpanded: $showTuning) {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledSlider(
                                label: "Match tolerance",
                                caption: "Left: only a performance very close to your takes counts. Right: looser matching — move this right if the gesture won't trigger, left if it triggers by accident.",
                                value: binding(\.sensitivity),
                                range: 0...1)
                            LabeledSlider(
                                label: "Hold to confirm",
                                caption: holdCaption,
                                value: binding(\.holdSeconds),
                                range: 0...1)
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
            .confirmationDialog(
                "Remove “\(gesture.name)”? Its training can't be recovered.",
                isPresented: $confirmingRemoval, titleVisibility: .visible
            ) {
                Button("Remove Gesture", role: .destructive) {
                    store.settings.trainedGestures.gestures.removeAll { $0.id == id }
                }
            }
        }
    }

    private var holdCaption: String {
        let seconds = gesture?.holdSeconds ?? 0
        return seconds > 0.05
            ? String(format: "Keep matching for %.1f s before it fires — the pill counts it down.", seconds)
            : "Fires the moment it matches. Raise this for pose-like gestures so a passing resemblance can't trigger."
    }

    /// A binding into the gesture's record in settings, by id — stable
    /// against reordering and other rows' removal.
    private func binding<Value>(_ keyPath: WritableKeyPath<TrainedGesture, Value>) -> Binding<Value> where Value: Sendable {
        Binding(
            get: {
                guard let gesture = store.settings.trainedGestures.gesture(withID: id) else {
                    return TrainedGesture(name: "", handCount: 1, template: [],
                                          duration: 0, baseThreshold: 0)[keyPath: keyPath]
                }
                return gesture[keyPath: keyPath]
            },
            set: { newValue in
                guard let index = store.settings.trainedGestures.gestures
                    .firstIndex(where: { $0.id == id }) else { return }
                store.settings.trainedGestures.gestures[index][keyPath: keyPath] = newValue
            })
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
