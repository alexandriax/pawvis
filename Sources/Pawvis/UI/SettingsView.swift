import PawvisCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        TabView {
            GeneralSettingsTab(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
            GestureSettingsTab(store: store)
                .tabItem { Label("Gestures", systemImage: "hand.point.up.left") }
            DictationSettingsTab(store: store)
                .tabItem { Label("Dictation", systemImage: "mic") }
            AboutTab()
                .tabItem { Label("About", systemImage: "pawprint") }
        }
        .frame(width: 480)
        .tint(PawvisTheme.purpleUI)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject var store: SettingsStore
    private var cameras: [(id: String, name: String)] { CameraManager.availableCameras() }

    var body: some View {
        Form {
            Picker("Camera", selection: Binding(
                get: { store.settings.general.cameraDeviceID ?? "" },
                set: { store.settings.general.cameraDeviceID = $0.isEmpty ? nil : $0 })) {
                Text("Automatic").tag("")
                ForEach(cameras, id: \.id) { camera in
                    Text(camera.name).tag(camera.id)
                }
            }

            Toggle("Control all displays", isOn: $store.settings.general.controlAllDisplays)
            Text("Off: hand space maps to the main display only.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            LabeledSlider(
                label: "Responsiveness",
                caption: "Left: smoother, steadier cursor. Right: faster, more direct.",
                value: Binding(
                    get: { store.settings.gestures.smoothing.beta },
                    set: { store.settings.gestures.smoothing.beta = $0 }),
                range: 0.005...0.09)

            LabeledSlider(
                label: "Reach",
                caption: "How much of the camera view maps to the whole screen. Higher = smaller hand movements.",
                value: Binding(
                    get: { 0.5 - store.settings.gestures.interactionBox.xMin },
                    set: { reach in
                        let mx = 0.5 - reach
                        let my = mx * 0.9 + 0.03
                        store.settings.gestures.interactionBox = InteractionBox(
                            xMin: mx, xMax: 1 - mx, yMin: my, yMax: 1 - my)
                    }),
                range: 0.2...0.45)

            Picker("Cursor follows", selection: $store.settings.gestures.pointerSource) {
                Text("Palm (recommended — steadiest)").tag(PointerSource.palmCenter)
                Text("Thumb tip").tag(PointerSource.thumbTip)
                Text("Index fingertip").tag(PointerSource.indexTip)
                Text("Thumb–index midpoint").tag(PointerSource.pinchMidpoint)
            }

            Toggle("Mirror camera", isOn: $store.settings.gestures.mirrorCamera)
            Text("Leave on for a normal user-facing webcam.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

// MARK: - Gestures

private struct GestureSettingsTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Picker("Right-click pinch finger", selection: $store.settings.gestures.rightClickFinger) {
                Text("Middle").tag(Finger.middle)
                Text("Ring").tag(Finger.ring)
                Text("Little").tag(Finger.little)
            }

            LabeledSlider(
                label: "Pinch sensitivity",
                caption: "How close thumb and finger must get to click.",
                value: $store.settings.gestures.pinchEngageRatio,
                range: 0.30...0.55)

            Divider()

            Toggle("Two-finger scroll", isOn: $store.settings.gestures.scrollEnabled)
            Toggle("Natural scrolling", isOn: $store.settings.gestures.naturalScroll)
                .disabled(!store.settings.gestures.scrollEnabled)
            LabeledSlider(
                label: "Scroll speed",
                caption: nil,
                value: $store.settings.gestures.scrollGainPixels,
                range: 400...3000)
                .disabled(!store.settings.gestures.scrollEnabled)

            Toggle("Fist clutch (park the cursor)", isOn: $store.settings.gestures.clutchEnabled)

            Divider()

            Picker("Dictation gesture", selection: $store.settings.gestures.dictationToggle) {
                ForEach(DictationToggleGesture.allCases, id: \.self) { gesture in
                    Text(gesture.displayName).tag(gesture)
                }
            }
            LabeledSlider(
                label: "Hold duration",
                caption: "Seconds to hold the gesture before dictation toggles.",
                value: $store.settings.gestures.dictationHoldSeconds,
                range: 0.4...2.0)

            Divider()

            Toggle("Fingertip dots", isOn: $store.settings.overlay.showFingertipDots)
            Toggle("Pinch ring", isOn: $store.settings.overlay.showPinchRing)
            Toggle("Cursor halo", isOn: $store.settings.overlay.showCursorHalo)
            Toggle("Dictation status pill", isOn: $store.settings.overlay.showStatusPill)
        }
        .padding(20)
    }
}

// MARK: - Dictation

private struct DictationSettingsTab: View {
    @ObservedObject var store: SettingsStore
    @State private var apiKeyDraft = ""
    @State private var keySaved = false

    private var usesOpenAI: Bool { store.settings.dictation.engine == "openai" }

    var body: some View {
        Form {
            Toggle("Enable voice dictation", isOn: $store.settings.dictation.enabled)

            Picker("Engine", selection: $store.settings.dictation.engine) {
                Text("Apple (on-device, private)").tag("apple")
                Text("OpenAI (cloud)").tag("openai")
            }
            Text(usesOpenAI
                 ? "Audio streams to OpenAI only while dictation is armed."
                 : "Recognition runs entirely on this Mac — nothing leaves it. First use may download a speech model.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            if usesOpenAI {
                openAISection
            }

            TextField("Language (ISO code, blank = auto)", text: $store.settings.dictation.language)

            TextField("Wake words (comma-separated)", text: listBinding($store.settings.dictation.wakeWords))
            Text("Start an utterance with one of these to begin typing.")
                .font(.caption).foregroundStyle(.secondary)

            TextField("Stop phrases (comma-separated)", text: listBinding($store.settings.dictation.stopPhrases))

            Toggle("Spoken commands (“new line”, “press enter”…)",
                   isOn: $store.settings.dictation.commandsEnabled)
            Toggle("Low-latency typing (experimental)",
                   isOn: $store.settings.dictation.typeDeltasImmediately)
            Text("Types words as you say them and corrects revisions with backspaces.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }

    @ViewBuilder
    private var openAISection: some View {
            LabeledContent("OpenAI API key") {
                VStack(alignment: .trailing, spacing: 6) {
                    SecureField("sk-proj-…", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                    HStack {
                        if keySaved {
                            Text("Saved ✓").font(.caption).foregroundStyle(.green)
                        } else {
                            Text(keyStatusText).font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Save") {
                            store.saveAPIKey(apiKeyDraft)
                            apiKeyDraft = ""
                            keySaved = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                keySaved = false
                            }
                        }
                        .disabled(apiKeyDraft.isEmpty)
                        Button("Clear") { store.clearAPIKey() }
                            .disabled(!store.apiKeyInKeychain)
                    }
                }
            }
            Text("Stored in your login keychain — never in the app or its settings files. Paste the whole key, including its “sk-” prefix.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Model", selection: $store.settings.dictation.model) {
                Text("gpt-4o-transcribe (recommended)").tag("gpt-4o-transcribe")
                Text("gpt-live-transcribe (lowest latency)").tag("gpt-live-transcribe")
                Text("gpt-4o-mini-transcribe").tag("gpt-4o-mini-transcribe")
                Text("whisper-1").tag("whisper-1")
            }

            Picker("Microphone profile", selection: $store.settings.dictation.noiseReduction) {
                Text("Built-in / far-field").tag("far_field")
                Text("Headset / near-field").tag("near_field")
                Text("No noise reduction").tag("")
            }

            Divider()
    }

    private var keyStatusText: String {
        if store.apiKeyInKeychain { return "Key in keychain" }
        if store.apiKeyAvailable { return "Using development key (.env)" }
        return "No key set"
    }

    private func listBinding(_ source: Binding<[String]>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue.joined(separator: ", ") },
            set: { text in
                source.wrappedValue = text
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            })
    }
}

// MARK: - About

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            if let icon = NSImage(named: "AppIcon") ?? bundledIcon() {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
            } else {
                Image(systemName: "pawprint.fill").font(.system(size: 64))
            }
            Text("Pawvis").font(.title2.bold())
            Text("Point, pinch, and speak — hands-free control for your Mac.")
                .foregroundStyle(.secondary)
            Text("Hand tracking runs entirely on-device via Apple Vision. " +
                 "Voice dictation streams audio to OpenAI only while armed.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
        .padding(28)
    }

    private func bundledIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "icon_1024", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

// MARK: - Shared controls

private struct LabeledSlider: View {
    let label: String
    let caption: String?
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Slider(value: $value, in: range) { Text(label) }
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
