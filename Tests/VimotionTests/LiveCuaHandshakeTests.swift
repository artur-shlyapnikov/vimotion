// LiveCuaHandshakeTests.swift — opt-in integration check against the real cua-driver.
// Entirely inert unless VIMOTION_LIVE_CUA=1; this is the ONLY live test in the target.

import XCTest
@testable import Vimotion

final class LiveCuaHandshakeTests: XCTestCase {
    func testLiveHandshakeAgainstRealDriver() async throws {
        guard ProcessInfo.processInfo.environment["VIMOTION_LIVE_CUA"] == "1" else {
            throw XCTSkip("Set VIMOTION_LIVE_CUA=1 to exercise the real cua-driver binary")
        }

        let process = CuaMCPProcess()
        do {
            let client = CuaDriverClient(process: process)
            let health = try await client.connect()
            XCTAssertEqual(health.schemaVersion, "1")

            await client.shutdown()
            let finalState = await process.state
            guard case .stopped = finalState else {
                XCTFail("expected .stopped after stop(), got \(finalState)")
                return
            }
        } catch {
            await process.stop()
            throw error
        }
    }
}
