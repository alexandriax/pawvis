import XCTest
@testable import PawvisCore

final class CameraSelectionPolicyTests: XCTestCase {
    private typealias Candidate = CameraSelectionPolicy.Candidate

    private let builtIn = Candidate(id: "facetime", kind: .builtIn)
    private let iphone = Candidate(id: "iphone", kind: .continuity)
    private let webcam = Candidate(id: "usb", kind: .other)

    private func choose(
        pick: String? = nil, available: [Candidate], systemPreferred: String? = nil
    ) -> String? {
        CameraSelectionPolicy.choose(
            pick: pick, available: available, systemPreferred: systemPreferred)
    }

    // MARK: Automatic

    func testAutomaticPrefersTheBuiltInCameraWhateverTheDiscoveryOrder() {
        XCTAssertEqual(choose(available: [webcam, iphone, builtIn]), "facetime")
        XCTAssertEqual(choose(available: [builtIn, webcam]), "facetime")
    }

    /// The feature: macOS naming a mounted iPhone as its preferred camera is
    /// the one signal Automatic follows away from the built-in camera.
    func testAutomaticAdoptsTheIPhoneMacOSPrefers() {
        XCTAssertEqual(
            choose(available: [builtIn, iphone], systemPreferred: "iphone"), "iphone")
    }

    /// Merely being nearby is not being mounted: an iPhone in the list that
    /// macOS does not prefer stays a picker entry.
    func testAutomaticIgnoresAnUnpreferredIPhone() {
        XCTAssertEqual(choose(available: [builtIn, iphone]), "facetime")
        XCTAssertEqual(
            choose(available: [builtIn, iphone], systemPreferred: "facetime"), "facetime")
    }

    /// A USB webcam the system happens to rank first could point anywhere; a
    /// hand tracker must not go blind on its own. Pick it to use it.
    func testAutomaticNeverFollowsTheSystemToAnOtherKindOfCamera() {
        XCTAssertEqual(
            choose(available: [builtIn, webcam], systemPreferred: "usb"), "facetime")
    }

    func testAutomaticIgnoresASystemPreferenceForACameraThatIsNotThere() {
        XCTAssertEqual(
            choose(available: [builtIn], systemPreferred: "iphone"), "facetime")
    }

    /// A Mac mini: no built-in camera, so the first camera at all.
    func testNoBuiltInCameraMeansTheFirstCameraAtAll() {
        XCTAssertEqual(choose(available: [webcam, iphone]), "usb")
    }

    func testNoCameraAtAllMeansNil() {
        XCTAssertNil(choose(available: []))
        XCTAssertNil(choose(pick: "facetime", available: [], systemPreferred: "iphone"))
    }

    // MARK: Explicit picks

    /// Manual mode: the pick wins even while macOS would hand over the iPhone.
    func testAPresentPickBeatsTheSystemsIPhone() {
        XCTAssertEqual(
            choose(pick: "usb", available: [builtIn, iphone, webcam], systemPreferred: "iphone"),
            "usb")
        XCTAssertEqual(
            choose(pick: "facetime", available: [builtIn, iphone], systemPreferred: "iphone"),
            "facetime")
    }

    /// Picking the iPhone explicitly pins it, mounted or not.
    func testPickingTheIPhoneNeedsNoSystemBlessing() {
        XCTAssertEqual(choose(pick: "iphone", available: [builtIn, iphone]), "iphone")
    }

    /// An unplugged pick is Automatic until it comes back: the built-in
    /// camera, or the iPhone macOS is offering right now.
    func testAMissingPickFallsBackToTheAutomaticRule() {
        XCTAssertEqual(choose(pick: "usb", available: [builtIn, iphone]), "facetime")
        XCTAssertEqual(
            choose(pick: "usb", available: [builtIn, iphone], systemPreferred: "iphone"),
            "iphone")
    }

    // MARK: isAutomatic

    func testIsAutomaticMeansNoPickOrAPickThatIsGone() {
        XCTAssertTrue(CameraSelectionPolicy.isAutomatic(pick: nil, available: [builtIn]))
        XCTAssertTrue(CameraSelectionPolicy.isAutomatic(pick: "usb", available: [builtIn]))
        XCTAssertFalse(
            CameraSelectionPolicy.isAutomatic(pick: "facetime", available: [builtIn]))
    }
}
