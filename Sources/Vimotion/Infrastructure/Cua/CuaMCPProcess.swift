// CuaMCPProcess.swift — long-lived `cua-driver mcp` subprocess over the MCP stdio transport.
//
// Ground truth verified against the pinned checkout (.build/checkouts/swift-sdk @ 0.12.1):
//   • Sources/MCP/Base/Transports/StdioTransport.swift:66-70 — descriptor-based initializer
//     `StdioTransport(input: FileDescriptor, output: FileDescriptor, logger: Logger?)` EXISTS
//     in 0.12.1; we feed it the raw fds of the Foundation.Process pipes.
//   • Sources/MCP/Client/Client.swift:207 — `connect(transport:) async throws -> Initialize.Result`;
//     Client.swift:282-284 shows connect() performs the initialize/handshake internally
//     (`return try await _initialize()`), so no manual initialize exchange is needed here.
//   • Sources/MCP/Client/Client.swift:743-755 — `listTools(cursor:) -> (tools: [Tool], nextCursor: String?)`;
//     Tool.name is `public let name: String` (Sources/MCP/Server/Tools.swift:13).
//   • Sources/MCP/Client/Client.swift:392-398 — `send(_: Request<M>) throws -> RequestContext<M.Result>`;
//     used directly so we get the FULL CallTool.Result including structuredContent
//     (the convenience callTool overload at Client.swift:768 drops structuredContent).
//   • Sources/MCP/Base/Error.swift:29-59 — transport failures surface as MCPError
//     (.connectionClosed/.transportError/.internalError, …); normalized to CuaError below.

import Foundation
import MCP
import os
#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

