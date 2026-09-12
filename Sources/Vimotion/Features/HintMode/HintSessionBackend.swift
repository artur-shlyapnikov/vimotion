// HintSessionBackend.swift — feature-level Cua workflow for Hint Mode.
//
// The controller owns the Hint Mode state machine. This backend owns the
// feature's interaction with Cua and the target preparation rules: frontmost
// window selection, bounded snapshots, the owner-mismatch retry, coordinate
// conversion, filtering, code assignment, and stale-token recovery.

import AppKit
import Foundation
import os

/// Errors that are meaningful to Hint Mode rather than to the Cua transport.
/// Each case carries its frozen HUD copy, so the controller never maintains
/// a parallel error→string table and never learns the driver's raw taxonomy.
enum HintSessionBackendError: Error, Sendable, Equatable {
    case driverUnavailable
    case accessibilityRequired
    case scanTimedOut
    case targetChanged
    case noActionableElements

    /// Frozen user-visible copy. Single source for the HUD strings the
    /// controller historically duplicated in its own `hudText(for:)` switch.
    var hudText: String {
        switch self {
        case .driverUnavailable:
            return "Cua Driver unavailable"
        case .accessibilityRequired:
            return "Cua Accessibility required"
        case .scanTimedOut:
            return "UI scan timed out"
        case .targetChanged:
            return "Target changed"
        case .noActionableElements:
            return "No actionable elements"
        }
    }
}

/// Result of a target activation. A stale-token recovery that cannot prove a
/// unique replacement is intentionally silent, matching Hint Mode's
/// fail-closed behavior for changed UI identity.
enum HintActivationResult: Sendable, Equatable {
    case completed
    case abortedSilently
}

/// The prepared input for one Hint Mode session.
struct HintSessionLoad: Sendable, Equatable {
    let window: CuaWindow
    let snapshotID: String?
    let targets: [HintTarget]
}

@MainActor
final class HintSessionBackend {

    /// Snapshot hard budget. Kept on the feature backend so timeout policy is
    /// not part of the state machine. The controller forwards its historical
    /// test seam to this value.
    static var scanTimeout: Duration = .milliseconds(1500)

    private static let spActivationToWindow: StaticString = "activation_to_window"
    private static let spWindowToSnapshot: StaticString = "window_to_snapshot"
    private static let spSnapshotToTargets: StaticString = "snapshot_to_targets"
    private static let spClickToResult: StaticString = "click_to_result"

    private let serving: any CuaDriverServing
    private let resolver: WindowTargetResolver
    private let settings: SettingsStore

    init(serving: any CuaDriverServing,
         resolver: WindowTargetResolver,
         settings: SettingsStore) {
        self.serving = serving
        self.resolver = resolver
        self.settings = settings
    }

    /// Whether a key is currently accepted by the configured Hint alphabet.
    /// Reading this live preserves settings changes while a session is open.
    func acceptsHintKey(_ key: PhysicalKey) -> Bool {
        settings.hintAlphabet.contains(key)
    }

