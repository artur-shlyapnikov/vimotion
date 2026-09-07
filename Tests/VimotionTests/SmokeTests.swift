import os
import XCTest

@testable import Vimotion

/// Deliberately unsynchronized: if the gate failed to serialize entrants,
/// increments would race and the final count would fall below the total.
private final class UnsynchronizedCounter: @unchecked Sendable {
    var value = 0
}

final class SmokeTests: XCTestCase {
    func testAsyncGateSerializesAccess() async throws {
        let gate = AsyncGate()
        let counter = UnsynchronizedCounter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    try await gate.with {
                        counter.value += 1
                        // Yield to give any (illegal) concurrent entrant a chance.
                        await Task.yield()
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(counter.value, 100)
    }

    func testAsyncGateReturnsBodyValue() async throws {
        let gate = AsyncGate()
        let result = try await gate.with { () -> Int in
            21 * 2
        }
        XCTAssertEqual(result, 42)
    }

    func testAsyncGateCancellationDoesNotBlockOthers() async throws {
        let gate = AsyncGate()

        // Occupy the gate for a while. The expectation resolves only once
        // the holder's body is RUNNING inside the gate, so the steps below
        // never depend on a fixed sleep racing task startup.
        let holderInsideGate = expectation(description: "holder body entered the gate")
        let holder = Task {
            try await gate.with {
                holderInsideGate.fulfill()
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        await fulfillment(of: [holderInsideGate], timeout: 2)

        // A cancelled waiter must fail with CancellationError, never enter.
        let cancelled = Task {
            try await gate.with { () -> Bool in
                true
            }
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("cancelled waiter must never enter the gate")
        } catch is CancellationError {
            // Expected path.
        }

        // A later waiter proceeds as soon as the holder releases.
        let lateWaiterStart = ContinuousClock.now
        let late = Task {
            try await gate.with { () -> Bool in
                true
            }
        }
        let lateResult = try await late.value
        try await holder.value
        let elapsed = ContinuousClock.now - lateWaiterStart
        XCTAssertTrue(lateResult)
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    func testSignposterIntervalNamesAreStable() {
        XCTAssertEqual(PerformanceMetrics.Intervals.activationToWindow, "activation_to_window")
        XCTAssertEqual(PerformanceMetrics.Intervals.windowToSnapshot, "window_to_snapshot")
        XCTAssertEqual(PerformanceMetrics.Intervals.snapshotToTargets, "snapshot_to_targets")
        XCTAssertEqual(PerformanceMetrics.Intervals.targetsToOverlay, "targets_to_overlay")
        XCTAssertEqual(PerformanceMetrics.Intervals.keyToClick, "key_to_click")
    }

    func testLoggerCategoriesConstruct() {
        // Crash-freedom smoke: every static category logger materializes.
        let loggers: [Logger] = [
            AppLogger.cua,
            AppLogger.hint,
            AppLogger.input,
            AppLogger.overlay,
            AppLogger.app,
        ]
        _ = loggers
    }
}
