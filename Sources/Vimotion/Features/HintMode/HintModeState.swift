// HintModeState.swift — Hint Mode state machine types (plan §3.14).
// Verbatim from local://vimotion-contract.md ("Frozen types").

import Foundation

/// Immutable snapshot of one active hint session.
struct HintSession: Sendable {
    var generation: UInt64
    var targetWindow: CuaWindow
    var snapshotID: String?
    var targets: [HintTarget]
    var typedPrefix: [PhysicalKey]
    var startedAt: ContinuousClock.Instant
}

/// No persistent error state: errors surface as a transient HUD and the
/// controller returns to `idle` immediately.
enum HintModeState: Sendable {
    case idle
    case loading(generation: UInt64, bufferedKeys: [PhysicalKey], startedAt: ContinuousClock.Instant)
    case active(HintSession)
    case executing(generation: UInt64, target: HintTarget)
}