    /// Resolves and prepares all targets needed by a new Hint Mode session.
    /// Raw Cua failures are translated at this feature boundary.
    func loadSession() async throws -> HintSessionLoad {
        do {
            let window: CuaWindow = try await resolveFrontmost()
            let snapshot = try await loadSnapshot(for: window)

            let interval = PerformanceMetrics.signposter.beginInterval(Self.spSnapshotToTargets)
            defer { PerformanceMetrics.signposter.endInterval(Self.spSnapshotToTargets, interval) }
            let targets = ElementFilter.prepare(snapshot, alphabet: settings.hintAlphabet)
            guard !targets.isEmpty else {
                throw HintSessionBackendError.noActionableElements
            }
            return HintSessionLoad(
                window: window,
                snapshotID: snapshot.snapshotID,
                targets: targets
            )
        } catch let error as HintSessionBackendError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.map(error)
        }
    }

    private func resolveFrontmost() async throws -> CuaWindow {
        let interval = PerformanceMetrics.signposter.beginInterval(Self.spActivationToWindow)
        defer { PerformanceMetrics.signposter.endInterval(Self.spActivationToWindow, interval) }
        return try await resolver.resolveFrontmost()
    }

    /// Activates a target and spends at most one stale-token recovery attempt.
    /// A failed recovery is a silent abort; an ordinary click failure remains a
    /// feature error for the controller to surface in its HUD.
    func activate(_ target: HintTarget) async throws -> HintActivationResult {
        do {
            return try await performClick(target, allowRecovery: true)
        } catch let error as HintSessionBackendError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: Snapshot workflow

    /// Snapshot with a hard timeout and exactly one retry when Cua reports
    /// that the window's owner changed. The retry first verifies that the
    /// window identity is still present, then uses the reported PID.
    private func loadSnapshot(for window: CuaWindow) async throws -> CuaWindowSnapshot {
        do {
            return try await timedSnapshot(pid: window.pid, windowID: window.windowID)
        } catch CuaError.windowOwnerMismatch(let actualPID) {
            try Task.checkCancellation()
            let windows = try await serving.listWindows(onScreenOnly: true)
            try Task.checkCancellation()
            // Verify the window is still present before retrying with the
            // owner reported by Cua. The driver owns the PID/window identity
            // check; list_windows may briefly lag the owner transition.
            guard windows.contains(where: { $0.windowID == window.windowID }) else {
                throw CuaError.windowNotFound
            }
            AppLogger.hint.info(
                "owner mismatch, retrying snapshot pid=\(actualPID) window=\(window.windowID)"
            )
            return try await timedSnapshot(pid: actualPID, windowID: window.windowID)
        }
    }

    private func timedSnapshot(pid: pid_t, windowID: UInt32) async throws -> CuaWindowSnapshot {
        let serving = self.serving
        let interval = PerformanceMetrics.signposter.beginInterval(Self.spWindowToSnapshot)
        defer { PerformanceMetrics.signposter.endInterval(Self.spWindowToSnapshot, interval) }
        let budget = Self.scanTimeout
        try Task.checkCancellation()
        // Hard-budget race: a task-group scope would await a wedged snapshot
        // child before returning, so the timeout could never fire on time
        // (the snapshot RPC has no cancellation point). Race unstructured
        // tasks instead; the loser is cancelled and its late result ignored.
        // Outer cancellation resolves no later than the budget: the pending
        // generation check in the controller discards the stale outcome.
        return try await withCheckedThrowingContinuation { continuation in
            let once = SnapshotRaceGuard()
            let snapshotTask = Task {
                do {
                    let snapshot = try await serving.snapshot(pid: pid, windowID: windowID)
                    once.run { continuation.resume(returning: snapshot) }
                } catch {
                    once.run { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: budget)
                once.run {
                    snapshotTask.cancel()
                    continuation.resume(throwing: CuaError.timeout)
                }
            }
        }
    }

    // MARK: Activation + stale-token recovery

    private func performClick(
        _ target: HintTarget,
        allowRecovery: Bool
    ) async throws -> HintActivationResult {
        let interval = PerformanceMetrics.signposter.beginInterval(Self.spClickToResult)
        do {
            try await serving.click(pid: target.pid, elementToken: target.token)
            PerformanceMetrics.signposter.endInterval(Self.spClickToResult, interval)
            return .completed
        } catch {
            PerformanceMetrics.signposter.endInterval(Self.spClickToResult, interval)
            guard let cuaError = error as? CuaError,
                  cuaError == .staleElementToken else {
                throw error
            }
            guard allowRecovery else { return .abortedSilently }
            return try await recoverStaleTarget(target)
        }
    }

    /// Re-resolves the same frontmost window, obtains a fresh snapshot, and
    /// clicks only when exactly one normalized target matches the original
    /// fingerprint. Errors while proving that identity are deliberately
    /// converted to a silent abort. The replacement click itself stays outside
    /// this catch so a real second-click failure still reaches the HUD.
    private func recoverStaleTarget(_ originalTarget: HintTarget) async throws -> HintActivationResult {
        guard !Task.isCancelled else { return .abortedSilently }

        let window: CuaWindow
        let snapshot: CuaWindowSnapshot
        let match: HintTarget
        do {
            window = try await resolver.resolveFrontmost()
            guard !Task.isCancelled else { return .abortedSilently }
            guard window.pid == originalTarget.pid,
                  window.windowID == originalTarget.windowID else {
                return .abortedSilently
            }

            snapshot = try await timedSnapshot(pid: window.pid, windowID: window.windowID)
            guard !Task.isCancelled else { return .abortedSilently }

            let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
            let candidates = ElementFilter
                .normalize(snapshot, mainDisplayHeight: mainDisplayHeight)
                .filter { matchesFingerprint($0, original: originalTarget) }
            guard candidates.count == 1, let uniqueMatch = candidates.first else {
                return .abortedSilently
            }
            match = uniqueMatch
        } catch {
            return .abortedSilently
        }

        guard !Task.isCancelled else { return .abortedSilently }
        var replacement = originalTarget
        replacement.token = match.token
        return try await performClick(replacement, allowRecovery: false)
    }

    private func matchesFingerprint(_ candidate: HintTarget, original: HintTarget) -> Bool {
        let originalFingerprint = original.fingerprint
        let candidateFingerprint = candidate.fingerprint

        guard candidate.role == original.role
                || candidateFingerprint.normalizedRole == originalFingerprint.normalizedRole else {
            return false
        }

        if let label = originalFingerprint.normalizedLabel,
           !label.isEmpty,
           candidateFingerprint.normalizedLabel != label {
            return false
        }

        let dx = Double(candidateFingerprint.center.x - originalFingerprint.center.x)
        let dy = Double(candidateFingerprint.center.y - originalFingerprint.center.y)
        guard (dx * dx + dy * dy).squareRoot() <= 12 else { return false }

        let widthTolerance = max(12, originalFingerprint.size.width * 0.25)
        let heightTolerance = max(12, originalFingerprint.size.height * 0.25)
        guard abs(candidateFingerprint.size.width - originalFingerprint.size.width) <= widthTolerance,
              abs(candidateFingerprint.size.height - originalFingerprint.size.height) <= heightTolerance else {
            return false
        }
        return true
    }

    // MARK: Error boundary

    private static func map(_ error: any Error) -> HintSessionBackendError {
        if let featureError = error as? HintSessionBackendError {
            return featureError
        }
        guard let cuaError = error as? CuaError else {
            return .driverUnavailable
        }
        switch cuaError {
        case .timeout:
            return .scanTimedOut
        case .accessibilityDenied:
            return .accessibilityRequired
        case .windowNotFound:
            return .targetChanged
        default:
            return .driverUnavailable
        }
    }
}

/// Resume-once guard for the snapshot/timeout race: exactly one racer
/// resumes the continuation; the loser's late result is dropped.
private final class SnapshotRaceGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        guard !done else {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        body()
    }
}
