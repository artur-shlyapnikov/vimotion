// CuaDriverServing.swift — internal test seam for HintModeController.
// Verbatim from local://vimotion-contract.md and plan §3.5.

import Foundation
protocol CuaDriverServing: Sendable {
    func health() async throws -> CuaHealth
    func listWindows(onScreenOnly: Bool) async throws -> [CuaWindow]
    func snapshot(pid: pid_t, windowID: UInt32) async throws -> CuaWindowSnapshot
    func click(pid: pid_t, elementToken: String) async throws
}
