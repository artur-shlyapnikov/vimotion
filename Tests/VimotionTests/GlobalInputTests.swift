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

        input.withDecisionEngine { gate in
            XCTAssertEqual(gate.activationChord, chord)
            XCTAssertEqual(
                gate.configuredHintKeyCodes,
                Set([PhysicalKey.s, .d, .f, .j].map(\.cgKeyCode))
            )
        }
    }

    func testHintCaptureLifecycleControlsTheOwnedEngine() {
        let input = GlobalInput { _ in }

        input.beginHintCapture()
        input.withDecisionEngine { gate in
            XCTAssertEqual(gate.mode, .hintCapture)
        }

        input.endHintCapture()
        input.withDecisionEngine { gate in
            XCTAssertEqual(gate.mode, .activationOnly)
        }
    }
}
