// AppEnvironment.swift — composition root (plan §AppEnvironment).
//
// Owns every long-lived object and wires the frozen seams:
//   GlobalInput → MainActor intent dispatch →
//   HintModeController → CuaDriverClient / WindowTargetResolver / overlay.
// No global singletons: the AppDelegate owns this instance and SwiftUI scenes
// receive pieces of it directly.

import AppKit
import Combine
import CoreGraphics
import Foundation
import os

@MainActor
private final class HintModeIntentRouter {
    weak var controller: HintModeController?

    func handle(_ intent: InputIntent) {
        controller?.handle(intent)
    }
}

@MainActor
final class AppEnvironment: ObservableObject {

    let settings: SettingsStore
    let permissions: PermissionCoordinator
    let cuaClient: CuaDriverClient
    let input: GlobalInput
    let overlay: OverlayCoordinator
    let resolver: WindowTargetResolver
    let controller: HintModeController

    /// Driver transport reachability for menu-bar status. Set by the startup
    /// health attempt; afterwards refreshed only by the explicit menu-bar
    /// reconnect — nothing retries automatically.
    @Published private(set) var cuaOnline = false

    /// True while a driver health attempt is in flight; coalesces repeated
    /// menu reconnects and drives the menu's disabled state.
    @Published private(set) var isRefreshingDriver = false

    private var cancellables = Set<AnyCancellable>()

    /// Upper bound for the synchronous Cua teardown wait in shutdown().
    private static let teardownBudget: TimeInterval = 1.0
    private var startupTask: Task<Void, Never>?

    /// While Vimotion's own Accessibility is missing, re-checks trust every
    /// 2 s so granting in System Settings takes effect without a relaunch.
    /// This watches local TCC state only — it is not the driver retry loop
    /// that plan §3.4 prohibits (driver reachability stays menu/startup-driven).
    private var accessibilityWatchTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init() {
        let settings = SettingsStore()
        let permissions = PermissionCoordinator()
        let client = CuaDriverClient()
        let overlay = OverlayCoordinator()
        let intentRouter = HintModeIntentRouter()
        let input = GlobalInput { [intentRouter] intent in
            intentRouter.handle(intent)
        }
        let resolver = WindowTargetResolver(
            providers: WindowTargetingProviders(
                listWindows: { onScreenOnly in
                    try await client.listWindows(onScreenOnly: onScreenOnly)
                },
                quartzLayer0FrontToBack: AppEnvironment.quartzLayer0FrontToBack
            ),
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
        let controller = HintModeController(
            serving: client,
            resolver: resolver,
            overlay: overlay,
            input: input,
            settings: settings
        )
        intentRouter.controller = controller

        self.settings = settings
        self.permissions = permissions
        self.cuaClient = client
        self.input = input
        self.overlay = overlay
        self.resolver = resolver
        self.controller = controller
    }

    // MARK: - Startup

    func start() {
        input.configure(
            activationChord: settings.activationChord,
            alphabet: settings.hintAlphabet
        )

        // Live input updates whenever the user edits activation settings.
        settings.$activationKeyCode
            .combineLatest(settings.$activationModifiers, settings.$hintAlphabet)
            .sink { [input] keyCode, modifiers, alphabet in
                input.configure(
                    activationChord: ActivationChord(keyCode: keyCode, requiredFlags: modifiers),
                    alphabet: alphabet
                )
            }
            .store(in: &cancellables)
        permissions.refreshVimotionAccessibility(prompt: false)

        if permissions.vimotionAccessibility == .granted {
            do {
                try input.start()
            } catch {
                AppLogger.input.error(
                    "event tap failed to start: \(String(describing: error), privacy: .public)"
                )
            }
        } else {
            startAccessibilityWatch()
            AppLogger.app.notice("accessibility not granted; watching for grant")
        }

        // Single health attempt — success marks online, failure marks offline.
        // No retry loop (plan §3.4): only the explicit menu-bar reconnect
        // re-checks later.
        startupTask = Task { await refreshDriverOnline() }

        installObservers()
    }

    /// Driver health attempt shared by startup and the menu-bar reconnect.
    /// Coalesced while one attempt is in flight; cancellation (shutdown)
    /// prevents any state write after teardown began.
    func refreshDriverOnline() async {
        guard !isRefreshingDriver else { return }
        isRefreshingDriver = true
        defer { isRefreshingDriver = false }
        do {
            let health = try await cuaClient.connect()
            guard !Task.isCancelled else { return }
            permissions.apply(cuaHealth: health)
            cuaOnline = true
            AppLogger.cua.info("driver online")
        } catch {
            guard !Task.isCancelled else { return }
            permissions.apply(cuaHealth: nil)
            cuaOnline = false
            AppLogger.cua.info(
                "driver offline: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - Accessibility watch

    private func startAccessibilityWatch() {
        accessibilityWatchTask?.cancel()
        accessibilityWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                permissions.refreshVimotionAccessibility(prompt: false)
                guard permissions.vimotionAccessibility == .granted else { continue }
                do {
                    try input.start()
                    AppLogger.app.notice("accessibility granted: event tap started")
                    await refreshDriverOnline()
                    accessibilityWatchTask?.cancel()
                    accessibilityWatchTask = nil
                } catch {
                    // Rare race (trust flipped but tap creation failed):
                    // keep watching and retry on the next tick.
                    AppLogger.input.error(
                        "event tap start failed after grant: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
    }

    // MARK: - Teardown

    func shutdown() {
        accessibilityWatchTask?.cancel()
        startupTask?.cancel()
        startupTask = nil
        controller.shutdown()
        input.stop()

        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers.removeAll()
        cancellables.removeAll()

        // applicationWillTerminate gives no cooperative async runway: bridge
        // the async teardown onto a detached helper and block briefly so the
        // driver subprocess actually receives termination before exit. A
        // hung teardown must never wedge termination past the budget.
        let latch = DispatchSemaphore(value: 0)
        let client = cuaClient
        Task.detached {
            await client.shutdown()
            latch.signal()
        }
        _ = latch.wait(timeout: .now() + Self.teardownBudget)
    }

    // MARK: - Observers

    /// Workspace/screen notifications only matter mid-session; the controller
    /// guards internally when idle, so unconditional forwarding is correct.
    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.frontmostAppDidChange() }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.screensDidChange() }
        })
    }

    // MARK: - Quartz fallback provider

    /// On-screen, desktop-excluded CG windows in front-to-back order,
    /// restricted to layer 0 (normal app windows). Order is guaranteed by
    /// CGWindowListCopyWindowInfo with .optionOnScreenOnly.
    nonisolated static func quartzLayer0FrontToBack()
        -> [(windowNumber: UInt32, pid: pid_t)]
    {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var result: [(windowNumber: UInt32, pid: pid_t)] = []
        result.reserveCapacity(list.count)
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int
            else { continue }
            result.append((windowNumber: UInt32(number), pid: pid_t(pid)))
        }
        return result
    }
}
