import SwiftUI
import AppKit
import ServiceManagement

/// Settings UI (plan §3.26 / §3.25 onboarding rows).
///
/// MVP-honest editors: activation chord via modifier checkboxes + letter
/// picker; hint alphabet as toggle chips with a ≥4-distinct save gate.
/// Launch-at-login reads `SMAppService.mainApp` registration as the single
/// source of truth (never duplicated into UserDefaults).
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var permissions: PermissionCoordinator

    // Draft state for the activation editor; applied only on "Apply".
    @State private var draftUseCommand = true
    @State private var draftUseShift = true
    @State private var draftUseControl = false
    @State private var draftUseOption = false
    @State private var draftLetter: PhysicalKey?

    // Draft chips for the alphabet editor.
    @State private var selectedKeys: Set<PhysicalKey> = []

    // Mirrors SMAppService.mainApp.status so the toggle re-renders even when
    // register/unregister throws (custom-Binding sets mutate no @State).
    @State private var launchAtLogin = false

    init(store: SettingsStore, permissions: PermissionCoordinator) {
        self.store = store
        self.permissions = permissions
    }

    var body: some View {
        Form {
            activationSection
            alphabetSection
            launchAtLoginSection
            permissionsSection
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear {
            syncDraftsWithStore()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Activation shortcut

    private var activationSection: some View {
        Section("Activation Shortcut") {
            LabeledContent("Current") {
                Text(Self.format(chord: store.activationChord))
                    .font(.system(.title3, design: .monospaced))
            }
            Text("Press this shortcut anywhere in macOS to show hints over the frontmost window. The base key may match a hint key — the modifiers make the difference.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Toggle("⌘", isOn: $draftUseCommand)
                Toggle("⇧", isOn: $draftUseShift)
                Toggle("⌃", isOn: $draftUseControl)
                Toggle("⌥", isOn: $draftUseOption)
            }
            if draftLetter == nil,
               PhysicalKey(cgKeyCode: store.activationKeyCode) == nil {
                Text("Base key \(currentBaseKeyName) can't be selected here; Apply keeps it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("Base key", selection: Binding(
                get: { draftLetter ?? PhysicalKey(cgKeyCode: store.activationKeyCode) ?? .a },
                set: { draftLetter = $0 }
            )) {
                ForEach(PhysicalKey.allCases, id: \.self) { key in
                    Text(String(key.displayGlyph)).tag(key)
                }
            }

            HStack {
                Button("Apply") { applyActivationDraft() }
                    .disabled(!activationDraftIsValid || activationDraftUnchanged)
                Spacer()
                Text(Self.format(chord: activationDraftChord))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(activationDraftIsValid ? Color.primary : Color.secondary)
            }
            if !activationDraftIsValid {
                Text("At least one modifier is required.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var activationDraftModifiers: CGEventFlags {
        var flags: CGEventFlags = []
        if draftUseCommand { flags.insert(.maskCommand) }
        if draftUseShift { flags.insert(.maskShift) }
        if draftUseControl { flags.insert(.maskControl) }
        if draftUseOption { flags.insert(.maskAlternate) }
        return flags
    }

    private var activationDraftIsValid: Bool {
        !activationDraftModifiers.isEmpty
    }

    /// The chord Apply would persist right now: draft modifiers plus the
    /// picked letter, or the store's base key when nothing is picked
    /// (non-letter keys like Space are preserved, never rewritten).
    private var activationDraftChord: ActivationChord {
        ActivationChord(
            keyCode: draftLetter?.cgKeyCode ?? store.activationKeyCode,
            requiredFlags: activationDraftModifiers
        )
    }

    private var activationDraftUnchanged: Bool {
        activationDraftChord == store.activationChord
    }


    private func applyActivationDraft() {
        guard activationDraftIsValid else { return }
        store.setActivation(activationDraftChord)
    }

    private func syncDraftsWithStore() {
        let masked = store.activationModifiers.intersection(SettingsStore.allowedModifiers)
        draftUseCommand = masked.contains(.maskCommand)
        draftUseShift = masked.contains(.maskShift)
        draftUseControl = masked.contains(.maskControl)
        draftUseOption = masked.contains(.maskAlternate)
        // An explicit pick survives only until the next sync; a non-letter
        // base key (e.g. Space) is preserved, never silently rewritten.
        draftLetter = nil
        selectedKeys = Set(store.hintAlphabet)
    }

    // MARK: - Hint alphabet

    private var alphabetSection: some View {
        Section("Hint Alphabet") {
            Text("Keys used to build hint codes. At least 4 distinct keys are required.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                ForEach(PhysicalKey.defaultAlphabetOrder, id: \.self) { key in
                    alphabetChip(key)
                }
            }

            let distinct = selectedKeys.count
            Button(distinct < 4 ? "Save (\(distinct)/4 keys)" : "Save") { applyAlphabetDraft() }
                .disabled(distinct < 4)
        }
    }

    private func alphabetChip(_ key: PhysicalKey) -> some View {
        let isSelected = selectedKeys.contains(key)
        return Button {
            if isSelected { selectedKeys.remove(key) } else { selectedKeys.insert(key) }
        } label: {
            Text(String(key.displayGlyph))
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? .accentColor : .secondary)
        .opacity(isSelected ? 1.0 : 0.55)
    }

    private func applyAlphabetDraft() {
        // Deterministic persistence order: default ergonomic order filtered by
        // the selection. Invalid input (<4 distinct) is repaired by the store.
        let keys = PhysicalKey.defaultAlphabetOrder.filter { selectedKeys.contains($0) }
        store.setHintAlphabet(keys)
        selectedKeys = Set(store.hintAlphabet)
    }

    // MARK: - Launch at login

    private var launchAtLoginSection: some View {
        Section("General") {
            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin },
                set: { enabled in setLaunchAtLogin(enabled) }
            ))
        }
    }

    /// `SMAppService` status is the source of truth; we only register or
    /// unregister and re-read the resulting status.
    /// Registers/unregisters, then re-reads the ACTUAL resulting status into
    /// the mirrored @State — on failure the toggle snaps back to the truth
    /// instead of silently keeping the flipped visual state.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            AppLogger.app.error("launch-at-login toggle failed: \(String(describing: error), privacy: .public)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section("Permissions") {
            permissionRow(
                name: "Vimotion Accessibility",
                requirement: "Required",
                status: permissions.vimotionAccessibility
            ) {
                Button("Enable…") { permissions.refreshVimotionAccessibility(prompt: true) }
            }

            permissionRow(
                name: "Cua Accessibility",
                requirement: "Required",
                status: permissions.cuaAccessibility
            ) {
                Button("Open System Settings") { Self.openAccessibilitySystemSettings() }
            }

            permissionRow(
                name: "Cua Screen Recording",
                requirement: "Optional",
                status: permissions.cuaScreenRecording
            ) {
                EmptyView()
            }
        }
    }

    private func permissionRow<Trailing: View>(
        name: String,
        requirement: String,
        status: PermissionCoordinator.Status?,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(requirement).font(.caption).foregroundStyle(.secondary)
            trailing()
            Text(mark(for: status))
                .foregroundStyle(color(for: status))
        }
    }

    private func mark(for status: PermissionCoordinator.Status?) -> String {
        switch status {
        case .granted: return "✓"
        case .denied: return "✗"
        case nil: return "—"
        }
    }

    private func color(for status: PermissionCoordinator.Status?) -> Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        case nil: return .secondary
        }
    }

    // MARK: - Helpers
    /// Human name for the current activation base key ("A", "Space", …),
    /// including keys the letter picker cannot represent.
    private var currentBaseKeyName: String {
        let code = store.activationKeyCode
        if let key = PhysicalKey(cgKeyCode: code) { return String(key.displayGlyph) }
        if code == VimotionKeys.spaceKeyCode { return "Space" }
        if code == VimotionKeys.escapeKeyCode { return "Esc" }
        return "Key(\(code))"
    }


    /// Formats a chord like "⌘⇧Space" / "⌃A".
    static func format(chord: ActivationChord) -> String {
        var text = ""
        if chord.requiredFlags.contains(.maskControl) { text += "⌃" }
        if chord.requiredFlags.contains(.maskAlternate) { text += "⌥" }
        if chord.requiredFlags.contains(.maskShift) { text += "⇧" }
        if chord.requiredFlags.contains(.maskCommand) { text += "⌘" }
        if let key = PhysicalKey(cgKeyCode: chord.keyCode) {
            text.append(key.displayGlyph)
        } else if chord.keyCode == VimotionKeys.spaceKeyCode {
            text += "Space"
        } else if chord.keyCode == VimotionKeys.escapeKeyCode {
            text += "Esc"
        } else {
            text += "Key(\(chord.keyCode))"
        }
        return text
    }

    static func openAccessibilitySystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
