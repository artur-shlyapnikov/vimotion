// VimotionApp.swift — SwiftUI app shell (plan §4).
//
// Background-only utility: .accessory activation policy (set before anything
// else) plus LSUIElement in the bundle. The AppDelegate owns the single
// AppEnvironment instance — no global singletons; scenes receive the pieces
// they need directly.

import AppKit
import SwiftUI

@main
struct VimotionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarSceneContent(environment: delegate.environment)
        } label: {
            StatusBarLabel(
                environment: delegate.environment,
                permissions: delegate.environment.permissions
            )
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(
                store: delegate.environment.settings,
                permissions: delegate.environment.permissions
            )
        }
    }
}

/// Owns the app environment and lifecycle hooks. Constructing the
/// environment here (not in a global) keeps a single clear owner.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let environment = AppEnvironment()

    override init() {
        super.init()
        // Immediate, unconditional background-only policy.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        // ⌥⌘V opens Settings globally — the tray icon can be pushed
        // off-screen by a full menu bar; the hotkey stays reachable.
        environment.start()
        SettingsHotkey.install()
    }
    /// Own Settings window: SwiftUI's programmatic
    /// showSettingsWindow:/showPreferencesWindow: selectors are unreliable
    /// here (accessory app, no scene bridge), so host SettingsView directly.
    private var settingsWindowController: NSWindowController?

    @objc func openSettingsWindow() {
        if let wc = settingsWindowController {
            wc.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let vc = NSHostingController(
            rootView: SettingsView(store: environment.settings,
                                   permissions: environment.permissions)
        )
        let window = NSWindow(contentViewController: vc)
        window.styleMask = [.titled, .closable]
        window.title = "Vimotion Settings"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 480))
        window.center()
        let wc = NSWindowController(window: window)
        settingsWindowController = wc
        wc.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment.shutdown()
    }
}

/// Menu-bar content; observes the environment so cuaOnline flips re-render.
private struct MenuBarSceneContent: View {
    @ObservedObject var environment: AppEnvironment

    var body: some View {
        MenuBarView(
            permissions: environment.permissions,
            cuaConnected: environment.cuaOnline,
            isRefreshingDriver: environment.isRefreshingDriver,
            activationChord: environment.settings.activationChord,
            onEnableHints: { environment.controller.handle(.activateHintMode) },
            onReconnectDriver: { Task { await environment.refreshDriverOnline() } }
        )
    }
}

/// Reactive menu-bar label: status icon + text driven by permissions and
/// driver reachability.
private struct StatusBarLabel: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject var permissions: PermissionCoordinator

    var body: some View {
        let status = MenuBarStatus.compute(permissions: permissions, cuaConnected: environment.cuaOnline)
        // Icon-only: a titled label gets clipped behind the notch on
        // notched Macs; the full status text lives inside the menu.
        Image(systemName: status.systemImage)
            .symbolRenderingMode(.palette)
            .foregroundStyle(status.color)
    }
}
