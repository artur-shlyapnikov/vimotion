// CuaLifecycleStubTests.swift — lifecycle regression coverage for CuaMCPProcess
// against a stub `cua-driver` speaking newline-delimited JSON-RPC over stdio
// (wire shape verified against swift-sdk 0.12.1: Base/Messages.swift Request/
// Response encoding, StdioTransport newline framing).
//
// The tests redirect the PATH-based branch of locateDriverBinary() at a temp
// directory containing the stub. They are inert on machines where the
// PREFERRED location (~/.local/bin/cua-driver) exists — that path always wins
// over PATH and would launch a REAL driver.

import Darwin
#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif
import MCP
import XCTest

@testable import Vimotion

final class CuaLifecycleStubTests: XCTestCase {
    // MARK: - Fixtures

    /// Mirrors the known-good health payload from CuaResponseDecoderTests
    /// (snake_case wire keys, schema_version "1").
    private static let cannedHealth = CuaHealth(
        schemaVersion: "1",
        binaryVersion: "0.4.2",
        platformSupported: true,
        sessionActive: false,
        bundleIdentity: "local.cua.CuaDriver",
        tccAccessibility: true,
        axCapability: true
    )

    // MARK: - Environment guards & plumbing

    private static func preferredDriverPresent() -> Bool {
        let preferred = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/cua-driver")
        return FileManager.default.isExecutableFile(atPath: preferred.path)
    }

    private func skipIfPreferredDriverInstalled() throws {
        guard !Self.preferredDriverPresent() else {
            throw XCTSkip(
                "~/.local/bin/cua-driver exists; locateDriverBinary prefers it over PATH "
                    + "and these stub tests would launch the real binary")
        }
    }

    private static func setEnv(_ key: String, _ value: String) {
        key.withCString { keyPtr in
            value.withCString { _ = setenv(keyPtr, $0, 1) }
        }
    }

    private static func unsetEnv(_ key: String) {
        key.withCString { _ = unsetenv($0) }
    }

    /// Points the process PATH at `dir` (children inherit at spawn time).
    /// An empty dir makes binary lookup fail before any spawn — the
    /// `.driverNotInstalled` path.
    private static func setPATH(_ value: String) {
        setEnv("PATH", value)
    }

