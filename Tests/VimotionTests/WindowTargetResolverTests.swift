import XCTest

@testable import Vimotion

final class WindowTargetResolverTests: XCTestCase {

    private let ownPID: pid_t = 9999

    private func makeWindow(
        id: UInt32,
        pid: pid_t = 4711,
        z: Int?,
        bounds: CuaRect = CuaRect(x: 0, y: 0, width: 1200, height: 800),
        isOnScreen: Bool = true,
        onCurrentSpace: Bool = true
    ) -> CuaWindow {
        CuaWindow(
            windowID: id,
            pid: pid,
            appName: nil,
            title: nil,
            bounds: bounds,
            zIndex: z,
            isOnScreen: isOnScreen,
            onCurrentSpace: onCurrentSpace
        )
    }

    private func makeResolver(
        windows: [CuaWindow] = [],
        error: CuaError? = nil,
        quartz: [(windowNumber: UInt32, pid: pid_t)] = []
    ) -> WindowTargetResolver {
        WindowTargetResolver(
            providers: WindowTargetingProviders(
                listWindows: { _ in
                    if let error { throw error }
                    return windows
                },
                quartzLayer0FrontToBack: { quartz }
            ),
            ownPID: ownPID
        )
    }

    // MARK: Primary max zIndex

    func testMaxZIndexWins() async throws {
        let resolver = makeResolver(windows: [
            makeWindow(id: 1, z: 5),
            makeWindow(id: 2, z: 9),
            makeWindow(id: 3, z: 2),
        ])
        let front = try await resolver.resolveFrontmost()
        XCTAssertEqual(front.windowID, 2)
    }

    func testNilZIndexIgnoredWhenOthersHaveZIndex() async throws {
        // A Quartz-front window without zIndex must NOT beat z-ordered ones.
        let resolver = makeResolver(
            windows: [
                makeWindow(id: 10, z: nil),
                makeWindow(id: 11, z: 3),
            ],
            quartz: [(windowNumber: 10, pid: 4711)]
        )
        let front = try await resolver.resolveFrontmost()
        XCTAssertEqual(front.windowID, 11)
    }

    // MARK: Filtering

    func testOwnPIDAndInvalidBoundsFiltered() async throws {
        let resolver = makeResolver(windows: [
            makeWindow(id: 20, pid: ownPID, z: 100),                                  // own PID
            makeWindow(id: 21, z: 90, bounds: CuaRect(x: 0, y: 0, width: 0, height: 500)),   // zero width
            makeWindow(id: 22, z: 80, bounds: CuaRect(x: 0, y: 0, width: 500, height: -4)),  // negative height
            makeWindow(id: 23, z: 70, isOnScreen: false),
            makeWindow(id: 24, z: 60, onCurrentSpace: false),
            makeWindow(id: 25, z: 1),
        ])
        let front = try await resolver.resolveFrontmost()
        XCTAssertEqual(front.windowID, 25)
    }

    func testEverythingFilteredThrowsWindowNotFound() async {
        let resolver = makeResolver(windows: [
            makeWindow(id: 30, pid: ownPID, z: 5),
        ])
        do {
            _ = try await resolver.resolveFrontmost()
            XCTFail("expected windowNotFound")
        } catch {
            XCTAssertEqual(error as? CuaError, .windowNotFound)
        }
    }

    func testEmptyListThrowsWindowNotFound() async {
        let resolver = makeResolver()
        do {
            _ = try await resolver.resolveFrontmost()
            XCTFail("expected windowNotFound")
        } catch {
            XCTAssertEqual(error as? CuaError, .windowNotFound)
        }
    }

    // MARK: Quartz layer-0 fallback (all remaining zIndex nil)

    func testQuartzFallbackPicksFirstIntersection() async throws {
        // Quartz order front-to-back: 77 (not a candidate), then 55, then 88.
        let resolver = makeResolver(
            windows: [
                makeWindow(id: 55, z: nil),
                makeWindow(id: 88, z: nil),
            ],
            quartz: [
                (windowNumber: 77, pid: 4712),
                (windowNumber: 55, pid: 4711),
                (windowNumber: 88, pid: 4711),
            ]
        )
        let front = try await resolver.resolveFrontmost()
        XCTAssertEqual(front.windowID, 55)
        XCTAssertEqual(front.pid, 4711)
    }

    func testQuartzFallbackSkipsNonCandidatesUntilMatch() async throws {
        let resolver = makeResolver(
            windows: [makeWindow(id: 42, z: nil)],
            quartz: [
                (windowNumber: 1, pid: 100),
                (windowNumber: 2, pid: 101),
                (windowNumber: 42, pid: 4711),
            ]
        )
        let front = try await resolver.resolveFrontmost()
        XCTAssertEqual(front.windowID, 42)
    }

    func testQuartzFallbackNoIntersectionFailsClosed() async {
        let resolver = makeResolver(
            windows: [makeWindow(id: 55, z: nil)],
            quartz: [(windowNumber: 777, pid: 1234)]
        )
        do {
            _ = try await resolver.resolveFrontmost()
            XCTFail("expected windowNotFound")
        } catch {
            XCTAssertEqual(error as? CuaError, .windowNotFound)
        }
    }
}
