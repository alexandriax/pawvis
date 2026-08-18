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
struct CaptionText: View {
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
struct SettingRow<Control: View>: View {
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
struct SettingToggle: View {
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

struct LabeledSlider: View {
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
struct SettingsPage<Content: View>: View {
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
    @ObservedObject var loginItem: LoginItemController
    /// Lets the update notification (and the menu bar's update row) land the
    /// user on About rather than wherever they last were.
    @ObservedObject private var router = SettingsRouter.shared

    var body: some View {
        TabView(selection: $router.tab) {
            GeneralSettingsTab(store: store, loginItem: loginItem)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            TrackingSettingsTab(store: store)
                .tabItem { Label("Tracking", systemImage: "cursorarrow.motionlines") }
                .tag(SettingsTab.tracking)
            MouseSettingsTab(store: store)
                .tabItem { Label("Mouse", systemImage: "computermouse") }
                .tag(SettingsTab.mouse)
            CustomGesturesTab(store: store)
                .tabItem { Label("Gestures", systemImage: "hand.wave") }
                .tag(SettingsTab.gestures)
            VoiceControlSettingsTab(store: store)
                .tabItem { Label("Voice (Beta)", systemImage: "mic") }
                .tag(SettingsTab.voice)
            AboutTab(updater: updater)
                .tabItem {
                    // The real claw, same as the menu bar — not the generic
                    // SF pawprint. Template, so it tints with the tab
                    // selection like its SF neighbors; the symbol stays as
                    // the bare-binary fallback (no bundle, no art).
                    if let claw = Self.tabClaw {
                        Image(nsImage: claw)
                        Text("About")
                    } else {
                        Label("About", systemImage: "pawprint")
                    }
                }
                .tag(SettingsTab.about)
        }
        .frame(width: 620, height: 580)
        .tint(PawvisTheme.accentUI)
    }

    /// Loaded once: the body re-runs on every settings change, and
    /// `PawvisGlyph` hands out fresh images on purpose (same reasoning as
    /// the menu header's claw).
    private static let tabClaw = PawvisGlyph.claw(size: 24)
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var loginItem: LoginItemController
    private var cameras: [(id: String, name: String)] { CameraManager.availableCameras() }

    var body: some View {
        SettingsPage {
            SettingToggle(
                title: "Launch Pawvis at login",
                caption: launchAtLoginCaption,
                isOn: Binding(
                    get: { store.settings.general.launchAtLogin },
                    set: { enabled in
                        store.settings.general.launchAtLogin = enabled
                        loginItem.setEnabled(enabled)
                    }))
                .disabled(loginItem.status == .unavailable)

            if loginItem.status == .requiresApproval {
                Button("Open Login Items…") { loginItem.openLoginItemsSettings() }
            }
            if let error = loginItem.lastError {
                CaptionText("Couldn’t change the login item: \(error)")
            }

            Divider()

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
                caption: "Live fps, click-dip ratio, and fingertip confidence in the on-screen pill — useful when detection feels off.",
                isOn: $store.settings.general.showDiagnostics)
        }
        .onAppear {
            // The login item can also be switched off in System Settings, so
            // re-read macOS rather than trusting our stored value.
            if loginItem.systemHasDisabledIt(), store.settings.general.launchAtLogin {
                store.settings.general.launchAtLogin = false
            }
        }
    }

