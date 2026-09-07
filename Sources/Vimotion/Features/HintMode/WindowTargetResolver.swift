// WindowTargetResolver.swift — frontmost window targeting (plan §3.8).
//
// Primary algorithm: list_windows(on_screen_only:true) → drop own PID,
// invalid/zero-sized bounds, off-screen, off-space windows → pick MAX zIndex
// among the non-nil entries. Fallback when ALL remaining windows have nil
// zIndex: Quartz layer-0 front-to-back order (CGWindowListCopyWindowInfo is
// guaranteed front-to-back for .optionOnScreenOnly), taking the FIRST Quartz
// entry present in the Cua candidate set. Identity always comes from Cua.
// No match → fails closed with .windowNotFound.

import Foundation

struct WindowTargetingProviders: Sendable {
    var listWindows: @Sendable (_ onScreenOnly: Bool) async throws -> [CuaWindow]
    var quartzLayer0FrontToBack: @Sendable () -> [(windowNumber: UInt32, pid: pid_t)]  // injectable for tests
}

struct WindowTargetResolver: Sendable {
    var providers: WindowTargetingProviders
    var ownPID: pid_t

    func resolveFrontmost() async throws -> CuaWindow {
        let all = try await providers.listWindows(true)
        let candidates = all.filter { window in
            window.pid != ownPID
                && window.bounds.width > 0 && window.bounds.height > 0
                && window.isOnScreen
                && window.onCurrentSpace
        }

        let zOrdered = candidates.filter { $0.zIndex != nil }
        if let top = zOrdered.max(by: { $0.zIndex! < $1.zIndex! }) {
            return top
        }

        // Every remaining candidate lacks zIndex → native stacking fallback.
        for entry in providers.quartzLayer0FrontToBack() where candidates.contains(where: { $0.windowID == entry.windowNumber }) {
            guard let match = candidates.first(where: { $0.windowID == entry.windowNumber }) else { continue }
            return match
        }
        throw CuaError.windowNotFound
    }
}
