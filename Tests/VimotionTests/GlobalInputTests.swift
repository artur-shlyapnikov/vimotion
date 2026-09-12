import CoreGraphics
import XCTest
@testable import Vimotion

@MainActor
final class GlobalInputTests: XCTestCase {

    private let chord = ActivationChord(
        keyCode: VimotionKeys.spaceKeyCode,
        requiredFlags: [.maskCommand, .maskShift]
    )

    func testConfigureAppliesChordAndAlphabetToTheOwnedEngine() {
        let input = GlobalInput { _ in }

        input.configure(activationChord: chord, alphabet: [.s, .d, .f, .j])

        XCTAssertEqual(input.activationChord, chord)
        XCTAssertTrue(input.acceptsHintKey(.s))
        XCTAssertTrue(input.acceptsHintKey(.d))
        XCTAssertTrue(input.acceptsHintKey(.f))
        XCTAssertTrue(input.acceptsHintKey(.j))
        XCTAssertFalse(input.acceptsHintKey(.a))
    }

    func testHintCaptureLifecycleControlsTheOwnedEngine() {
        let input = GlobalInput { _ in }

        input.beginHintCapture()
        XCTAssertTrue(input.isCapturing)

        input.endHintCapture()
        XCTAssertFalse(input.isCapturing)
    }
}
