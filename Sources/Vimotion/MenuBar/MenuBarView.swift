import SwiftUI
import AppKit

/// Menu-bar status (plan §4 MenuBarView).
enum MenuBarStatus: Equatable, Sendable {
    case ready
    case permissionRequired
    case cuaOffline

    /// Priority: Vimotion's own Accessibility first (nothing can work
    /// without it), then driver reachability (offline hides the Cua AX
    /// detail, which is unknown while disconnected), then the driver's
    /// AX readiness, else ready. Checking Cua AX before reachability would
    /// conflate offline with denied and permanently hide the Reconnect
    /// affordance, since apply(nil) fails Cua AX closed while offline.
    @MainActor
    static func compute(permissions: PermissionCoordinator, cuaConnected: Bool) -> MenuBarStatus {
        if permissions.vimotionAccessibility == .denied {
            return .permissionRequired
        }
        if !cuaConnected {
            return .cuaOffline
        }
        if permissions.cuaAccessibility == .denied {
            return .permissionRequired
        }
        return .ready
    }

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .permissionRequired: return "Permission Required"
        case .cuaOffline: return "Cua Offline"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .permissionRequired: return "exclamationmark.triangle.fill"
        case .cuaOffline: return "circle.slash.fill"
        }
    }

    var color: Color {
        switch self {
        case .ready: return .green
        case .permissionRequired: return .orange
        case .cuaOffline: return .red
        }
    }
}

/// MenuBarExtra content: status-driven icon label plus the actions. The
/// "Enable Hints" row carries the current activation chord as a native
/// keyboard-shortcut hint, so the chord is discoverable without opening
/// Settings.
struct MenuBarView: View {
    @ObservedObject var permissions: PermissionCoordinator
    let cuaConnected: Bool
    let isRefreshingDriver: Bool
    let activationChord: ActivationChord
    let onEnableHints: () -> Void
    let onReconnectDriver: () -> Void

    @Environment(\.openSettings) private var openSettings

    init(permissions: PermissionCoordinator,
         cuaConnected: Bool,
         isRefreshingDriver: Bool,
         activationChord: ActivationChord,
         onEnableHints: @escaping () -> Void,
         onReconnectDriver: @escaping () -> Void) {
        self.permissions = permissions
        self.cuaConnected = cuaConnected
        self.isRefreshingDriver = isRefreshingDriver
        self.activationChord = activationChord
        self.onEnableHints = onEnableHints
        self.onReconnectDriver = onReconnectDriver
    }

    private var status: MenuBarStatus {
        MenuBarStatus.compute(permissions: permissions, cuaConnected: cuaConnected)
    }

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .symbolRenderingMode(.palette)
            .foregroundStyle(status.color)

        Section {
            Text(status.title)
                .foregroundStyle(status.color)
        }

        enableHintsButton

        if status == .cuaOffline {
            Button(isRefreshingDriver ? "Reconnecting…" : "Reconnect to Driver") {
                onReconnectDriver()
            }
            .disabled(isRefreshingDriver)
        }

        Divider()

        Button("Settings…") { openSettings() }
        Button("Quit") { NSApp.terminate(nil) }
    }

    @ViewBuilder
    private var enableHintsButton: some View {
        if let shortcut = Self.menuShortcut(for: activationChord) {
            Button("Enable Hints") { onEnableHints() }
                .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
                .disabled(status != .ready)
        } else {
            Button("Enable Hints") { onEnableHints() }
                .disabled(status != .ready)
        }
    }
}

/// Pure chord → menu-shortcut mapping. `nil` for base keys that have no
/// menu KeyEquivalent (F-keys preserved by the settings editor): the row
/// then simply renders without a hint.
extension MenuBarView {
    static func menuShortcut(
        for chord: ActivationChord
    ) -> (key: KeyEquivalent, modifiers: EventModifiers)? {
        let key: KeyEquivalent
        if chord.keyCode == VimotionKeys.spaceKeyCode {
            key = .space
        } else if chord.keyCode == VimotionKeys.escapeKeyCode {
            key = .escape
        } else if let physical = PhysicalKey(cgKeyCode: chord.keyCode) {
            key = KeyEquivalent(extendedGraphemeClusterLiteral: physical.displayGlyph)
        } else {
            return nil
        }

        var modifiers: EventModifiers = []
        if chord.requiredFlags.contains(.maskCommand) { modifiers.insert(.command) }
        if chord.requiredFlags.contains(.maskShift) { modifiers.insert(.shift) }
        if chord.requiredFlags.contains(.maskControl) { modifiers.insert(.control) }
        if chord.requiredFlags.contains(.maskAlternate) { modifiers.insert(.option) }
        return (key, modifiers)
    }
}
