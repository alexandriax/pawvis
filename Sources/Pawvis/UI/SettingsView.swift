import PawvisCore
import SwiftUI

// MARK: - Layout primitives
//
// Every settings control is laid out label-ABOVE-control in a leading-aligned
// column, and every caption wraps. macOS `Form`'s two-column layout squeezes
// long labels into a narrow leading column (truncating them with a leading
// ellipsis) and clips captions on the right, which is exactly the bug this
// structure removes: with a single full-width column there is no column to
// squeeze, so labels and captions can only wrap, never truncate.
//
// Rule for future settings: use SettingRow / SettingToggle / LabeledSlider
// below. Do not add bare `Picker("Long label", …)` or `TextField("Long label",
// …)` to a Form — see AGENTS.md.

/// Wrapping secondary text. Never truncates: `fixedSize(vertical:)` lets it
/// grow to as many lines as it needs.
private struct CaptionText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Title above an arbitrary control, with an optional wrapping caption below.
private struct SettingRow<Control: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            control()
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            if let caption { CaptionText(caption) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A checkbox whose label wraps instead of truncating.
private struct SettingToggle: View {
    let title: String
    var caption: String?
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: $isOn)
                .fixedSize(horizontal: false, vertical: true)
            if let caption { CaptionText(caption) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LabeledSlider: View {
    let label: String
    let caption: String?
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Slider(value: $value, in: range)
            if let caption { CaptionText(caption) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A scrolling, leading-aligned settings page. Scrolling means long pages can
/// never be clipped vertically either.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var updater: UpdateChecker

    var body: some View {
        TabView {
            GeneralSettingsTab(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
            TrackingSettingsTab(store: store)
                .tabItem { Label("Tracking", systemImage: "cursorarrow.motionlines") }
            GestureSettingsTab(store: store)
                .tabItem { Label("Gestures", systemImage: "hand.point.up.left") }
            VoiceControlSettingsTab(store: store)
                .tabItem { Label("Voice", systemImage: "mic") }
            AboutTab(updater: updater)
                .tabItem { Label("About", systemImage: "pawprint") }
        }
        .frame(width: 620, height: 580)
        .tint(PawvisTheme.purpleUI)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject var store: SettingsStore
    private var cameras: [(id: String, name: String)] { CameraManager.availableCameras() }

    var body: some View {
        SettingsPage {
            SettingRow(title: "Camera") {
                Picker("", selection: Binding(
                    get: { store.settings.general.cameraDeviceID ?? "" },
                    set: { store.settings.general.cameraDeviceID = $0.isEmpty ? nil : $0 })) {
                    Text("Automatic").tag("")
                    ForEach(cameras, id: \.id) { camera in
                        Text(camera.name).tag(camera.id)
                    }
                }
            }

            SettingToggle(
                title: "Control all displays",
                caption: "Off: hand space maps to the main display only.",
                isOn: $store.settings.general.controlAllDisplays)

            Divider()

            LabeledSlider(
                label: "Responsiveness",
                caption: "Left: smoother, steadier cursor. Right: faster, more direct.",
                value: Binding(
                    get: { store.settings.gestures.smoothing.beta },
                    set: { store.settings.gestures.smoothing.beta = $0 }),
                range: 0.005...0.09)

            SettingRow(
                title: "Reach",
                caption: store.settings.gestures.reachMode == .auto
                    ? "Sizes the tracking area from your hand's apparent size, so the whole screen stays reachable — near or far — with all fingers visible to the camera. Adjusts gently, and never mid-click."
                    : "Fixed tracking area, set with the slider below."
            ) {
                Picker("", selection: $store.settings.gestures.reachMode) {
                    Text("Auto (adapts to distance)").tag(ReachMode.auto)
                    Text("Manual").tag(ReachMode.manual)
                }
                .pickerStyle(.radioGroup)
            }

            LabeledSlider(
                label: "Manual reach",
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
                .disabled(store.settings.gestures.reachMode == .auto)

            SettingToggle(
                title: "Mirror camera",
                caption: "Leave on for a normal user-facing webcam.",
                isOn: $store.settings.gestures.mirrorCamera)

            Divider()

            SettingToggle(
                title: "Show tracking diagnostics",
                caption: "Live fps, pinch ratio, and fingertip confidence in the on-screen pill — useful when detection feels off.",
                isOn: $store.settings.general.showDiagnostics)
        }
    }
}

// MARK: - Tracking

private struct TrackingSettingsTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsPage {
            SettingRow(title: "Take control of the cursor with", caption: triggerCaption) {
                Picker("", selection: $store.settings.gestures.controlTrigger) {
                    ForEach(ControlTrigger.allCases, id: \.self) { trigger in
                        Text(trigger.displayName).tag(trigger)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Divider()

            SettingToggle(
                title: "Start tracking when Pawvis launches",
                caption: "Off: hand tracking waits until you flip the switch in the menu bar.",
                isOn: $store.settings.general.startTrackingOnLaunch)
        }
    }

    private var triggerCaption: String {
        switch store.settings.gestures.controlTrigger {
        case .openHand:
            // A fist physically contains the pinch and thumb-curl click
            // gestures, so in those modes it clicks rather than parks.
            let park: String
            switch store.settings.gestures.clickGesture {
            case .indexTap, .wholeHandPinch:
                park = "Close your hand into a fist for a moment — or take it out of view — to park the cursor again."
            case .pinch, .thumbCurl:
                park = "Take your hand out of view to park the cursor again (with your click gesture, a closing fist reads as a click and holds it instead)."
            }
            return "Your hands are tracked whenever tracking is on, but the cursor only follows after you show an open hand — all four fingers up, thumb free. \(park) A click or drag in progress never lets go, and the claw dims while control is parked."
        case .anyHand:
            return "Any hand the camera sees moves the cursor immediately — no trigger gesture."
        }
    }
}

// MARK: - Gestures

private struct GestureSettingsTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsPage {
            SettingRow(title: "Click gesture", caption: clickGestureCaption) {
                Picker("", selection: $store.settings.gestures.clickGesture) {
                    ForEach(ClickGesture.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }

            Divider()

            LabeledSlider(
                label: "Sensitivity",
                caption: "Right = a lighter gesture clicks. Left = it must close more fully.",
                value: $store.settings.gestures.pinchEngageRatio,
                range: 0.30...0.60)

            LabeledSlider(
                label: "Click vs. grab",
                caption: "Releases faster than this are clean clicks (small wobbles ignored). Hold longer — or move deliberately — to start a drag. Far left = drags start immediately.",
                value: Binding(
                    get: { store.settings.gestures.dragStartDelay },
                    set: { store.settings.gestures.dragStartDelay = $0 }),
                range: 0...0.6)

            if rightClickAvailable {
                Divider()

                SettingToggle(
                    title: "Right-click",
                    isOn: $store.settings.gestures.rightClickEnabled)

                SettingRow(
                    title: "Right-click finger",
                    caption: "Dip that finger like a mouse button to right-click; hold it down to right-drag. Measured against its neighbor, so hand tilt can't trigger it."
                ) {
                    Picker("", selection: $store.settings.gestures.rightClickFinger) {
                        Text("Pinky").tag(Finger.little)
                        Text("Ring").tag(Finger.ring)
                        Text("Middle").tag(Finger.middle)
                        if store.settings.gestures.clickGesture == .thumbCurl {
                            Text("Index").tag(Finger.index)
                        }
                    }
                    .disabled(!store.settings.gestures.rightClickEnabled)
                }
            }

            Divider()

            SettingToggle(title: "Fingertip dots", isOn: $store.settings.overlay.showFingertipDots)
            SettingToggle(title: "Closing ring around the cursor", isOn: $store.settings.overlay.showPinchRing)
            SettingToggle(title: "Claw cursor", isOn: $store.settings.overlay.showCursorHalo)
            SettingToggle(title: "Status pill", isOn: $store.settings.overlay.showStatusPill)
            SettingToggle(
                title: "Show overlay in screen recordings",
                caption: "Off keeps the claw and dots out of screenshots and captures (private by default). Turn on to record a demo of Pawvis.",
                isOn: $store.settings.overlay.showInScreenCapture)

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Button("Reset gestures to defaults") {
                    store.settings.gestures = .default
                }
                CaptionText("Restores the click gesture, control trigger, sensitivity, smoothing, reach, and timing to the tuned defaults.")
            }
        }
    }

    private var rightClickAvailable: Bool {
        store.settings.gestures.clickGesture == .indexTap
            || store.settings.gestures.clickGesture == .thumbCurl
    }

    private var clickGestureCaption: String {
        switch store.settings.gestures.clickGesture {
        case .pinch:
            return "Touch your thumb and index fingertip together to click. The cursor rides their midpoint."
        case .wholeHandPinch:
            return "Gather all your fingertips onto your thumb to click — deliberate, and averaging four fingers makes phantom clicks much rarer. The cursor rides your palm."
        case .thumbCurl:
            return "Hold your hand open like a high-five and tuck your thumb across your palm to click. Your fingers stay visible to the camera, so tracking stays solid. The cursor rides your palm."
        case .indexTap:
            return "Hold your hand open and dip your index finger like tapping a mouse button — keep the others up. Measured against the middle finger, so tilting your whole hand can't click. The cursor rides your palm."
        }
    }
}

// MARK: - Voice Control

private struct VoiceControlSettingsTab: View {
    @ObservedObject var store: SettingsStore
    @State private var screenRecording = Permissions.screenRecording()

    private var wake: String { store.settings.voiceControl.wakeWord }

    var body: some View {
        SettingsPage {
            SettingToggle(
                title: "Enable voice control",
                caption: "Recognition runs entirely on this Mac — nothing leaves it. First use may download a speech model.",
                isOn: $store.settings.voiceControl.enabled)

            Divider()

            SettingRow(
                title: "Wake word",
                caption: "Address Pawvis by saying this first: “\(wake) go to github.com”, “\(wake) type hello”, “\(wake) press enter”, “\(wake) open Safari”, “\(wake) click”, “\(wake) scroll down”."
            ) {
                TextField("", text: $store.settings.voiceControl.wakeWord)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }

            SettingRow(
                title: "Also answers to (comma-separated)",
                caption: "Common mishearings of the wake word. Close matches are accepted automatically."
            ) {
                TextField("", text: listBinding($store.settings.voiceControl.wakeWordAliases))
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            LabeledSlider(
                label: "Typing pause",
                caption: "While typing (“\(wake) type …”), this much silence ends typing mode: \(String(format: "%.1f", store.settings.voiceControl.typingPauseSeconds)) s.",
                value: $store.settings.voiceControl.typingPauseSeconds,
                range: 1.0...6.0)

            SettingRow(
                title: "Stop phrases (comma-separated)",
                caption: "Saying one of these while typing also ends typing mode."
            ) {
                TextField("", text: listBinding($store.settings.voiceControl.stopPhrases))
                    .textFieldStyle(.roundedBorder)
            }

            SettingToggle(
                title: "Spoken commands while typing (“new line”, “new paragraph”, “press enter”)",
                isOn: $store.settings.voiceControl.inlineCommandsEnabled)

            SettingToggle(
                title: "Low-latency typing (experimental)",
                caption: "Types words as you say them and corrects revisions with backspaces.",
                isOn: $store.settings.voiceControl.typeDeltasImmediately)

            Divider()

            SettingToggle(
                title: "Visual commands (Apple Intelligence)",
                caption: "Commands the grammar doesn't know (“\(wake) click sign in”) are resolved against the screen near your pointer with the on-device model — widening to the whole screen only when needed. Nothing leaves your Mac.",
                isOn: $store.settings.voiceControl.visualContextEnabled)

            if store.settings.voiceControl.visualContextEnabled,
               screenRecording != .granted {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    CaptionText("Screen Recording lets visual commands read text that isn't exposed by accessibility (canvases, images). Optional but recommended.")
                    Button("Grant…") {
                        Permissions.requestScreenRecording()
                        Permissions.openScreenRecordingSettings()
                    }
                }
            }

            Divider()

            SettingRow(title: "Language (ISO code, blank = auto)") {
                TextField("", text: $store.settings.voiceControl.language)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }
        }
        .onAppear { screenRecording = Permissions.screenRecording() }
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
    @ObservedObject var updater: UpdateChecker

    var body: some View {
        SettingsPage {
            VStack(spacing: 12) {
                if let icon = bundledIcon() {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                } else {
                    Image(systemName: "pawprint.fill").font(.system(size: 64))
                }
                Text("Pawvis").font(.title2.bold())
                Text("macOS visual gesture & voice control")
                    .italic()
                    .foregroundStyle(.secondary)
                Text("Version \(AppVersion.current)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Divider()

            UpdateSection(updater: updater)

            Divider()

            CaptionText("Hand tracking and voice control run entirely on-device — speech, and the screen context used for visual commands, never leave your Mac.")
        }
    }

    private func bundledIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "icon_1024", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
