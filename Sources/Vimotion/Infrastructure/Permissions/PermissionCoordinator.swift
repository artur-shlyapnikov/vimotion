import Foundation
import ApplicationServices
import ApplicationServices.HIServices

/// Tracks the two independent permission owners (plan §3.25):
/// Vimotion's own Accessibility grant and the Cua driver's AX readiness.
///
/// Screen Recording is optional in the MVP and is never prompted for; its
/// status is `nil` (unknown) unless a health report carries the check.
/// Mirrors `kAXTrustedCheckOptionPrompt` ("AXTrustedCheckOptionPrompt").
/// Referencing the HIServices global directly is not concurrency-safe under
/// strict Swift 6 isolation; the key string is a documented, frozen constant,
/// so we bind our own immutable copy instead.
private nonisolated(unsafe) let axTrustedCheckOptionPrompt = "AXTrustedCheckOptionPrompt" as CFString

@MainActor
final class PermissionCoordinator: ObservableObject {

    enum Status: Equatable, Sendable { case granted, denied }

    @Published private(set) var vimotionAccessibility: Status
    @Published private(set) var cuaAccessibility: Status
    @Published private(set) var cuaScreenRecording: Status?   // nil = unknown/not requested (optional in MVP)

    init() {
        vimotionAccessibility = .denied
        cuaAccessibility = .denied
        refreshVimotionAccessibility(prompt: false)
    }

    /// Checks Vimotion's Accessibility trust. `prompt: true` triggers the
    /// system prompt; only call that from an explicit user action (onboarding).
    func refreshVimotionAccessibility(prompt: Bool) {
        let options = [axTrustedCheckOptionPrompt as String: prompt] as CFDictionary
        vimotionAccessibility = AXIsProcessTrustedWithOptions(options) ? .granted : .denied
    }

    /// Maps a Cua driver health report onto published statuses. `nil` health
    /// (driver offline / not yet connected) means Cua accessibility is unknown
    /// to us → treated as denied, failing closed.
    func apply(cuaHealth: CuaHealth?) {
        guard let health = cuaHealth else {
            cuaAccessibility = .denied
            cuaScreenRecording = nil
            return
        }
        // tccAccessibility is the TCC grant; axCapability == false means the
        // driver cannot actually use AX even when granted → denied.
        if health.tccAccessibility == true, health.axCapability != false {
            cuaAccessibility = .granted
        } else {
            cuaAccessibility = .denied
        }

        // The MVP health_report schema carries no screen-recording check key;
        // absence ⇒ nil status ("—") per plan §3.25: optional, never prompted.
        cuaScreenRecording = nil
    }
}
