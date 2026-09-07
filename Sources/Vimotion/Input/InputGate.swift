import Foundation
import CoreGraphics
import os
enum GateMode: Sendable { case activationOnly, hintCapture }

enum InputIntent: Sendable, Equatable {
    case activateHintMode
    case cancelHintMode
    case hintKey(PhysicalKey)
    case backspace
}

enum OtherInputKind: Sendable { case leftMouseDown, rightMouseDown, otherMouseDown, scrollWheel }

struct InputDecision: Sendable, Equatable {
    var suppress: Bool
    var intent: InputIntent?

    static let pass = InputDecision(suppress: false, intent: nil)

    static func suppress(_ intent: InputIntent?) -> InputDecision {
        InputDecision(suppress: true, intent: intent)
    }
}

/// Pure, lock-protected decision engine for the global event tap (plan §3.17).
///
/// The event-tap callback consults this gate synchronously; all mutable state
/// lives behind an `OSAllocatedUnfairLock`, so the callback never touches the
/// MainActor.
final class InputGate: @unchecked Sendable {

    /// Only these modifier bits participate in chord matching; all other
    /// CGEventFlags bits (caps lock, numeric pad, function, device flags…) are
    /// ignored.
    private static let modifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]

    var activationChord: ActivationChord {
        get { state.withLock { $0.chord } }
        set { state.withLock { $0.chord = newValue } }
    }

    var mode: GateMode {
        get { state.withLock { $0.mode } }
        set { state.withLock { $0.mode = newValue } }
    }

    /// Keycodes accepted as hint letters during capture. Letters outside this
    /// set behave like unrecognized keys: capture exits atomically and the
    /// event passes through unwritten (plan §3.26). Defaults to every
    /// physical letter so unwired configurations keep the historical behavior.
    var configuredHintKeyCodes: Set<UInt64> {
        get { state.withLock { $0.configuredHintKeyCodes } }
        set { state.withLock { $0.configuredHintKeyCodes = newValue } }
    }

    private struct State {
        var mode: GateMode = .activationOnly
        var chord = ActivationChord(keyCode: VimotionKeys.spaceKeyCode, requiredFlags: [.maskCommand, .maskShift])
        /// KeyDown-suppressed keycodes with outstanding keyUps, counted:
        /// the activation base key may coincide with a hint key, so the
        /// same keycode can be suppressed twice before either keyUp lands.
        /// A Set would dedupe the pair and leak the second keyUp to the
        /// target app as an orphan.
        var pendingKeyUps: [UInt64: Int] = [:]
        var configuredHintKeyCodes: Set<UInt64> = Set(PhysicalKey.allCases.map(\.cgKeyCode))
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    init() {}

    /// Updates the complete configuration under one lock acquisition so an
    /// event-tap callback cannot observe a new chord with an old alphabet (or
    /// vice versa).
    func configure(activationChord: ActivationChord, configuredHintKeyCodes: Set<UInt64>) {
        state.withLock { st in
            st.chord = activationChord
            st.configuredHintKeyCodes = configuredHintKeyCodes
        }
    }

    func beginHintCapture() {
        state.withLock { $0.mode = .hintCapture }
    }

    func endHintCapture() {
        state.withLock { $0.mode = .activationOnly }
    }

    // MARK: - Events

    func evaluateKeyDown(keyCode: UInt64, flags: CGEventFlags, isAutoRepeat: Bool) -> InputDecision {
        state.withLock { st in
            let masked = flags.intersection(Self.modifierMask)
            switch st.mode {
            case .activationOnly:
                return evaluateKeyDownActivationOnly(st: &st, keyCode: keyCode, masked: masked, isAutoRepeat: isAutoRepeat)
            case .hintCapture:
                return evaluateKeyDownHintCapture(st: &st, keyCode: keyCode, masked: masked, isAutoRepeat: isAutoRepeat)
            }
        }
    }

    func evaluateKeyUp(keyCode: UInt64, flags: CGEventFlags) -> InputDecision {
        state.withLock { st in
            if let count = st.pendingKeyUps[keyCode], count > 0 {
                if count == 1 {
                    st.pendingKeyUps.removeValue(forKey: keyCode)
                } else {
                    st.pendingKeyUps[keyCode] = count - 1
                }
                return .suppress(nil)
            }
            return .pass
        }
    }

    /// Clears transient pending-keyUp pairing without touching mode or chord.
    /// Called by the tap layer whenever events were observed that never passed
    /// through the gate (tap disabled by timeout/user input, fresh start), so
    /// stale entries cannot orphan-suppress an unrelated future keyUp.
    func resetTransientState() {
        state.withLock { st in
            st.pendingKeyUps = [:]
        }
    }

    func evaluateOther(_ kind: OtherInputKind) -> InputDecision {
        _ = kind
        return state.withLock { st in
            guard st.mode == .hintCapture else { return .pass }
            st.mode = .activationOnly
            return InputDecision(suppress: false, intent: .cancelHintMode)
        }
    }

    // MARK: - Private

    private func matchesChord(st: inout State, keyCode: UInt64, masked: CGEventFlags) -> Bool {
        masked == st.chord.requiredFlags && keyCode == st.chord.keyCode
    }

    private func evaluateKeyDownActivationOnly(st: inout State, keyCode: UInt64, masked: CGEventFlags, isAutoRepeat: Bool) -> InputDecision {
        guard matchesChord(st: &st, keyCode: keyCode, masked: masked) else { return .pass }
        if isAutoRepeat {
            // Autorepeat of the activation chord is ignored entirely:
            // suppressed silently, no new intent emitted.
            return .suppress(nil)
        }
        st.pendingKeyUps[keyCode, default: 0] += 1
        return .suppress(.activateHintMode)
    }

    private func evaluateKeyDownHintCapture(st: inout State, keyCode: UInt64, masked: CGEventFlags, isAutoRepeat: Bool) -> InputDecision {
        // Bare Escape cancels capture mode (consumed). A modified Escape is
        // a target-app shortcut: fall through to the modifier branch so the
        // session cancels but the key reaches the app.
        if keyCode == VimotionKeys.escapeKeyCode, masked == [] {
            st.mode = .activationOnly
            st.pendingKeyUps[keyCode, default: 0] += 1
            return .suppress(.cancelHintMode)
        }
        // Bare Backspace is consumed but keeps capture alive. Modified
        // Delete (e.g. Cmd+Delete = delete-line) belongs to the app.
        if keyCode == VimotionKeys.backspaceKeyCode, masked == [] {
            st.pendingKeyUps[keyCode, default: 0] += 1
            return .suppress(.backspace)
        }
        // Activation chord toggles hint mode off (consumed). Autorepeat of the
        // chord is swallowed without emitting another toggle intent.
        if matchesChord(st: &st, keyCode: keyCode, masked: masked) {
            if isAutoRepeat { return .suppress(nil) }
            st.pendingKeyUps[keyCode, default: 0] += 1
            st.mode = .activationOnly
            return .suppress(.cancelHintMode)
        }
        // Any modifier chord (masked flags non-empty) is a shortcut for the
        // target app: cancel capture atomically, pass through unchanged.
        if masked != [] {
            st.mode = .activationOnly
            return InputDecision(suppress: false, intent: .cancelHintMode)
        }
        // Bare letter key within the configured alphabet → hint key input
        // (consumed; its keyUp must be swallowed too).
        if let key = PhysicalKey(cgKeyCode: keyCode) {
            // A letter outside the configured alphabet is not hint input:
            // exit capture atomically and pass it through like an
            // unrecognized key (plan §3.26). Its autorepeats must pass too,
            // since the gate never swallowed the initial press.
            guard st.configuredHintKeyCodes.contains(keyCode) else {
                st.mode = .activationOnly
                return InputDecision(suppress: false, intent: .cancelHintMode)
            }
            // Autorepeat of a held letter floods the prefix with
            // guaranteed zero-match repeats: suppress silently, like the
            // chord branch. The keyUp is already paired by the initial press.
            if isAutoRepeat { return .suppress(nil) }
            st.pendingKeyUps[keyCode, default: 0] += 1
            return .suppress(.hintKey(key))
        }
        // Unrecognized ordinary key: atomically exit capture, pass through,
        // asynchronously cancel hint mode.
        st.mode = .activationOnly
        return InputDecision(suppress: false, intent: .cancelHintMode)
    }
}
