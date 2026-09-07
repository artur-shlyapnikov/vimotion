// SettingsHotkey.swift
//
// Global ⌥⌘V hotkey that opens the Settings window. Exists so the app is
// configurable even when its menu-bar item is pushed off-screen by an
// overcrowded status bar (notched Macs hide overflow items entirely).

import AppKit
import Carbon.HIToolbox

/// C-function-pointer-compatible handler; must not capture context.
private func settingsHotkeyEventHandler(
    _ hid: EventHandlerCallRef?,
    _ event: EventRef?,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    // Carbon invokes this on the main event loop, not the MainActor
    // executor, so assumeIsolated would trap. Hop instead.
    Task { @MainActor in
        SettingsHotkey.openSettings()
    }
    return noErr
}

@MainActor
enum SettingsHotkey {
    private nonisolated(unsafe) static var hotKeyRef: EventHotKeyRef?
    private static var installed = false
    /// Idempotent; call once during app launch.
    static func install() {
        guard !installed else { return }

        let hotKeyID = EventHotKeyID(signature: OSType(0x564D_544E) /* 'VMTN' */, id: 1)
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            settingsHotkeyEventHandler,
            1,
            &eventType,
            nil,
            nil
        )
        guard status == noErr else {
            print("hotkey: InstallEventHandler failed \(status)")
            return
        }

        // ⌥⌘V: unlikely to collide with system or common app shortcuts.
        let reg = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(optionKey | cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard reg == noErr else {
            print("hotkey: RegisterEventHotKey failed \(reg)")
            return
        }
        installed = true
    }
    static func openSettings() {
        // `as? AppDelegate` can fail under @NSApplicationDelegateAdaptor
        // (two runtime copies of the class); dispatch through the delegate
        // object directly instead.
        guard let d = NSApp.delegate else { return }
        let sel = #selector(AppDelegate.openSettingsWindow)
        if d.responds(to: sel) {
            d.perform(sel, with: nil)
        }
    }
}
