import XCTest
@testable import PawvisCore

/// A step that validates must be executable: key names and URLs are checked
/// with the same parsers that will execute them, and element indices against
/// the same list the model saw.
final class AutopilotStepValidationTests: XCTestCase {
    private func validate(_ step: AutopilotStep, elements: Int = 3) -> AutopilotStepValidation {
        AutopilotPolicy.validate(step, elementCount: elements)
    }

    func testClickRequiresElementIndexInRange() {
        XCTAssertEqual(validate(AutopilotStep(action: .click, elementIndex: 2)), .valid)
        XCTAssertNotEqual(validate(AutopilotStep(action: .click, elementIndex: 3)), .valid)
        XCTAssertNotEqual(validate(AutopilotStep(action: .click, elementIndex: -1)), .valid)
        XCTAssertNotEqual(validate(AutopilotStep(action: .click)), .valid)
    }

    func testTypeTextRequiresNonEmptyArgument() {
        XCTAssertEqual(
            validate(AutopilotStep(action: .typeText, argument: "hello")), .valid)
        XCTAssertNotEqual(validate(AutopilotStep(action: .typeText)), .valid)
        XCTAssertNotEqual(
            validate(AutopilotStep(action: .typeText, argument: "")), .valid)
    }

    func testTypeTextIntoElementChecksTheIndex() {
        XCTAssertEqual(
            validate(AutopilotStep(action: .typeText, elementIndex: 1, argument: "hi")),
            .valid)
        XCTAssertNotEqual(
            validate(AutopilotStep(action: .typeText, elementIndex: 9, argument: "hi")),
            .valid)
    }

    func testPressKeyArgumentValidatedThroughSpokenKeyParser() {
        XCTAssertEqual(
            validate(AutopilotStep(action: .pressKey, argument: "return")), .valid)
        XCTAssertEqual(
            validate(AutopilotStep(action: .pressKey, argument: "command shift t")),
            .valid)
        XCTAssertNotEqual(
            validate(AutopilotStep(action: .pressKey, argument: "the any key")), .valid)
        XCTAssertNotEqual(validate(AutopilotStep(action: .pressKey)), .valid)
    }

    func testGoToURLArgumentNormalizedThroughSpokenURLNormalizer() {
        XCTAssertEqual(
            validate(AutopilotStep(action: .goToURL, argument: "github dot com")),
            .valid)
        XCTAssertEqual(
            validate(AutopilotStep(action: .goToURL, argument: "github.com")), .valid)
        XCTAssertNotEqual(
            validate(AutopilotStep(action: .goToURL, argument: "no address here")),
            .valid)
    }

    func testAppActionsNeedAName() {
        XCTAssertEqual(
            validate(AutopilotStep(action: .openApp, argument: "Notes")), .valid)
        XCTAssertNotEqual(validate(AutopilotStep(action: .openApp)), .valid)
        XCTAssertNotEqual(validate(AutopilotStep(action: .switchToApp)), .valid)
    }

    func testDoneAndCannotProceedNeedNoArguments() {
        XCTAssertEqual(validate(AutopilotStep(action: .done)), .valid)
        XCTAssertEqual(validate(AutopilotStep(action: .cannotProceed)), .valid)
        XCTAssertEqual(validate(AutopilotStep(action: .wait)), .valid)
        XCTAssertEqual(validate(AutopilotStep(action: .scrollDown)), .valid)
    }
}