    private var launchAtLoginCaption: String {
        switch loginItem.status {
        case .requiresApproval:
            return "macOS is holding this back: switch Pawvis on under System Settings → General → Login Items."
        case .unavailable:
            return "Only available when Pawvis runs from its app bundle."
        case .enabled, .notRegistered:
            return "Starts Pawvis automatically after you log in. It opens straight into the menu bar — no window, no dock icon."
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

            if store.settings.gestures.controlTrigger == .openHand {
                LabeledSlider(
                    label: "Open-hand strictness",
                    caption: "How unmistakably open your hand must be to take the cursor. Right: fingers fully extended, well clear of the palm — fewer accidental grabs. Left: a looser hand qualifies sooner.",
                    value: Binding(
                        get: { store.settings.gestures.poseThresholds.openHandMinOpenness },
                        set: { store.settings.gestures.poseThresholds.openHandMinOpenness = $0 }),
                    range: 0.20...0.60)
            }

            Divider()

            SettingToggle(
                title: "Wave both hands to stop tracking",
                caption: "Hold up both hands open with fingers spread wide, like a double high-five, then cross them over each other and back. Once they've traded sides enough times, hand tracking switches off entirely — the same as the menu bar switch.",
                isOn: $store.settings.gestures.crissCrossDisableEnabled)

            SettingRow(
                title: "Crossings required",
                caption: "How many times your hands must trade sides. Two is one full wave: cross over, then back."
            ) {
                HStack(spacing: 10) {
                    Text("\(store.settings.gestures.crissCrossDisableCrossings)×")
                        .font(.callout)
                        .monospacedDigit()
                    Stepper("", value: $store.settings.gestures.crissCrossDisableCrossings,
                            in: 1...6)
                }
            }
            .disabled(!store.settings.gestures.crissCrossDisableEnabled)

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
            return "Your hands are tracked whenever tracking is on, but the cursor only follows after you show an open hand — all four fingers up, thumb free. Close your hand into a fist for a moment — or take it out of view — to park the cursor again. A click or drag in progress never lets go, and the claw dims while control is parked."
        case .anyHand:
            return "Any hand the camera sees moves the cursor immediately — no trigger gesture."
        case .gesturesOnly:
            return "The mouse is never touched: no pointing, no clicks, no scrolling. Your hands become a remote — only the gestures you've assigned in the Gestures tab (and the stop-tracking wave) do anything."
        }
    }
}

// MARK: - Mouse

private struct MouseSettingsTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 5) {
                Button("Open Gesture Guide") { GuideWindow.show() }
                CaptionText("Every gesture, illustrated — the mouse set below plus anything you assign in the Gestures tab.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("Click — mouse tap")
                    .font(.callout)
                CaptionText("Hold your hand open and dip your index finger like tapping a mouse button — keep the others up. Measured against the middle finger, so tilting your whole hand can't click. The cursor rides your \(store.settings.gestures.pointerSource.inlineName).")
            }

            LabeledSlider(
                label: "Sensitivity",
                caption: "Right = a lighter dip clicks. Left = the finger must dip further.",
                value: $store.settings.gestures.pinchEngageRatio,
                range: 0.30...0.60)

            LabeledSlider(
                label: "Click vs. grab",
                caption: "Releases faster than this are clean clicks (small wobbles ignored). Hold longer — or move deliberately — to start a drag. Far left = drags start immediately.",
                value: Binding(
                    get: { store.settings.gestures.dragStartDelay },
                    set: { store.settings.gestures.dragStartDelay = $0 }),
                range: 0...0.6)

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
                }
                .disabled(!store.settings.gestures.rightClickEnabled)
            }

            Divider()

            SettingToggle(
                title: "Middle-click",
                caption: "Off by default. Gives a third finger the middle mouse button — open links in background tabs, close tabs with one click.",
                isOn: $store.settings.gestures.middleClickEnabled)

            SettingRow(
                title: "Middle-click finger",
                caption: "Dips exactly like the right-click finger. If it collides with the right-click finger, right-click keeps it."
            ) {
                Picker("", selection: $store.settings.gestures.middleClickFinger) {
                    Text("Ring").tag(Finger.ring)
                    Text("Middle").tag(Finger.middle)
                    Text("Pinky").tag(Finger.little)
                }
                .disabled(!store.settings.gestures.middleClickEnabled)
            }

            Divider()

            SettingToggle(
                title: "Scroll gesture",
                caption: "Fold your middle and ring fingers in — index and pinky stay up — then move your hand up and down to scroll. The cursor parks while the pose is held.",
                isOn: $store.settings.gestures.scrollEnabled)

            SettingToggle(
                title: "Horizontal scrolling",
                caption: "Sideways hand movement scrolls sideways too, with the same deadband per axis. Off: only vertical movement scrolls.",
                isOn: Binding(
                    get: { store.settings.gestures.scrollAxes == .both },
                    set: { store.settings.gestures.scrollAxes = $0 ? .both : .vertical }))
                .disabled(!store.settings.gestures.scrollEnabled)

            SettingToggle(
                title: "Invert scroll direction",
                caption: "On: moving your hand up scrolls the page down. Vertical only — horizontal scrolling always follows the hand.",
                isOn: $store.settings.gestures.scrollInvert)
                .disabled(!store.settings.gestures.scrollEnabled)

