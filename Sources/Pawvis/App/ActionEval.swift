import AppKit
import Foundation
import PawvisCore

/// `Pawvis --action-eval <kind> [argument…]` — perform one gesture action
/// through the real `GestureActionRunner` and print what the pill would say.
/// The eyes-on hook for the action layer, like `--voice-eval` for the ladder:
/// "does desktopRight actually switch the desktop on THIS machine" is a
/// question for the machine, not for reading the code.
@MainActor
func runActionEval(_ args: [String]) -> Int32 {
    guard let first = args.first, let kind = GestureAction.Kind(rawValue: first) else {
        print("usage: Pawvis --action-eval <kind> [argument…]")
        print("kinds: \(GestureAction.Kind.allCases.map(\.rawValue).joined(separator: " "))")
        return 2
    }
    let argument = args.dropFirst().joined(separator: " ")
    let action = GestureAction(kind: kind, argument: argument)

    let runner = GestureActionRunner()
    var followUp: String?
    runner.onFollowUp = { followUp = $0 }
    runner.stopTracking = { print("(would stop tracking)") }
    runner.toggleVoiceControl = { print("(would toggle voice control)") }

    print("perform: \(action.summary)")
    let feedback = runner.perform(action)
    print("feedback: \(feedback)")

    // Long-running actions (the desktop switch) report a follow-up; pump the
    // main loop long enough for it to land.
    let waits: TimeInterval = (kind == .desktopLeft || kind == .desktopRight) ? 7 : 1.5
    let deadline = Date().addingTimeInterval(waits)
    while followUp == nil, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    if let followUp {
        print("follow-up: \(followUp)")
    }
    return 0
}
