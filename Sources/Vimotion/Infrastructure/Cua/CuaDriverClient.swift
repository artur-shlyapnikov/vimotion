// CuaDriverClient.swift — typed facade over CuaMCPProcess.
// Implements the internal CuaDriverServing seam consumed by HintModeController.
// click sends delivery_mode:"background" + its per-launch session label
// (`vimotion-<8 random hex>`); snapshot sends the session label;
// health/listWindows send neither. get_window_state calls are serialized
// through one capacity-1 AsyncGate so overlapping snapshots can never
// supersede token maps out of order (plan §3.5). Exactly ONE reconnect
// attempt after a transport failure; no other retry loops exist anywhere
// in this file.

import Foundation
import MCP

actor CuaDriverClient: CuaDriverServing {
    /// Public per-launch session label; never persists.
    let sessionLabel: String

    private let process: CuaMCPProcess
    private let snapshotGate = AsyncGate()

    private static let requiredTools = [
        "health_report", "list_windows", "get_window_state", "click",
    ]

    private static let healthIncludeKeys = [
        "binary_version", "platform_supported", "session_active",
        "bundle_identity", "tcc_accessibility", "ax_capability",
    ]

    init(process: CuaMCPProcess = CuaMCPProcess()) {
        self.process = process
        self.sessionLabel = Self.makeSessionLabel()
    }

    // MARK: - CuaDriverServing

    func health() async throws -> CuaHealth {
        let result = try await perform(
            "health_report",
            ["include": MCP.Value.array(Self.healthIncludeKeys.map(MCP.Value.string))]
        )
        return try CuaResponseDecoder.health(from: result)
    }

    func listWindows(onScreenOnly: Bool) async throws -> [CuaWindow] {
        let result = try await perform(
            "list_windows",
            ["on_screen_only": MCP.Value.bool(onScreenOnly)]
        )
        return try CuaResponseDecoder.windows(from: result)
    }

    func snapshot(pid: pid_t, windowID: UInt32) async throws -> CuaWindowSnapshot {
        try await snapshotGate.with {
            let result = try await self.perform(
                "get_window_state",
                [
                    "pid": MCP.Value.int(Int(pid)),
                    "window_id": MCP.Value.int(Int(windowID)),
                    "include_screenshot": MCP.Value.bool(false),
                    "max_depth": MCP.Value.int(25),
                    "max_elements": MCP.Value.int(2500),
                    "session": MCP.Value.string(self.sessionLabel),
                ]
            )
            return try CuaResponseDecoder.snapshot(pid: pid, windowID: windowID, from: result)
        }
    }

    func click(pid: pid_t, elementToken: String) async throws {
        let result = try await perform(
            "click",
            [
                "pid": MCP.Value.int(Int(pid)),
                "element_token": MCP.Value.string(elementToken),
                "delivery_mode": MCP.Value.string("background"),
                "session": MCP.Value.string(self.sessionLabel),
            ]
        )
        try CuaResponseDecoder.clickAcknowledgement(from: result)
    }

    // MARK: - Lifecycle (assembly-owned additive seam)

    /// Establishes the MCP connection, validates the CUA protocol, and
    /// returns the decoded health report. The transport remains unaware of
    /// all three CUA-specific operations.
    func connect() async throws -> CuaHealth {
        try await process.start()
        do {
            try await validateRequiredTools()
            return try await requestHealth()
        } catch {
            // A connected but incompatible or malformed CUA endpoint is not
            // useful to callers. Keep the transport boundary reusable by
            // tearing down the failed CUA configuration here.
            await process.stop()
            throw error
        }
    }

    /// Teardown path for app termination: stops the driver subprocess.
    func shutdown() async {
        await process.stop()
    }

    // MARK: - Single reconnect attempt

    private func perform(_ name: String, _ arguments: [String: MCP.Value]) async throws
        -> MCP.CallTool.Result
    {
        do {
            return try await process.callTool(name: name, arguments: arguments)
        } catch let error as CuaError where error == .transportDisconnected {
            guard await process.isTransportFailed() else { throw error }
            // Single reconnect attempt: a failed re-configuration throws its
            // own error, which is more informative than the stale disconnect.
            _ = try await connect()
            return try await process.callTool(name: name, arguments: arguments)
        }
    }

    // MARK: - Cua protocol configuration

    private func validateRequiredTools() async throws {
        let available = try await process.availableToolNames()
        let missing = Self.requiredTools.filter { !available.contains($0) }.sorted()
        guard missing.isEmpty else {
            throw CuaError.incompatibleDriver(missingTools: missing)
        }
    }

    /// Fetch and decode health directly through the transport. This helper is
    /// intentionally separate from `health()` so reconnect configuration does
    /// not recursively invoke the CUA reconnect policy.
    private func requestHealth() async throws -> CuaHealth {
        let result = try await process.callTool(
            name: "health_report",
            arguments: [
                "include": MCP.Value.array(Self.healthIncludeKeys.map(MCP.Value.string)),
            ]
        )
        return try CuaResponseDecoder.health(from: result)
    }

    // MARK: - Session label

    private static func makeSessionLabel() -> String {
        var generator = SystemRandomNumberGenerator()
        let raw = UInt32.random(in: .min ... .max, using: &generator)
        return String(format: "vimotion-%08x", raw)
    }
}
