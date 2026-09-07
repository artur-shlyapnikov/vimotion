// PendingCallBoardTests.swift — regression tests for the cancellation-aware
// pending-call registry backing CuaMCPProcess.performCall.
//
// Review finding: performCall parked in a plain checked continuation whose
// inner transport task ignored cancellation, so the controller's 1500 ms scan
// hard-timeout could not bound a hung driver. These tests pin the contract:
// cancelling the awaiting task surfaces CancellationError promptly, a late
// worker completion never double-resumes, and teardown can fail all calls.

import XCTest

@testable import Vimotion

final class PendingCallBoardTests: XCTestCase {

    /// Cancelling the task awaiting a stalled fake transport must surface
    /// CancellationError promptly instead of hanging on the continuation.
    func testCancelSurfacesCancellationErrorPromptly() async {
        let board = PendingCallBoard<String>()
        let clock = ContinuousClock()

        let stalled = Task {
            try await board.run(id: UUID()) {
                // Stalled fake transport: never completes unless cancelled.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                throw CancellationError()
            }
        }

        // Let registration land before cancelling.
        try? await Task.sleep(for: .milliseconds(50))
        stalled.cancel()

        let started = clock.now
        do {
            _ = try await stalled.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(
            clock.now - started,
            .seconds(1),
            "cancellation must surface promptly, not wait on the stalled transport"
        )
    }

    /// A worker completing after its call was already cancelled must be a
    /// no-op — resume-once semantics (a double resume would trip the
    /// CheckedContinuation runtime traps).
    func testLateWorkerCompletionAfterCancelIsNoOp() async throws {
        let board = PendingCallBoard<String>()

        let task = Task {
            try await board.run(id: UUID()) {
                try? await Task.sleep(for: .milliseconds(150))
                return "late result"
            }
        }

        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        // Give the late completion time to run its (no-op) finish path.
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// Teardown path: failAll(with:) must fail every registered call with the
    /// given error, mirroring process-death fan-out.
    func testFailAllFailsEveryRegisteredCall() async {
        let board = PendingCallBoard<String>()
        let error = CuaError.transportDisconnected

        let tasks = (0..<3).map { _ in
            Task {
                try await board.run(id: UUID()) {
                    try? await Task.sleep(for: .seconds(5))
                    return "never"
                }
            }
        }

        try? await Task.sleep(for: .milliseconds(50))
        board.failAll(with: error)

        for task in tasks {
            do {
                _ = try await task.value
                XCTFail("expected \(error)")
            } catch let e as CuaError {
                XCTAssertEqual(e, error)
            } catch {
                XCTFail("expected \(error), got \(error)")
            }
        }
    }
}
