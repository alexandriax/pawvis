import XCTest
@testable import PawvisCore

final class FirstRunPolicyTests: XCTestCase {
    private func verdict(
        completed: Bool, camera: Bool, automated: Bool = false
    ) -> FirstRunPolicy.Verdict {
        FirstRunPolicy.verdict(
            completed: completed, cameraGranted: camera, automated: automated)
    }

    func testNewInstallSeesTheWelcome() {
        XCTAssertEqual(verdict(completed: false, camera: false), .showWelcome)
    }

    /// The upgrade-safety rule: an install that already granted the camera
    /// was in use before onboarding existed. It records completion instead of
    /// getting a tour it never needed.
    func testGrantedCameraAdoptsCompletionInsteadOfTouring() {
        XCTAssertEqual(verdict(completed: false, camera: true), .adoptCompleted)
    }

    func testCompletedLaunchesAreExactlyNormal() {
        XCTAssertEqual(verdict(completed: true, camera: false), .proceedNormally)
        XCTAssertEqual(verdict(completed: true, camera: true), .proceedNormally)
    }

    /// `PAWVIS_NO_AUTOSTART` runs stay headless — no welcome window — and
    /// leave the flag alone, so an automated run on a fresh machine can't
    /// suppress onboarding for the real launch after it.
    func testAutomatedRunsNeverTourAndNeverAdopt() {
        for camera in [true, false] {
            XCTAssertEqual(
                verdict(completed: false, camera: camera, automated: true),
                .proceedNormally)
        }
    }
}