            LabeledSlider(
                label: "Scroll speed",
                caption: "How much a hand movement scrolls, both axes. Left: slower, more precise. Right: faster.",
                value: $store.settings.gestures.scrollGain,
                range: GestureConfig.scrollGainRange)
                .disabled(!store.settings.gestures.scrollEnabled)

            Divider()

            SettingToggle(
                title: "Dwell click",
                caption: "Clicking without the finger dip: park the cursor on a target, hold it still, and after the dwell time a left click fires on its own (the ring around the claw tightens as it counts down). Move the cursor away to arm the next one. It never fires while a button is held, while scrolling, or while the cursor is parked.",
                isOn: $store.settings.gestures.dwellClickEnabled)

            LabeledSlider(
                label: "Dwell time",
                caption: "\(String(format: "%.1f", store.settings.gestures.dwellSeconds)) s of holding still before the click fires. Shorter clicks sooner but fires more easily while you rest; longer is calmer but slower.",
                value: $store.settings.gestures.dwellSeconds,
                range: 0.5...3.0)
                .disabled(!store.settings.gestures.dwellClickEnabled)

            SettingRow(
                title: "The cursor rides",
                caption: "The palm barely moves while a finger dips, which is what keeps clicks from smearing into drags. The fingertip sources point more directly but wobble during finger clicks; they pair best with dwell click, where clicking moves no fingers."
            ) {
                Picker("", selection: $store.settings.gestures.pointerSource) {
                    ForEach(PointerSource.allCases, id: \.self) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .frame(maxWidth: 320)
            }

            Divider()

            SettingToggle(title: "Fingertip dots", isOn: $store.settings.overlay.showFingertipDots)
            SettingToggle(title: "Closing ring around the cursor", isOn: $store.settings.overlay.showPinchRing)
            SettingToggle(title: "Claw cursor", isOn: $store.settings.overlay.showCursorHalo)
            SettingToggle(
                title: "Status pill",
                caption: "Voice hints, confirmations and warnings at the top of the screen. Each one fades after five seconds, or click its ✕ to dismiss it now.",
                isOn: $store.settings.overlay.showStatusPill)
            SettingToggle(
                title: "Show overlay in screen recordings",
                caption: "Off keeps the claw and dots out of screenshots and captures (private by default). Turn on to record a demo of Pawvis.",
                isOn: $store.settings.overlay.showInScreenCapture)

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Button("Reset gestures to defaults") {
                    store.settings.gestures = .default
                }
                CaptionText("Restores the control trigger, sensitivity, right-click, middle-click, scrolling, dwell click, the pointer source, the tracking-off wave, smoothing, reach, and timing to the tuned defaults.")
            }
        }
    }
}

// MARK: - Voice Control

/// The agent hand-off risk copy, in one place, so the warning box and the
/// acceptance dialog can never drift apart (and so the README and the website
/// have a single wording to restate).
@MainActor
private enum AgentRiskCopy {
    static func title(_ tool: AgentCLIExecutor.Tool) -> String {
        "Hand every spoken command to \(tool.displayName)?"
    }

    /// Short form for the always-visible warning box in Settings.
    static func short(tool: AgentCLIExecutor.Tool, wake: String) -> String {
        "High risk: \(tool.displayName) runs with ALL permission checks bypassed. It never asks you to confirm anything, it just does what it was told, as you, with your files and your logged-in sessions. A misheard command still runs. Only “\(wake), stop listening” stays local, and what it does is your responsibility."
    }

    /// Long form for the dialog the user has to accept.
    static func body(tool: AgentCLIExecutor.Tool, wake: String) -> String {
        """
        \(tool.displayName) is launched with its own permission prompts turned off, so nothing pauses to confirm anything. It carries out what it was handed, as you, with your files, your logged-in sessions and your credentials: deleting or rewriting files, installing software, running shell commands, opening apps, sending things on your behalf.

        Everything you say after “\(wake)” is sent to it, and speech recognition is not perfect, so a misheard command is still executed. This is also the only mode that sends what you say beyond this Mac. Only “\(wake), stop listening” stays local. By default Pawvis reads each command back on screen and sends it only after you say “\(wake) yes”; switch that confirmation off in Settings → Voice and commands go the moment they are heard.

        Stay on Apple Intelligence (on-device) if you want a handler that can only do what Pawvis itself can do.

        Turning this on is your call and your responsibility: Pawvis is provided as is, with no warranty, and its developer accepts no liability for anything done with it, intended or not. Please use it responsibly.
        """
    }
}

