import PawvisCore
import SwiftUI

// MARK: - The Custom tab
//
// Extra one-shot gestures, each bound to an action. The page stays calm by
// construction: it shows only what the user has added (plus one Add button),
// and the sensitivity sliders appear only for gesture families actually in
// use. Everything is built from the shared SettingRow/SettingToggle/
// CaptionText helpers per the AGENTS.md settings-UI rules.

struct CustomGesturesTab: View {
    @ObservedObject var store: SettingsStore
    @State private var showGallery = false

    private var settings: CustomGestureSettings { store.settings.customGestures }

    var body: some View {
        SettingsPage {
            CaptionText("Bind extra one-shot gestures — swipes, finger wiggles, thumbs, grab & fling — to actions: switch desktops, snap windows, press shortcuts, open apps, run commands. Nothing is active until you add it here and give it an action.")

            HStack(spacing: 12) {
                Button("Add a gesture…") { showGallery = true }
                if !settings.bindings.isEmpty {
                    Toggle("Enabled", isOn: $store.settings.customGestures.enabled)
                }
            }

            if settings.bindings.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("No custom gestures yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    CaptionText("Add one to see it here with its picture, then choose what it does. The Gesture Guide shows everything you've bound, illustrated.")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
            }

            ForEach(settings.bindings) { binding in
                CustomBindingRow(store: store, gesture: binding.gesture)
            }
            .opacity(settings.enabled ? 1 : 0.5)

            if !settings.familiesInUse.isEmpty {
                Divider()
                sensitivitySection
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Button("Open Gesture Guide") { GuideWindow.show() }
                CaptionText("Your custom gestures appear there too, alongside the built-in set.")
            }
        }
        .sheet(isPresented: $showGallery) {
            GestureGallerySheet(store: store)
        }
    }

    // MARK: Sensitivity

    @ViewBuilder
    private var sensitivitySection: some View {
        Text("Sensitivity")
            .font(.callout)

        if settings.familiesInUse.contains(.swipe) {
            LabeledSlider(
                label: "Swipe length",
                caption: "How far the sweep must travel. Left: a shorter flick fires. Right: a longer, more deliberate sweep.",
                value: $store.settings.customGestures.swipeTravel,
                range: 0.20...0.45)
        }
        if settings.familiesInUse.contains(.wiggle) {
            SettingRow(
                title: "Wiggle vigor",
                caption: "How many times each finger must change direction. More = a longer, more emphatic wiggle."
            ) {
                HStack(spacing: 10) {
                    Text("\(store.settings.customGestures.wiggleReversals)×")
                        .font(.callout)
                        .monospacedDigit()
                    Stepper("", value: $store.settings.customGestures.wiggleReversals, in: 2...5)
                }
            }
        }
        if settings.familiesInUse.contains(.holdPose) {
            LabeledSlider(
                label: "Hold time",
                caption: String(format: "Held poses (thumbs, shaka) fire after %.1f s.",
                                store.settings.customGestures.holdSeconds),
                value: $store.settings.customGestures.holdSeconds,
                range: 0.2...0.8)
        }
        if settings.familiesInUse.contains(.grabFling) {
            LabeledSlider(
                label: "Fling distance",
                caption: "How far the grabbed hand must travel. Left: a small tug fires. Right: a full fling.",
                value: $store.settings.customGestures.flingTravel,
                range: 0.10...0.30)
        }
    }
}

// MARK: - One binding

private struct CustomBindingRow: View {
    @ObservedObject var store: SettingsStore
    let gesture: CustomGesture

    private var action: GestureAction? {
        store.settings.customGestures.binding(for: gesture)?.action
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GestureGlyphView(gesture: gesture, size: 40)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(gesture.displayName).font(.headline)
                    Spacer()
                    Button {
                        remove()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this gesture")
                }
                CaptionText(gesture.howTo)

                Picker("", selection: kindSelection) {
                    Text("Choose an action…").tag(GestureAction.Kind?.none)
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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

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
        guard let index = store.settings.customGestures.bindings.firstIndex(
            where: { $0.gesture == gesture }) else { return }
        store.settings.customGestures.bindings[index].action = newAction
    }

    private func remove() {
        store.settings.customGestures.bindings.removeAll { $0.gesture == gesture }
    }
}

// MARK: - The gallery sheet

private struct GestureGallerySheet: View {
    @ObservedObject var store: SettingsStore
    @Environment(\.dismiss) private var dismiss

    private static let familyOrder: [CustomGesture.Family] = [.swipe, .wiggle, .holdPose, .grabFling]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add a gesture")
                    .font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Self.familyOrder, id: \.self) { family in
                        let available = gestures(in: family)
                        if !available.isEmpty {
                            familySection(family, gestures: available)
                        }
                    }
                    if Self.familyOrder.allSatisfy({ gestures(in: $0).isEmpty }) {
                        CaptionText("Every gesture has been added — configure them in the list, or remove one to re-add it.")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 600)
        .tint(PawvisTheme.accentUI)
    }

    private func gestures(in family: CustomGesture.Family) -> [CustomGesture] {
        let added = Set(store.settings.customGestures.bindings.map(\.gesture))
        return CustomGesture.allCases.filter { $0.family == family && !added.contains($0) }
    }

    private func familyBlurb(_ family: CustomGesture.Family) -> String {
        switch family {
        case .swipe:
            return "A fast, straight sweep with an open hand. Quick and directional — the desktop-switching classic."
        case .wiggle:
            return "Hand up, fingers spread, fingers wiggling while the hand stays put. Unmistakable on camera."
        case .holdPose:
            return "An unambiguous shape, held for a beat."
        case .grabFling:
            return "Close your open hand into a grab, then fling it toward an edge or corner. The cursor parks while you hold the grab."
        }
    }

    private func familySection(_ family: CustomGesture.Family,
                               gestures: [CustomGesture]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(family.displayName).font(.headline)
            CaptionText(familyBlurb(family))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      alignment: .leading, spacing: 8) {
                ForEach(gestures, id: \.self) { gesture in
                    galleryCard(gesture)
                }
            }
        }
    }

    private func galleryCard(_ gesture: CustomGesture) -> some View {
        Button {
            store.settings.customGestures.bindings
                .append(CustomGestureBinding(gesture: gesture))
        } label: {
            HStack(alignment: .top, spacing: 10) {
                GestureGlyphView(gesture: gesture, size: 34)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(gesture.displayName)
                        .font(.callout.weight(.semibold))
                        .multilineTextAlignment(.leading)
                    Text(gesture.howTo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.tint)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Add \(gesture.displayName)")
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
