import XCTest

@testable import Vimotion

final class GeometryMapperTests: XCTestCase {
    private let retinaMainHeight: CGFloat = 900      // logical points, 2× backing
    private let externalHeight: CGFloat = 1080       // 1× display right of main

    private func assertConverted(
        _ cua: CGRect,
        expectedAppKit: CGRect,
        mainDisplayHeight: CGFloat,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let result = GeometryMapper.appKitRect(fromCua: cua, mainDisplayHeight: mainDisplayHeight)
        XCTAssertEqual(result, expectedAppKit, file: file, line: line)
    }

    // MARK: Fixture matrix from plan §3.22

    /// Primary Retina display (2× backing): logical points pass through unscaled.
    func testPrimaryRetinaDisplay() {
        // Cua top-left (120, 200, 300, 50) on a 900pt-tall main display.
        assertConverted(
            CGRect(x: 120, y: 200, width: 300, height: 50),
            expectedAppKit: CGRect(x: 120, y: 900 - 250, width: 300, height: 50),
            mainDisplayHeight: retinaMainHeight
        )
    }

    /// External 1× display to the right of the primary.
    func testExternalOneTimesDisplayRight() {
        // Display frame starts at AppKit x=1440; element at its left edge.
        assertConverted(
            CGRect(x: 1450, y: 40, width: 220, height: 30),
            expectedAppKit: CGRect(x: 1450, y: 900 - 70, width: 220, height: 30),
            mainDisplayHeight: retinaMainHeight
        )
    }

    /// Display positioned to the LEFT: negative X coordinates.
    func testDisplayLeftWithNegativeX() {
        assertConverted(
            CGRect(x: -1900, y: 100, width: 400, height: 60),
            expectedAppKit: CGRect(x: -1900, y: 740, width: 400, height: 60),
            mainDisplayHeight: retinaMainHeight
        )
    }

    /// Display ABOVE the primary: negative Y in top-left space maps above the
    /// main display's top in bottom-left space.
    func testDisplayAbove() {
        // Secondary 500pt tall sits entirely above the main display:
        // cua y ∈ [-500, 0].
        let rect = CGRect(x: 200, y: -460, width: 150, height: 30)
        assertConverted(
            rect,
            expectedAppKit: CGRect(x: 200, y: 900 - (-430), width: 150, height: 30),
            mainDisplayHeight: retinaMainHeight
        )
    }

    /// Display BELOW the primary: cua y > main height.
    func testDisplayBelow() {
        let rect = CGRect(x: 100, y: 950, width: 180, height: 40)
        assertConverted(
            rect,
            expectedAppKit: CGRect(x: 100, y: -(90), width: 180, height: 40),
            mainDisplayHeight: retinaMainHeight
        )
    }

    /// Target spanning two displays side by side — geometry is global and
    /// unaffected by display boundaries.
    func testRectSpanningTwoDisplays() {
        let rect = CGRect(x: 1400, y: 300, width: 200, height: 80) // crosses x=1440 boundary
        assertConverted(
            rect,
            expectedAppKit: CGRect(x: 1400, y: 520, width: 200, height: 80),
            mainDisplayHeight: retinaMainHeight
        )
    }

    /// Mixed backing scales (2× next to 1×): conversion is identical because no
    /// scaling ever happens.
    func testMixedBackingScales() {
        let onRetina = GeometryMapper.appKitRect(
            fromCua: CGRect(x: 10, y: 20, width: 30, height: 40),
            mainDisplayHeight: retinaMainHeight
        )
        let onExternal = GeometryMapper.appKitRect(
            fromCua: CGRect(x: 10, y: 20, width: 30, height: 40),
            mainDisplayHeight: externalHeight
        )
        XCTAssertEqual(onRetina.width, 30)
        XCTAssertEqual(onRetina.height, 40)
        XCTAssertEqual(onRetina.origin.x, 10)
        XCTAssertEqual(onRetina.origin.y, 840)
        // Same input against a different main height flips only via that height.
        XCTAssertEqual(onExternal.width, onRetina.width)
        XCTAssertEqual(onExternal.height, onRetina.height)
        XCTAssertEqual(onExternal.origin.x, onRetina.origin.x)
        XCTAssertEqual(onExternal.origin.y, 1020)
    }

    /// Full-window conversion sanity: a window covering the whole main display
    /// lands exactly on the AppKit global frame of that display.
    func testFullMainWindow() {
        assertConverted(
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            expectedAppKit: CGRect(x: 0, y: 0, width: 1440, height: 900),
            mainDisplayHeight: retinaMainHeight
        )
    }
}
