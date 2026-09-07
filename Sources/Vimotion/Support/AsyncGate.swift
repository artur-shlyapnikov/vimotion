/// Capacity-1 async gate: serializes access to a critical section across
/// concurrency domains. Waiters are cancellation-aware — a cancelled waiter
/// leaves the queue and never stalls tasks behind it. FIFO ordering is not
/// guaranteed.
actor AsyncGate {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private var isOccupied = false
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0

    func with<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        // A cancel that raced the handoff still owns the slot at this
        // point: refuse to run the body so a live waiter isn't starved by
        // wasted work. release() in the defer hands the slot onward.
        try Task.checkCancellation()
        defer { release() }
        return try await body()
    }

    private func acquire() async throws {
        if !isOccupied {
            isOccupied = true
            return
        }
        let id = nextWaiterID
        nextWaiterID &+= 1
        // Resuming normally means ownership of the slot has been handed off
        // by `release()`; throwing CancellationError means this waiter was
        // dequeued by its own cancellation handler.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Hands the slot directly to the next queued waiter when one exists;
    /// otherwise marks the gate free.
    private func release() {
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: ())
            return
        }
        isOccupied = false
    }
}