/// A pending "yes, I understand" for the agent hand-off. `apply` is the change
/// the user asked for, held back until they accept it.
private struct AgentConsentRequest: Identifiable {
    let id = UUID()
    let tool: AgentCLIExecutor.Tool
    let apply: () -> Void
}

/// A warning that reads as a warning: yellow triangle, tinted card, wrapping
/// text. Used for the risks the user has to weigh, not the ones they can fix
/// with a button.
private struct RiskNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            CaptionText(text)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.yellow.opacity(0.12)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.yellow.opacity(0.35)))
    }
}

private struct VoiceControlSettingsTab: View {
    @ObservedObject var store: SettingsStore
    @State private var screenRecording = Permissions.screenRecording()
    @State private var consent: AgentConsentRequest?
    @FocusState private var wakeWordFocused: Bool

    private var wake: String { store.settings.voiceControl.wakeWord }

    /// The handler currently in force, if it's an agent CLI.
    private var selectedAgent: AgentCLIExecutor.Tool? {
        AgentCLIExecutor.Tool(rawValue: store.settings.voiceControl.agentExecutor)
    }

    var body: some View {
        SettingsPage {
            SettingToggle(
                title: "Enable voice control (beta)",
                caption: "Off by default while in beta. Recognition runs entirely on this Mac — nothing leaves it. First use may download a speech model.",
                isOn: Binding(
                    get: { store.settings.voiceControl.enabled },
                    set: { enabled in
                        // Turning voice control on while an agent handler is
                        // selected arms the hand-off, so it goes through the
                        // same acceptance dialog as picking the agent does.
                        guard enabled, let tool = selectedAgent else {
                            store.settings.voiceControl.enabled = enabled
                            return
                        }
                        consent = AgentConsentRequest(tool: tool) {
                            store.settings.voiceControl.enabled = true
                        }
                    }))

            RiskNote(text: "Voice control acts on what it hears. It clicks, types, presses keys and opens apps for real, wherever the pointer and focus happen to be, and a misheard command is still a command. A multi-step command keeps acting until it finishes, hits its limits, or you say “\(wake) stop”.")

            Divider()

            SettingRow(
                title: "Wake word",
                caption: "Every command starts with this word — speech without it is ignored. “\(wake) go to github.com”, “\(wake) type hello”, “\(wake) press enter”, “\(wake) open Safari”, “\(wake) click”, “\(wake) scroll down”."
            ) {
                VStack(alignment: .leading, spacing: 5) {
                    TextField("", text: $store.settings.voiceControl.wakeWord)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .focused($wakeWordFocused)
                        .onSubmit { commitWakeWord() }
                    if !VoiceControlParser.supportsFuzzyMatching(store.settings.voiceControl.wakeWord) {
                        CaptionText("Short wake words match strictly, with no tolerance for mishearings.")
                    }
                }
                // Commit on every way of leaving the field: Return
                // (onSubmit above), focus moving elsewhere, or the tab or
                // window going away mid-edit.
                .onChange(of: wakeWordFocused) { _, focused in
                    if !focused { commitWakeWord() }
                }
                .onDisappear { commitWakeWord() }
            }

            SettingRow(
                title: "Also answers to (comma-separated)",
                caption: "Common mishearings of the wake word. Close matches are accepted automatically."
            ) {
                TextField("", text: listBinding($store.settings.voiceControl.wakeWordAliases))
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            SettingToggle(
                title: "Show what Pawvis hears at the top of the screen",
                caption: "A capsule shows the live transcript while you speak, so you can see exactly what's being interpreted. Click it to dismiss it early.",
                isOn: $store.settings.voiceControl.transcriptOverlayEnabled)

            if store.settings.voiceControl.transcriptOverlayEnabled {
                SettingToggle(
                    title: "Keep it up until clicked",
                    caption: "Off: it hides on its own after the delay below.",
                    isOn: $store.settings.voiceControl.transcriptOverlayManualDismiss)

                LabeledSlider(
                    label: "Hide after",
                    caption: "\(String(format: "%.1f", store.settings.voiceControl.transcriptOverlaySeconds)) s after an utterance completes.",
                    value: $store.settings.voiceControl.transcriptOverlaySeconds,
                    range: 1.0...10.0)
                .disabled(store.settings.voiceControl.transcriptOverlayManualDismiss)
            }

            SettingToggle(
                title: "Play a sound when a command is heard and when it finishes",
                caption: "Two subtle system sounds: Tink acknowledges a command (when it is heard, and again when it succeeds), Bottle marks a failure. Off by default.",
                isOn: $store.settings.voiceControl.audibleCues)

            Divider()

            SettingRow(
                title: "Commands after “\(wake)” are handled by",
                caption: agentPickerCaption
            ) {
                Picker("", selection: Binding(
                    get: { store.settings.voiceControl.agentExecutor },
                    set: { selection in
                        // Switching to an agent CLI is the moment the risk
                        // becomes real, so the change is held until the user
                        // accepts it. Setting `consent` re-renders the tab,
                        // which snaps the picker back to the live value.
                        guard let tool = AgentCLIExecutor.Tool(rawValue: selection),
                              selection != store.settings.voiceControl.agentExecutor else {
                            store.settings.voiceControl.agentExecutor = selection
                            return
                        }
                        consent = AgentConsentRequest(tool: tool) {
                            store.settings.voiceControl.agentExecutor = selection
                        }
                    })) {
                    Text("Apple Intelligence (on-device)").tag("")
                    Text("Claude Code (agent CLI)").tag("claude")
                    Text("Codex CLI (agent CLI)").tag("codex")
                }
                .frame(maxWidth: 320)
            }

            if let tool = selectedAgent {
                RiskNote(text: AgentRiskCopy.short(tool: tool, wake: wake))

                if let path = AgentCLIExecutor.binaryPath(for: tool) {
                    CaptionText("Found \(tool.displayName) at \(path).")
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        CaptionText("\(tool.displayName) wasn't found on this Mac — install it (and sign in) or pick another handler.")
                    }
                }

                SettingToggle(
                    title: "Confirm before sending to the agent",
                    caption: "The command is read back in the top-of-screen capsule and sent only after you say “\(wake) yes” (“\(wake) no” cancels, and so do ten seconds of silence). Off: everything after the wake word goes to \(tool.displayName) the moment it is heard.",
                    isOn: $store.settings.voiceControl.agentConfirm)

                LabeledSlider(
                    label: "Agent timeout",
                    caption: "Give up on a background run after \(Int(store.settings.voiceControl.agentTimeoutSeconds)) s.",
                    value: $store.settings.voiceControl.agentTimeoutSeconds,
                    range: 30...300)

                AgentSessionsSection(tool: tool)
            }

            SettingToggle(
                title: "Apple Intelligence autopilot",
                caption: "Commands the grammar doesn't match are carried out step by step: Pawvis looks at the screen, acts, then looks again until the request is done (“\(wake) open Notes and start a new note”). Up to 8 steps per command, entirely on this Mac. Say “\(wake) stop” to cancel a run.",
                isOn: $store.settings.voiceControl.visualContextEnabled)
                .disabled(!store.settings.voiceControl.agentExecutor.isEmpty)

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

            Divider()

            VoiceActivitySection()
        }
        .onAppear { screenRecording = Permissions.screenRecording() }
        .alert(
            consent.map { AgentRiskCopy.title($0.tool) } ?? "",
            isPresented: Binding(
                get: { consent != nil },
                set: { if !$0 { consent = nil } }),
            presenting: consent
        ) { request in
            Button("Cancel", role: .cancel) { consent = nil }
            Button("I understand, turn it on", role: .destructive) {
                request.apply()
                consent = nil
            }
        } message: { request in
            Text(AgentRiskCopy.body(tool: request.tool, wake: wake))
        }
    }