/// Owns the driver subprocess and exposes the MCP transport boundary.
///
/// CUA tool names, arguments, validation, and response decoding deliberately
/// live in `CuaDriverClient`. This actor only knows how to establish and tear
/// down the MCP connection and forward generic tool requests safely.
actor CuaMCPProcess {
    enum ConnectionState: Sendable { case stopped, starting, ready, failed(CuaError) }

    private(set) var state: ConnectionState = .stopped

    private var process: Foundation.Process?
    private var client: MCP.Client?
    private var transport: StdioTransport?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    /// Last ~8 KiB of driver stderr; contents are NEVER logged (may contain window titles).
    private let stderrRing = StderrRing()

    private var startTask: Task<Void, Error>?
    private let calls = PendingCallBoard<MCP.CallTool.Result>()
    private let toolListingCalls = PendingCallBoard<Set<String>>()
    private var stopLatch: ExitLatch?
    private var expectingStop = false

    // MARK: - Lifecycle

    /// Idempotent: `.ready` returns immediately; `.starting` awaits the in-flight attempt.
    func start() async throws {
        switch state {
        case .ready:
            return
        case .starting:
            guard let running = startTask else { return }
            return try await running.value
        case .stopped, .failed:
            break
        }
        // Claim the transition synchronously, before any suspension: a
        // concurrent start() observes `.starting` and awaits this exact
        // attempt instead of spawning a duplicate subprocess. Co-waiters get
        // the same result/error rethrown.
        // A fresh lifecycle claim un-poisons the flag latched by a previous
        // attempt's cleanup or a completed stop(); a concurrent stop() re-sets
        // it before awaiting the attempt, preserving the race guard.
        expectingStop = false
        state = .starting
        let attempt = Task { try await self.runStart() }
        startTask = attempt
        defer { startTask = nil }
        try await attempt.value
    }

    func stop() async {
        // Fix #1: stop happens-after any in-flight start attempt. Without this,
        // stop could complete entirely between state=.starting and the spawn of
        // runStart's subprocess, leaving an orphaned driver running after quit.
        expectingStop = true
        startTask?.cancel()
        if let attempt = startTask {
            _ = try? await attempt.value
        }
        startTask = nil
        calls.failAll(with: CuaError.transportDisconnected)
        toolListingCalls.failAll(with: CuaError.transportDisconnected)
        await teardownClient()

        guard let proc = process else {
            state = .stopped
            return
        }
        // Fix #2: reuse an already-installed latch so we never orphan a waiter
        // on a replaced latch object (which would hang stop() forever).
        let latch = stopLatch ?? ExitLatch()
        stopLatch = latch

        if proc.isRunning {
            proc.terminate()
        } else {
            latch.fire()
        }
        // Fix #7: fast paths skip processDidExit, so drop the readability
        // handler here too — only for the exact process we are tearing down.
        if process === proc {
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
        }
        // Fix #6: SIGTERM alone can hang forever on a wedged driver. Race the
        if await !latch.wait(for: .seconds(2)) {
            Self.sendSIGKILL(proc)
            _ = await latch.wait(for: .seconds(2))
        }

        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
        stopLatch = nil
        state = .stopped
    }

    // MARK: - Tool calls

    func callTool(name: String, arguments: [String: MCP.Value]) async throws -> MCP.CallTool.Result {
        guard case .ready = state, client != nil else {
            throw CuaError.transportDisconnected
        }
        return try await performCall(name: name, arguments: arguments)
    }

    /// True iff the transport previously failed.
    ///
    /// Reconnect policy belongs to the typed client above this boundary; this
    /// query only exposes the transport lifecycle state needed to gate it.
    func isTransportFailed() -> Bool {
        if case .failed = state { return true }
        return false
    }

    /// Returns the names advertised by the connected MCP server without
    /// assigning any application meaning to them.
    func availableToolNames() async throws -> Set<String> {
        guard case .ready = state, let client else {
            throw CuaError.transportDisconnected
        }
        do {
            return try await toolListingCalls.run(id: UUID()) { [client] in
                let (tools, _) = try await client.listTools()
                return Set(tools.map(\.name))
            }
        } catch let error as CancellationError {
            throw error
        } catch is MCPError {
            throw CuaError.transportDisconnected
        }
    }

    /// Runs one RPC with a registered, cancellation-aware continuation so both
    /// abrupt process death and task cancellation fail it promptly.
    private func performCall(name: String, arguments: [String: MCP.Value]) async throws
        -> MCP.CallTool.Result
    {
        guard let client else { throw CuaError.transportDisconnected }
        do {
            return try await calls.run(id: UUID()) { [client] in
                let request = MCP.CallTool.request(
                    MCP.CallTool.Parameters(name: name, arguments: arguments))
                let context = try await client.send(request)
                return try await context.value
            }
        } catch let error as CancellationError {
            throw error  // task cancellation must still surface verbatim
        } catch is MCPError {
            // Fix #3: SDK deaths (MCPError.transportError/internalError/
            // connectionClosed) must map onto the typed seam so downstream
            // reconnect logic fires; raw MCPError leaks otherwise.
            throw CuaError.transportDisconnected
        }
    }

    // MARK: - Startup sequence

    private func runStart() async throws {
        // Fix #1 (b): a stop that landed after start() claimed .starting but
        // before this body ran would otherwise respawn a fresh subprocess and
        // flip back to .ready after shutdown. Bail out instead.
        if expectingStop || Self.isTerminal(state) {
            state = .stopped
            throw CuaError.transportDisconnected
        }

        // Binary lookup happens strictly BEFORE spawning (plan §3.4).
        guard let binaryURL = Self.locateDriverBinary() else {
            state = .failed(.driverNotInstalled)
            throw CuaError.driverNotInstalled
        }
        stderrRing.reset()

        let proc = Foundation.Process()
        proc.executableURL = binaryURL
        // Only the bare `mcp` subcommand — never --direct/--permission-mode/--socket.
        proc.arguments = ["mcp"]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        stderrPipe = stderr
        stderr.fileHandleForReading.readabilityHandler = { [ring = stderrRing] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                ring.append(chunk)
            }
        }

        proc.terminationHandler = { [weak self, weak proc] _ in
            Task { await self?.processDidExit(from: proc) }
        }

        do {
            try proc.run()
        } catch {
            proc.terminationHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            state = .failed(.transportDisconnected)
            throw CuaError.transportDisconnected
        }
        process = proc
        stdinPipe = stdin
        stdoutPipe = stdout

        do {
            let transport = StdioTransport(
                input: FileDescriptor(rawValue: stdout.fileHandleForReading.fileDescriptor),
                output: FileDescriptor(rawValue: stdin.fileHandleForWriting.fileDescriptor)
            )
            self.transport = transport
            let client = MCP.Client(name: "vimotion", version: "1.0.0")
            self.client = client

            // connect() performs the MCP initialize handshake itself in SDK 0.12.1.
            _ = try await client.connect(transport: transport)

            if expectingStop { throw CuaError.transportDisconnected }
            state = .ready
        } catch {
            calls.failAll(with: CuaError.transportDisconnected)
            toolListingCalls.failAll(with: CuaError.transportDisconnected)
            await teardownClient()
            expectingStop = true  // our own cleanup exit must not overwrite the failure below
            await terminateProcess()
            // Cancellation is not a transport failure: keep the cleanup
            // above, but let callers see the cancellation so they don't
            // burn a useless reconnect on a cancelled task.
            if error is CancellationError {
                state = .failed(.transportDisconnected)
                throw CancellationError()
            }
            let normalized = normalize(error)
            state = .failed(normalized)
            throw normalized
        }
    }

    // MARK: - Exit handling

    /// Single terminationHandler entry point; distinguishes graceful stop from unexpected death.
    /// Fix #4: identifies WHICH process exited — a late notification from generation N
    /// must not tear down generation N+1's client/pipes mid-handshake.
    private func processDidExit(from exitedProc: Foundation.Process?) {
        guard let exitedProc, exitedProc === process else { return }
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stopLatch?.fire()

        if expectingStop { return }

        state = .failed(.transportDisconnected)
        calls.failAll(with: CuaError.transportDisconnected)
        toolListingCalls.failAll(with: CuaError.transportDisconnected)
        Task { await teardownClient() }
        // Diagnostics carry byte counts only — stderr content is never logged.
        AppLogger.cua.debug(
            "cua-driver terminated unexpectedly, stderr bytes captured: \(self.stderrRing.byteCount)"
        )
    }

    private func teardownClient() async {
        if let client {
            await client.disconnect()
        }
        client = nil
        transport = nil
    }

    private func terminateProcess() async {
        guard let proc = process else { return }
        // Fix #2: never overwrite an already-installed latch — its waiter would
        // hang forever because the exit only fires whichever latch is current.
        let latch = stopLatch ?? ExitLatch()
        stopLatch = latch
        if proc.isRunning {
            proc.terminate()
            if await !latch.wait(for: .seconds(2)) {
                Self.sendSIGKILL(proc)  // Fix #6: escalate past an uninterruptible wedge
                _ = await latch.wait(for: .seconds(2))
            }
        } else {
            latch.fire()
        }
        // Fix #7: fast path bypasses processDidExit — clear the handler for the
        // exact instance being dropped before releasing the pipes.
        if process === proc {
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
        }
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
        stopLatch = nil
    }

    /// True once the connection has definitively ended (fix #1 helper).
    private nonisolated static func isTerminal(_ state: ConnectionState) -> Bool {
        switch state {
        case .stopped, .failed: return true
        case .starting, .ready: return false
        }
    }

    /// SIGKILL escalation (fix #6). Foundation.Process exposes only terminate()
    /// (SIGTERM); go through kill(2) directly, guarding against a reaped pid.
    private nonisolated static func sendSIGKILL(_ proc: Foundation.Process) {
        let pid = proc.processIdentifier
        guard pid > 0 else { return }
        kill(pid, SIGKILL)
    }

    private func normalize(_ error: Error) -> CuaError {
        if let cuaError = error as? CuaError { return cuaError }
        return .transportDisconnected
    }

    // MARK: - Binary lookup

    /// `~/.local/bin/cua-driver` first, then a PATH environment scan. No filesystem crawl.
    nonisolated private static func locateDriverBinary() -> URL? {
        let fileManager = FileManager.default
        let preferred = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/cua-driver")
        if fileManager.isExecutableFile(atPath: preferred.path) { return preferred }
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent("cua-driver")
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

/// Coordinates resume-once completion of in-flight tool calls across racing
/// finalizers: the transport reply, process death (`failAll`), and cancellation
/// of the awaiting task. All completion paths funnel through `finish`, which
/// atomically removes the entry under one lock — whichever finalizer removes
/// first resumes the continuation exactly once; every other path becomes a
/// no-op. Cancelling the task awaiting `run(id:_:)` surfaces `CancellationError`
/// immediately, unregisters the entry, and cancels the stalled worker.
final class PendingCallBoard<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    private final class Entry {
        let continuation: CheckedContinuation<Value, Error>
        var worker: Task<Void, Never>?

        init(continuation: CheckedContinuation<Value, Error>) {
            self.continuation = continuation
        }
    }

    /// Registers `body` as the worker for this call and awaits its outcome.
    func run(id: UUID, _ body: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Value, Error>) in
                let entry = Entry(continuation: continuation)
                lock.lock()
                // The worker is created while holding the lock so its finish
                // can never race ahead of registration.
                entries[id] = entry
                entry.worker = Task { [weak self] in
                    guard let self else { return }
                    do {
                        self.finish(id, with: .success(try await body()))
                    } catch {
                        self.finish(id, with: .failure(error))
                    }
                }
                lock.unlock()
                // A cancel that fired before registration was a no-op above;
                // retire the just-registered entry now (finish is idempotent).
                if Task.isCancelled {
                    finish(id, with: .failure(CancellationError()), cancelWorker: true)
                }
            }
        }, onCancel: {
            finish(id, with: .failure(CancellationError()), cancelWorker: true)
        })
    }

    /// Fails and resumes every registered call (process teardown path).
    func failAll(with error: Error) {
        let drained: [Entry]
        lock.lock()
        drained = Array(entries.values)
        entries.removeAll()
        lock.unlock()
        for entry in drained {
            entry.worker?.cancel()
            entry.continuation.resume(throwing: error)
        }
    }

    private func finish(_ id: UUID, with outcome: sending Result<Value, Error>, cancelWorker: Bool = false) {
        lock.lock()
        let entry = entries.removeValue(forKey: id)
        lock.unlock()
        if let entry {
            if cancelWorker { entry.worker?.cancel() }
            entry.continuation.resume(with: outcome)
        }
    }
}


