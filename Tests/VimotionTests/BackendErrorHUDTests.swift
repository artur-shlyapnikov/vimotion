import XCTest

@testable import Vimotion

/// Table-driven pin of the single-source HUD copy owned by
/// `HintSessionBackendError.hudText`. Adding a new error case must update
/// this table, not a second switch in the controller.
final class BackendErrorHUDTests: XCTestCase {

    func testEachErrorCarriesItsFrozenHUDText() {
        XCTAssertEqual(HintSessionBackendError.driverUnavailable.hudText, "Cua Driver unavailable")
        XCTAssertEqual(HintSessionBackendError.accessibilityRequired.hudText, "Cua Accessibility required")
        XCTAssertEqual(HintSessionBackendError.scanTimedOut.hudText, "UI scan timed out")
        XCTAssertEqual(HintSessionBackendError.targetChanged.hudText, "Target changed")
        XCTAssertEqual(HintSessionBackendError.noActionableElements.hudText, "No actionable elements")
    }

    func testControllerForwardsTheSingleSource() {
        XCTAssertEqual(HintModeController.hudDriverUnavailable,
                       HintSessionBackendError.driverUnavailable.hudText)
        XCTAssertEqual(HintModeController.hudAccessibilityRequired,
                       HintSessionBackendError.accessibilityRequired.hudText)
        XCTAssertEqual(HintModeController.hudScanTimedOut,
                       HintSessionBackendError.scanTimedOut.hudText)
        XCTAssertEqual(HintModeController.hudNoActionableElements,
                       HintSessionBackendError.noActionableElements.hudText)
        XCTAssertEqual(HintModeController.hudTargetChanged,
                       HintSessionBackendError.targetChanged.hudText)
    }
}
