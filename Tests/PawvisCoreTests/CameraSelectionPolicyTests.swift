import XCTest
@testable import PawvisCore

final class CameraSelectionPolicyTests: XCTestCase {
    private typealias Candidate = CameraSelectionPolicy.Candidate

    private let builtIn = Candidate(id: "facetime", kind: .builtIn)
    private let iphone = Candidate(id: "iphone", kind: .continuity)
    private let webcam = Candidate(id: "usb", kind: .other)

    private func choose(pick: String? = nil, available: [Candidate]) -> String? {
        CameraSelectionPolicy.choose(pick: pick, available: available)
    }

    // MARK: Automatic

    func testAutomaticIsTheBuiltInCameraWhateverTheDiscoveryOrder() {
        XCTAssertEqual(choose(available: [webcam, iphone, builtIn]), "facetime")
        XCTAssertEqual(choose(available: [builtIn, webcam]), "facetime")
    }

    /// The decision this file exists for: an iPhone macOS offers is a picker
    /// entry, never a camera Pawvis switched to on its own.
    func testAutomaticNeverTakesAnIPhoneUnasked() {
        XCTAssertEqual(choose(available: [iphone, builtIn]), "facetime")
        XCTAssertEqual(choose(available: [builtIn, iphone]), "facetime")
    }

    func testAutomaticNeverTakesAWebcamUnasked() {
        XCTAssertEqual(choose(available: [webcam, builtIn]), "facetime")
    }

    /// A Mac mini: no built-in camera, so the first camera at all.
    func testNoBuiltInCameraMeansTheFirstCameraAtAll() {
        XCTAssertEqual(choose(available: [iphone, webcam]), "iphone")
        XCTAssertEqual(choose(available: [webcam, iphone]), "usb")
    }

    func testNoCameraAtAllMeansNil() {
        XCTAssertNil(choose(available: []))
        XCTAssertNil(choose(pick: "facetime", available: []))
    }

    // MARK: Explicit picks

    func testAPresentPickWins() {
        XCTAssertEqual(choose(pick: "iphone", available: [builtIn, iphone, webcam]), "iphone")
        XCTAssertEqual(choose(pick: "usb", available: [builtIn, iphone, webcam]), "usb")
        XCTAssertEqual(choose(pick: "facetime", available: [builtIn, iphone]), "facetime")
    }

    /// An unplugged pick is Automatic until it comes back: the built-in
    /// camera, not the next external thing in the list.
    func testAMissingPickFallsBackToTheBuiltInCamera() {
        XCTAssertEqual(choose(pick: "usb", available: [iphone, builtIn]), "facetime")
    }

    func testAMissingPickOnAMacWithoutABuiltInCameraTakesTheFirstCamera() {
        XCTAssertEqual(choose(pick: "usb", available: [iphone]), "iphone")
    }

    // MARK: isAutomatic

    func testIsAutomaticMeansNoPickOrAPickThatIsGone() {
        XCTAssertTrue(CameraSelectionPolicy.isAutomatic(pick: nil, available: [builtIn]))
        XCTAssertTrue(CameraSelectionPolicy.isAutomatic(pick: "usb", available: [builtIn]))
        XCTAssertFalse(CameraSelectionPolicy.isAutomatic(pick: "facetime", available: [builtIn]))
    }
}