/// Thread-safe one-shot latch bridging the Process terminationHandler queue to `await`.
private final class ExitLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.lock.lock()
            if self.fired {
                self.lock.unlock()
                continuation.resume(returning: ())
            } else {
                self.continuation = continuation
                self.lock.unlock()
            }
        }
    }

    /// Timed wait (fix #6): polls the fired flag at coarse intervals so no
    /// continuation is stranded when the deadline expires. Returns true iff the
    /// latch fired within the budget. Cancellation-safe by design — sleeps
    /// tolerate cancellation and the loop exits on fire or timeout.
    func wait(for timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if self.isFired { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return self.isFired
    }

    /// Synchronous fired check so async polling never touches NSLock from an
    /// async context (lock()/unlock() are unavailable there).
    private var isFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }

    func fire() {
        lock.lock()
        fired = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: ())
    }
}

/// Bounded (last ~8 KiB) stderr sink shared with the readabilityHandler thread.
private final class StderrRing: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private(set) var totalBytes = 0
    private let capacity = 8 * 1024

    /// Lock-protected read for callers outside append/reset (e.g. logging from
    /// the actor while handler threads append).
    var byteCount: Int { lock.withLock { totalBytes } }

    func append(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        totalBytes += chunk.count
        if buffer.count > capacity {
            buffer = buffer.suffix(capacity)
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        buffer.removeAll(keepingCapacity: false)
        totalBytes = 0
        lock.unlock()
    }
}
