import XCTest
@testable import PawvisCore

/// The "sequences never smuggle control commands" invariant: clauseSequence
/// only assembles a `.sequence` when every clause's own command is a plain,
/// executable one — a clause that resolves to .resolve/.sequence/
/// .stopVoiceControl/.cancelActivity sends the WHOLE utterance to resolve
/// instead (see VoiceControlParser.clauseSequence). So a `.sequence`'s
/// members never need the screen and never interrupt the loop.
///
/// Both phrases below are multi-clause by AutopilotPolicy.isMultiClause, so
/// if either had reached `.resolve`, AutopilotPolicy.goesStraightToLoop
/// would route it straight to the visual loop. They never reach `.resolve`,
/// so that routing rule is simply irrelevant for them.
final class ClauseSequenceGateTests: XCTestCase {
    private let parser = VoiceControlParser()

    func testSequencesNeverSmuggleControlCommands() {
        let phrases = [
            "open chrome and go to youtube dot com",
            "pause this, open up a new tab, and go to youtube dot com",
        ]
        for phrase in phrases {
            XCTAssertTrue(AutopilotPolicy.isMultiClause(goal: phrase),
                          "'\(phrase)' should read as multi-clause")

            guard case .sequence(let members)? = parser.parseRemainder(phrase).command else {
                XCTFail("'\(phrase)' did not produce a .sequence")
                continue
            }
            for member in members {
                switch member {
                case .resolve, .sequence, .stopVoiceControl, .cancelActivity:
                    XCTFail("'\(phrase)' sequence smuggled a control command: \(member)")
                default:
                    break
                }
            }
        }
    }
}
