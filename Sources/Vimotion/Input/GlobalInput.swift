import CoreGraphics
import Foundation

/// The user-configurable activation shortcut.
///
/// This value belongs to the input boundary rather than to the lock-protected
/// decision engine, so settings and presentation code can describe the same
/// shortcut without depending on `InputGate`.
struct ActivationChord: Sendable, Equatable {
    var keyCode: UInt64
    var requiredFlags: CGEventFlags
}

/// Keycodes for non-letter keys used by the input boundary and its settings
/// presentation. ANSI virtual keycodes are stable across input sources.
enum VimotionKeys {
    static let escapeKeyCode: UInt64 = 0x35
    static let backspaceKeyCode: UInt64 = 0x33
    static let spaceKeyCode: UInt64 = 0x31
}

/// Application-facing owner of global keyboard input.
///
/// `InputGate` remains the synchronous, lock-protected decision engine used by
/// the event-tap callback. This façade owns both pieces of the boundary and
/// keeps gate modes and configured keycode sets out of the composition and UI
/// layers.
@MainActor
final class GlobalInput {
    private let gate: InputGate
    private let eventTap: KeyboardEventTap

    convenience init(intentHandler: @escaping @MainActor (InputIntent) -> Void) {
        self.init(gate: InputGate(), intentHandler: intentHandler)
    }

    /// Internal injection seam for Hint Mode tests. Production code uses the
    /// initializer above so this façade remains the owner of the decision
    /// engine and event tap.
    init(gate: InputGate,
         intentHandler: @escaping @MainActor (InputIntent) -> Void = { _ in }) {
        self.gate = gate
        self.eventTap = KeyboardEventTap(gate: gate, intentHandler: intentHandler)
    }

    /// Applies the complete input policy as one boundary operation.
    func configure(activationChord: ActivationChord, alphabet: [PhysicalKey]) {
        gate.configure(
            activationChord: activationChord,
            configuredHintKeyCodes: Set(alphabet.map(\.cgKeyCode))
        )
    }

    func beginHintCapture() {
        gate.beginHintCapture()
    }

    func endHintCapture() {
        gate.endHintCapture()
    }

    func start() throws {
        try eventTap.start()
    }

    func stop() {
        eventTap.stop()
    }

    var isRunning: Bool {
        eventTap.isRunning
    }

    /// Compatibility bridge for the existing HintModeController seam. The
    /// controller receives this same engine instance; all input configuration
    /// and tap lifecycle remain owned by this façade.
    func withDecisionEngine<Result>(_ body: (InputGate) -> Result) -> Result {
        body(gate)
    }
}
