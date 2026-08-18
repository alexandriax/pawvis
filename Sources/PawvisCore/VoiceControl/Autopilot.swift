import Foundation

/// One step of the autopilot loop, as the on-device model chooses it. Plain
/// mirror of the app layer's @Generable schema (FoundationModels never
/// reaches PawvisCore), same pattern as AgentOutput mirroring the CLI stream.
public enum AutopilotAction: String, CaseIterable, Equatable, Sendable {
    case click, doubleClick, rightClick
    case typeText, pressKey
    case openApp, switchToApp
    case goToURL, webSearch
    case scrollUp, scrollDown
    case wait
    /// The goal is already satisfied; nothing to do.
    case done
    /// Stuck — or, with `targetNotInContext`, "show me more of the screen".
    case cannotProceed
}

public struct AutopilotStep: Equatable, Sendable {
    public var action: AutopilotAction
    public var elementIndex: Int?
    public var argument: String?
    /// The model marks the action that finishes the goal, so single-step
    /// commands cost exactly one round and multi-step runs know when to end.
    public var goalComplete: Bool
    public var targetNotInContext: Bool

    public init(action: AutopilotAction, elementIndex: Int? = nil,
                argument: String? = nil, goalComplete: Bool = false,
                targetNotInContext: Bool = false) {
        self.action = action
        self.elementIndex = elementIndex
        self.argument = argument
        self.goalComplete = goalComplete
        self.targetNotInContext = targetNotInContext
    }
}

/// One thing on screen, in prompt-ready form. Coordinates are global screen
/// points, top-left origin — the same space the app layer clicks in.
public struct AutopilotElement: Equatable, Sendable {
    public var label: String
    /// Plain word, not an AX role: button, link, field, menu, item, tab,
    /// text… — reads better to a small model and costs fewer tokens.
    public var kind: String
    /// Actionable controls sort ahead of passive text when trimming.
    public var actionable: Bool
    /// The element's live state, when it has any: a checkbox's 0-or-1, a
    /// slider's number, a row's selection. Captured for the completion
    /// signature — a toggle flip is a value-ONLY change (same label, same
    /// frame), invisible to a signature that ignores this field — and
    /// deliberately not rendered into the prompt.
    public var value: String?
    public var x: Double, y: Double, width: Double, height: Double

    public init(label: String, kind: String, actionable: Bool,
                value: String? = nil,
                x: Double, y: Double, width: Double, height: Double) {
        self.label = label
        self.kind = kind
        self.actionable = actionable
        self.value = value
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
}

/// What the autopilot can see for one step: the app-layer snapshot reduced to
/// prompt ingredients.
public struct AutopilotScreen: Equatable, Sendable {
    public var appName: String?
    public var windowTitle: String?
    public var focusedElement: String?
    public var pointerX: Double
    public var pointerY: Double
    public var isFullScreen: Bool
    public var elements: [AutopilotElement]

    public init(appName: String? = nil, windowTitle: String? = nil,
                focusedElement: String? = nil, pointerX: Double = 0,
                pointerY: Double = 0, isFullScreen: Bool = false,
                elements: [AutopilotElement] = []) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.focusedElement = focusedElement
        self.pointerX = pointerX
        self.pointerY = pointerY
        self.isFullScreen = isFullScreen
        self.elements = elements
    }
}

/// One line of what already happened, fed back to the model each step so it
/// never repeats itself — and shown to the user in the progress panel.
public struct AutopilotHistoryEntry: Equatable, Sendable {
    public var line: String
    public var succeeded: Bool

    public init(line: String, succeeded: Bool) {
        self.line = line
        self.succeeded = succeeded
    }
}

/// Whether a proposed step is executable against the screen it was chosen
/// from. Invalid steps become failure history lines, never actions.
public enum AutopilotStepValidation: Equatable, Sendable {
    case valid
    case invalid(reason: String)
}

extension AutopilotStep {
    /// Steps are rendered for history by Swift, never self-described by the
    /// model — a generated note would cost decode latency every step and add
    /// a hallucination surface for zero information.
    public func describe(targetLabel: String?) -> String {
        func target() -> String {
            if let targetLabel, !targetLabel.isEmpty { return "“\(targetLabel)”" }
            return "the target"
        }
        switch action {
        case .click: return "clicked \(target())"
        case .doubleClick: return "double-clicked \(target())"
        case .rightClick: return "right-clicked \(target())"
        case .typeText:
            let text = argument ?? ""
            let shown = text.count > 40 ? String(text.prefix(40)) + "…" : text
            return "typed “\(shown)”"
        case .pressKey: return "pressed \(argument ?? "a key")"
        case .openApp: return "opened \(argument ?? "an app")"
        case .switchToApp: return "switched to \(argument ?? "an app")"
        case .goToURL: return "went to \(argument ?? "a URL")"
        case .webSearch: return "searched for \(argument ?? "something")"
        case .scrollUp: return "scrolled up"
        case .scrollDown: return "scrolled down"
        case .wait: return "waited for the screen"
        case .done: return "nothing left to do"
        case .cannotProceed: return "couldn't see a way forward"
        }
    }
}