    private var agentPickerCaption: String {
        if store.settings.voiceControl.agentExecutor.isEmpty {
            return "On-device: the instant grammar runs first, then Apple Intelligence carries out the rest step by step, grounded in what is on screen. Private and fast."
        }
        return "EVERYTHING after the wake word goes to the agent, asked to perform it via computer use. Slower than on-device and far more capable; the run streams in the corner panel and the outcome flashes in the top-of-screen capsule."
    }

    /// The wake word, committed: trimmed, and never empty. A blank wake word
    /// would leave voice control with no address at all, so it snaps back to
    /// the default instead of being saved.
    private func commitWakeWord() {
        let current = store.settings.voiceControl.wakeWord
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let committed = trimmed.isEmpty ? VoiceControlConfig().wakeWord : trimmed
        if committed != current {
            store.settings.voiceControl.wakeWord = committed
        }
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

/// The in-memory voice pipeline log: wake verdicts, parsed commands, routing,
/// steps and outcomes, newest at the bottom like a terminal. Deliberately not
/// part of the settings tree — it is diagnostic state, never persisted (voice
/// transcripts are sensitive), and speech that failed the wake gate appears
/// only as an aggregate count, never as words (see `VoiceActivityLog`).
private struct VoiceActivitySection: View {
    @ObservedObject private var log = VoiceActivityLog.shared
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                CaptionText("The last \(VoiceActivityLog.cap) voice events, kept in memory only: nothing is written to disk, and the list clears when Pawvis quits. Speech without the wake word is counted, never recorded. Copy puts the log on the clipboard for a bug report, and a quoted transcript can be pasted into Pawvis --wake-eval to debug a missed wake.")

                if log.ignoredCount > 0 {
                    Text(log.ignoredSummary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if log.entries.isEmpty {
                    CaptionText("Nothing yet. Start voice control and speak a command; every pipeline decision lands here.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(log.entries) { entry in
                                Text("\(VoiceActivityLog.timestamp.string(from: entry.time))  \(entry.kind.tag) \(entry.text)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(color(for: entry.kind))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .defaultScrollAnchor(.bottom)
                    .frame(height: 180)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .quaternarySystemFill)))
                }

                HStack(spacing: 10) {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(log.plainText, forType: .string)
                    }
                    Button("Clear") { log.clear() }
                }
                .disabled(log.entries.isEmpty && log.ignoredCount == 0)
            }
            .padding(.top, 6)
        } label: {
            Text("Recent activity")
                .font(.callout)
        }
    }

    private func color(for kind: VoiceActivityLog.Entry.Kind) -> Color {
        switch kind {
        case .failure: return .red
        case .info: return .secondary
        default: return .primary
        }
    }
}