    /// Installs the stub `cua-driver` in `dir`. The script is a CONSTANT raw
    /// literal (no Swift interpolation ⇒ no escape-rendering surprises);
    /// behavior is parameterized through STUB_PIDFILE / STUB_INIT_DELAY which
    /// tests must setEnv() BEFORE start() and unsetEnv() in a defer — the child
    /// inherits them at spawn time.
    @discardableResult
    private static func installStub(in dir: URL) throws -> URL {
        let script = #"""
        #!/bin/bash
        # Test-only cua-driver stub: minimal MCP stdio server (newline-delimited JSON-RPC).
        [ -n "$STUB_PIDFILE" ] && echo $$ > "$STUB_PIDFILE"
        [ -n "$STUB_INIT_DELAY" ] && /bin/sleep "$STUB_INIT_DELAY"
        cleanup() { [ -n "$STUB_PIDFILE" ] && /bin/rm -f "$STUB_PIDFILE"; exit 0; }
        trap cleanup TERM INT HUP
        HEALTH='{"schema_version":"1","binary_version":"0.4.2","platform_supported":true,"session_active":false,"bundle_identity":"local.cua.CuaDriver","tcc_accessibility":true,"ax_capability":true}'
        TEXT=${HEALTH//\"/\\\"}
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          idpart=$(/usr/bin/grep -o '"id":[^,}]*' <<< "$line" | /usr/bin/head -1)
          [ -z "$idpart" ] && continue   # notification (no id): ignore
          id=${idpart#'"id":'}
          m=$(/usr/bin/grep -o '"method":"[^"]*"' <<< "$line" | /usr/bin/head -1)
          method=${m#'"method":"'}; method=${method%'"'}
          # JSONEncoder escapes "/" as "\/" — normalize before dispatch.
          method=${method//'\/'/'/'}
          case "$method" in
            initialize)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"stub-cua-driver","version":"0.4.2-test"}}}\n' "$id" ;;
            tools/list)
              if [ "$STUB_TRANSPORT_ONLY" = "1" ]; then
                printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"transport-only stub rejects tool discovery"}}\n' "$id"
              else
                printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"health_report","inputSchema":{"type":"object"}},{"name":"list_windows","inputSchema":{"type":"object"}},{"name":"get_window_state","inputSchema":{"type":"object"}},{"name":"click","inputSchema":{"type":"object"}}]}}\n' "$id"
              fi ;;
            tools/call)
              if [ "$STUB_TRANSPORT_ONLY" = "1" ]; then
                printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"ok\\":true}"}],"isError":false}}\n' "$id"
              else
                printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"%s"}],"isError":false}}\n' "$id" "$TEXT"
              fi ;;
            *)
              printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"stub: not implemented"}}\n' "$id" ;;
          esac
        done
        cleanup
        """#
        let stubURL = dir.appendingPathComponent("cua-driver")
        try script.write(to: stubURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubURL.path)
        return stubURL
    }

    private static func makeTempDir(label: String) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VimotionCuaLifecycle-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func removeTempDir(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Bounded-deadline polling; never a fixed sleep for readiness.
    private func pollUntil(
        timeout: Duration, interval: Duration = .milliseconds(10),
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: interval)
        }
        XCTFail("condition not met within \(timeout)")
    }
    /// True iff the PID recorded in the pidfile is gone (file removed by the
    /// stub's exit trap — deterministic regardless of zombie reaping).
    private func stubProcessGone(pidfile: URL) -> Bool {
        !FileManager.default.fileExists(atPath: pidfile.path)
    }

    // MARK: - 1. Failed start then recovery

    func testFailedStartThenStartRecovers() async throws {
        try skipIfPreferredDriverInstalled()
        let dir = try Self.makeTempDir(label: "recover")
        defer { Self.removeTempDir(dir) }
        let originalPATH = ProcessInfo.processInfo.environment["PATH"]
        defer { if let originalPATH { Self.setPATH(originalPATH) } }

        // Phase A: empty PATH entry — lookup must fail before any spawn.
        Self.setPATH(dir.path)
        do {
            let process = CuaMCPProcess()
            try await process.start()
            await process.stop()
            XCTFail("start() must throw .driverNotInstalled with no binary on PATH")
        } catch let error as CuaError {
            guard case .driverNotInstalled = error else {
                XCTFail("expected .driverNotInstalled, got \(error)")
                return
            }
        }

        // Phase B: install the working stub; recovery start must fully succeed.
        try Self.installStub(in: dir)
        Self.setPATH(dir.path)
        let process = CuaMCPProcess()
        let client = CuaDriverClient(process: process)
        let health = try await client.connect()
        XCTAssertEqual(health, Self.cannedHealth)

        await client.shutdown()
        let finalState = await process.state
        guard case .stopped = finalState else {
            XCTFail("expected .stopped after recovery stop(), got \(finalState)")
            return
        }
    }

    // MARK: - 2. Stop then start restarts the driver

    func testStopThenStartRestartsDriver() async throws {
        try skipIfPreferredDriverInstalled()
        let dir = try Self.makeTempDir(label: "restart")
        defer { Self.removeTempDir(dir) }
        try Self.installStub(in: dir)
        let originalPATH = ProcessInfo.processInfo.environment["PATH"]
        defer { if let originalPATH { Self.setPATH(originalPATH) } }
        Self.setPATH(dir.path)

        let process = CuaMCPProcess()
        let client = CuaDriverClient(process: process)
        let firstHealth = try await client.connect()
        XCTAssertEqual(firstHealth, Self.cannedHealth)

        await process.stop()
        let stoppedState = await process.state
        guard case .stopped = stoppedState else {
            XCTFail("expected .stopped after stop(), got \(stoppedState)")
            return
        }

        // Second start must re-enter runStart from .stopped (not bail on stale
        // expectingStop) and produce a live connection again.
        let secondHealth = try await client.connect()
        XCTAssertEqual(secondHealth, Self.cannedHealth)

        await client.shutdown()
    }

    // MARK: - 4. Transport boundary does not perform CUA handshake

    func testTransportStartsAndInvokesGenericToolWithoutCUAProtocol() async throws {
        try skipIfPreferredDriverInstalled()
        let dir = try Self.makeTempDir(label: "transport-only")
        defer { Self.removeTempDir(dir) }
        try Self.installStub(in: dir)

        let originalPATH = ProcessInfo.processInfo.environment["PATH"]
        defer { if let originalPATH { Self.setPATH(originalPATH) } }
        Self.setPATH(dir.path)
        Self.setEnv("STUB_TRANSPORT_ONLY", "1")
        defer { Self.unsetEnv("STUB_TRANSPORT_ONLY") }

        let process = CuaMCPProcess()
        do {
            try await process.start()
            let result = try await process.callTool(
                name: "echo",
                arguments: ["value": MCP.Value.string("transport")]
            )
            XCTAssertFalse(result.isError ?? true)
            XCTAssertEqual(result.content.count, 1)
        } catch {
            await process.stop()
            throw error
        }
        await process.stop()
    }

    // MARK: - 3. Stop during an in-flight start leaves no orphan

    func testStopDuringStartDoesNotOrphan() async throws {
        try skipIfPreferredDriverInstalled()
        let dir = try Self.makeTempDir(label: "orphan")
        defer { Self.removeTempDir(dir) }
        let pidfile = dir.appendingPathComponent("stub.pid")
        try Self.installStub(in: dir)
        // Env vars are inherited by the child at spawn time (not consumed by
        // installStub), so they must stay set until the test ends.
        Self.setEnv("STUB_PIDFILE", pidfile.path)
        Self.setEnv("STUB_INIT_DELAY", "0.35")
        defer {
            Self.unsetEnv("STUB_PIDFILE")
            Self.unsetEnv("STUB_INIT_DELAY")
        }
        let originalPATH = ProcessInfo.processInfo.environment["PATH"]
        defer { if let originalPATH { Self.setPATH(originalPATH) } }
        Self.setPATH(dir.path)

        let process = CuaMCPProcess()
        let startAttempt = Task { try await process.start() }

        // Wait until the subprocess actually spawned (deterministic signal:
        // the stub publishes its PID), then give the handshake a beat so stop()
        // lands while start() is still suspended inside the stub's delay.
        try await pollUntil(timeout: .seconds(5)) { [pidfile] in
            FileManager.default.fileExists(atPath: pidfile.path)
        }
        try await Task.sleep(for: .milliseconds(80))

        await process.stop()

        do {
            _ = try await startAttempt.value
            XCTFail("start() interrupted by stop() must not report success")
        } catch {
            // Any error is acceptable: cancellation surfacing through the
            // transport, or the runStart bail-out as transportDisconnected.
        }

        // The stub removes its pidfile on SIGTERM (trap) — bounded wait proves
        // the spawned process actually exited instead of orphaning.
        try await pollUntil(timeout: .seconds(5)) { [pidfile] in
            self.stubProcessGone(pidfile: pidfile)
        }

        let finalState = await process.state
        guard case .stopped = finalState else {
            XCTFail("expected .stopped after stop-during-start, got \(finalState)")
            return
        }
    }
}