/// Live list of background agent CLI runs — the same sessions the corner
/// activity panel shows, cancellable from here too.
private struct AgentSessionsSection: View {
    let tool: AgentCLIExecutor.Tool
    @ObservedObject var manager = AgentSessionManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Background agent sessions")
                .font(.callout)
            if manager.sessions.isEmpty {
                CaptionText("None right now. While \(tool.displayName) is working on a spoken command, the run shows here — and in the panel at the bottom-right of your screen — with its live output and a Cancel button.")
            } else {
                ForEach(manager.sessions) { session in
                    HStack(alignment: .top, spacing: 10) {
                        sessionIcon(session)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("“\(session.instruction)”")
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            switch session.phase {
                            case .running:
                                HStack(spacing: 6) {
                                    Text(session.tool.displayName)
                                    ElapsedText(since: session.startedAt)
                                    if let last = session.tail.last {
                                        Text("· \(last)")
                                            .lineLimit(1)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            case .finished(_, let message):
                                CaptionText(message)
                            }
                        }
                        Spacer(minLength: 8)
                        if session.phase.isRunning {
                            Button("Cancel") { manager.cancel(session.id) }
                                .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .quaternarySystemFill)))
                }
            }

            Button("Open agent log") { AgentAuditLog.shared.revealInFinder() }
                .controlSize(.small)
            CaptionText("Every hand-off is written to a local log only you can read: when, which agent, the exact instruction sent, and how the run ended.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func sessionIcon(_ session: AgentSessionSnapshot) -> some View {
        switch session.phase {
        case .running:
            ProgressView()
                .controlSize(.small)
        case .finished(let success, _):
            Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(success ? .green : .yellow)
        }
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
                Text("Touch-free hand control for your Mac")
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

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Disclaimer")
                    .font(.callout)
                CaptionText("Pawvis operates this Mac. It moves the real cursor and posts real clicks, drags and scrolls on your behalf, so a stray gesture can click whatever is under the pointer. With voice control on it can also open apps, type and press keys, and with the optional agent hand-off enabled it can carry out whatever the agent decides to do, without asking first.")
                CaptionText("Pawvis is provided as is, without warranty of any kind. Its developer accepts no liability for any action taken with it, intentional or not, or for any resulting loss or damage. You are responsible for what happens on your machine: please use it responsibly, and keep the menu bar toggle in reach.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bundledIcon() -> NSImage? { PawvisGlyph.pawPhoto() }
}
