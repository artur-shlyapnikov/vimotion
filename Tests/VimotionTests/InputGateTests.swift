import XCTest
import CoreGraphics
@testable import Vimotion

final class InputGateTests: XCTestCase {

    private let chord = ActivationChord(
        keyCode: VimotionKeys.spaceKeyCode,
        requiredFlags: [.maskCommand, .maskShift]
    )

    private func makeGate(mode: GateMode = .activationOnly) -> InputGate {
        let gate = InputGate()
        gate.activationChord = chord
        gate.mode = mode
        return gate
    }

    /// Caps lock / numeric-pad / function / device bits are ignored in chord matching.
    private static let extraneousBits: [CGEventFlags] = [
        [.maskAlphaShift],
        [.maskNumericPad],
        [.maskSecondaryFn],
        [.maskNonCoalesced],
        [.maskAlphaShift, .maskNumericPad, .maskSecondaryFn, .maskNonCoalesced],
    ]

    // MARK: - Activation (idle)

    func testActivationChordFiresExactlyOnceAndSuppresses() {
        let gate = makeGate()
        let d = gate.evaluateKeyDown(keyCode: chord.keyCode, flags: chord.requiredFlags, isAutoRepeat: false)
        XCTAssertEqual(d, InputDecision(suppress: true, intent: .activateHintMode))
    }

    func testActivationAutoRepeatIgnoredSilently() {
        let gate = makeGate()
        _ = gate.evaluateKeyDown(keyCode: chord.keyCode, flags: chord.requiredFlags, isAutoRepeat: false)
        for _ in 0..<5 {
            let repeatDecision = gate.evaluateKeyDown(keyCode: chord.keyCode, flags: chord.requiredFlags, isAutoRepeat: true)
            XCTAssertTrue(repeatDecision.suppress)
            XCTAssertNil(repeatDecision.intent, "autorepeat must not re-emit activation intent")
        }
    }

    func testWrongKeyOrFlagsDoNotActivate() {
        let gate = makeGate()
        XCTAssertEqual(gate.evaluateKeyDown(keyCode: PhysicalKey.a.cgKeyCode, flags: chord.requiredFlags, isAutoRepeat: false), .pass)
        XCTAssertEqual(gate.evaluateKeyDown(keyCode: chord.keyCode, flags: [.maskCommand], isAutoRepeat: false), .pass)
        XCTAssertEqual(gate.evaluateKeyDown(keyCode: chord.keyCode, flags: [], isAutoRepeat: false), .pass)
    }

    func testExtraneousFlagBitsStillMatchChord() {
        for extra in Self.extraneousBits {
            let gate = makeGate()
            let d = gate.evaluateKeyDown(keyCode: chord.keyCode, flags: chord.requiredFlags.union(extra), isAutoRepeat: false)
            XCTAssertEqual(d.intent, .activateHintMode, "extra bits \(extra.rawValue)")
            XCTAssertTrue(d.suppress)
        }
    }

    func testKeyUpOfSwallowedActivationIsSuppressed() {
        let gate = makeGate()
        _ = gate.evaluateKeyDown(keyCode: chord.keyCode, flags: chord.requiredFlags, isAutoRepeat: false)
        let up = gate.evaluateKeyUp(keyCode: chord.keyCode, flags: [])
        XCTAssertTrue(up.suppress)
        XCTAssertNil(up.intent)
        // Only one keyUp is paired; a second identical keyUp passes through.
        XCTAssertEqual(gate.evaluateKeyUp(keyCode: chord.keyCode, flags: []), .pass)
    }

    // MARK: - Hint capture

    func testHintKeyProducesHintIntentAndIsConsumed() {
        let gate = makeGate(mode: .hintCapture)
        for key in PhysicalKey.defaultAlphabetOrder.prefix(6) {
            let d = gate.evaluateKeyDown(keyCode: key.cgKeyCode, flags: [], isAutoRepeat: false)
            XCTAssertEqual(d, InputDecision(suppress: true, intent: .hintKey(key)))
            // Matching keyUp of a consumed keyDown must also be suppressed.
            XCTAssertTrue(gate.evaluateKeyUp(keyCode: key.cgKeyCode, flags: []).suppress)
        }
    }

    /// A held letter must not flood the prefix with zero-match autorepeats:
    /// repeat keyDowns are suppressed silently (no intent), stay in capture,
    /// and the single initial press still owns the keyUp.
    func testHintKeyAutoRepeatSuppressedSilentlyWithoutIntent() {
        let gate = makeGate(mode: .hintCapture)
        let key = PhysicalKey.a

        // Initial press emits the intent and registers the keyUp pairing.
        let first = gate.evaluateKeyDown(keyCode: key.cgKeyCode, flags: [], isAutoRepeat: false)
        XCTAssertEqual(first, InputDecision(suppress: true, intent: .hintKey(key)))

        // Autorepeats: consumed, but no intent and capture stays alive.
        for _ in 0..<5 {
            let repeat_ = gate.evaluateKeyDown(keyCode: key.cgKeyCode, flags: [], isAutoRepeat: true)
            XCTAssertEqual(repeat_, .suppress(nil))
            XCTAssertEqual(gate.mode, .hintCapture)
        }

        // The initial press already covers the keyUp — still suppressed.
        XCTAssertTrue(gate.evaluateKeyUp(keyCode: key.cgKeyCode, flags: []).suppress)
    }

    func testEscapeCancelsAndIsConsumed() {
        let gate = makeGate(mode: .hintCapture)
        let d = gate.evaluateKeyDown(keyCode: VimotionKeys.escapeKeyCode, flags: [], isAutoRepeat: false)
        XCTAssertEqual(d, InputDecision(suppress: true, intent: .cancelHintMode))
        XCTAssertEqual(gate.mode, .activationOnly)
    }

    func testBackspaceIsConsumedButKeepsCapture() {
        let gate = makeGate(mode: .hintCapture)
        let d = gate.evaluateKeyDown(keyCode: VimotionKeys.backspaceKeyCode, flags: [], isAutoRepeat: false)
        XCTAssertEqual(d, InputDecision(suppress: true, intent: .backspace))
        XCTAssertEqual(gate.mode, .hintCapture)
    }

    func testActivationChordInCaptureTogglesOffAndIsSuppressed() {
        let gate = makeGate(mode: .hintCapture)
        let d = gate.evaluateKeyDown(keyCode: chord.keyCode, flags: chord.requiredFlags, isAutoRepeat: false)
        XCTAssertEqual(d, InputDecision(suppress: true, intent: .cancelHintMode))
        XCTAssertEqual(gate.mode, .activationOnly)
        XCTAssertTrue(gate.evaluateKeyUp(keyCode: chord.keyCode, flags: []).suppress)
    }

    func testUnknownPlainKeyExitsCaptureAtomicallyPassesAndCancels() {
        let gate = makeGate(mode: .hintCapture)
        let d = gate.evaluateKeyDown(keyCode: 0x24, flags: [], isAutoRepeat: false) // Return key, not a hint letter
        XCTAssertFalse(d.suppress)
        XCTAssertEqual(d.intent, .cancelHintMode)
        XCTAssertEqual(gate.mode, .activationOnly, "mode must flip atomically with the pass-through decision")
    }

    func testShortcutWithModifiersInCaptureCancelsAndPassesUnchanged() {
        let shortcutFlagSets: [[CGEventFlags]] = [
            [.maskCommand], [.maskControl], [.maskAlternate],
            [.maskCommand, .maskShift], [.maskShift],
        ]
        for flags in shortcutFlagSets {
            let gate = makeGate(mode: .hintCapture)
            let d = gate.evaluateKeyDown(keyCode: PhysicalKey.x.cgKeyCode, flags: CGEventFlags(rawValue: flags.map({ $0.rawValue }).reduce(0, |)), isAutoRepeat: false)
            XCTAssertFalse(d.suppress, "flags \(flags)")
            XCTAssertEqual(d.intent, .cancelHintMode, "flags \(flags)")
            XCTAssertEqual(gate.mode, .activationOnly, "flags \(flags)")
        }
    }

    // MARK: - Other input kinds

    func testMouseAndScrollCancelCaptureAndPassThrough() {
        for kind in [OtherInputKind.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel] {
            let gate = makeGate(mode: .hintCapture)
            let d = gate.evaluateOther(kind)
            XCTAssertFalse(d.suppress)
            XCTAssertEqual(d.intent, .cancelHintMode)
            XCTAssertEqual(gate.mode, .activationOnly)
        }
    }

    func testMouseAndScrollPassInIdle() {
        for kind in [OtherInputKind.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel] {
            let gate = makeGate()
            XCTAssertEqual(gate.evaluateOther(kind), .pass)
            XCTAssertEqual(gate.mode, .activationOnly)
        }
    }

    // MARK: - Orphan keyUp invariant (property-style across sequences)

    /// After any interleaving of keyDown/keyUp/other/mode-mutation events,
    /// a keyUp is suppressed if and only if its keyDown was swallowed by the
    /// gate — so a target app can never receive an orphan keyUp.
    func testNoOrphanKeyUpReachesTargetAfterSuppressedKeyDown() {
        var generator = SeededGenerator(seed: 0x56_69_6D_6F_74_69_6F_6E) // "Vimotion", fixed seed = reproducible
        var pending = Set<UInt64>()
        for _ in 0..<2000 {
            let gate = makeGate(mode: generator.next(upperBound: 2) == 0 ? .activationOnly : .hintCapture)
            pending.removeAll()
            for _ in 0..<32 {
                switch generator.next(upperBound: 4) {
                case 0:
                    let keyCode = UInt64(generator.next(upperBound: 0x40))
                    let flags = CGEventFlags(rawValue: generator.next(upperBound: 0xFF_FFFF))
                    let down = gate.evaluateKeyDown(keyCode: keyCode, flags: flags, isAutoRepeat: false)
                    if down.suppress { pending.insert(keyCode) }
                case 1:
                    let keyCode = UInt64(generator.next(upperBound: 0x40))
                    if gate.evaluateKeyUp(keyCode: keyCode, flags: []).suppress {
                        XCTAssertTrue(pending.contains(keyCode), "orphan keyUp suppressed for \(keyCode)")
                        pending.remove(keyCode)
                    } else {
                        XCTAssertFalse(pending.contains(keyCode), "pending keyUp \(keyCode) leaked to target app")
                    }
                case 2:
                    let kinds: [OtherInputKind] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
                    _ = gate.evaluateOther(kinds[Int(generator.next(upperBound: 4))])
                default:
                    gate.mode = generator.next(upperBound: 2) == 0 ? .activationOnly : .hintCapture
                }
            }
        }
    }

    // MARK: - Thread safety smoke

    func testConcurrentMutationFromMultipleThreadsIsSafe() async {
        let gate = makeGate()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<16 {
                group.addTask(priority: .userInitiated) { [chord] in
                    for step in 0..<500 {
                        let capture = (i + step).isMultiple(of: 2)
                        gate.mode = capture ? .hintCapture : .activationOnly
                        if capture {
                            _ = gate.evaluateKeyDown(keyCode: PhysicalKey.allCases[step % 26].cgKeyCode, flags: [], isAutoRepeat: false)
                        } else {
                            _ = gate.evaluateKeyDown(keyCode: chord.keyCode, flags: chord.requiredFlags, isAutoRepeat: false)
                        }
                        _ = gate.evaluateKeyUp(keyCode: chord.keyCode, flags: [])
                        _ = gate.activationChord
                        _ = gate.mode
                    }
                }
            }
        }
        // Must terminate without crashing; mode holds a valid value.
        switch gate.mode {
        case .activationOnly, .hintCapture:
            break
        }
    }

    func testChordPropertyRoundTrip() {
        let gate = InputGate()
        let custom = ActivationChord(keyCode: 0x2F, requiredFlags: [.maskControl])
        gate.activationChord = custom
        XCTAssertEqual(gate.activationChord, custom)
    }

    // MARK: - resetTransientState

    func testResetTransientStateReleasesSwallowedKeyUpAndKeepsModeAndChord() {
        let gate = makeGate(mode: .activationOnly)
        _ = gate.evaluateKeyDown(keyCode: chord.keyCode, flags: chord.requiredFlags, isAutoRepeat: false)
        XCTAssertTrue(gate.evaluateKeyUp(keyCode: chord.keyCode, flags: []).suppress)

        // Swallow again, then simulate a wedged-tap reset (plan §3.17):
        // the pended keyUp must pass instead of orphan-suppressing.
        let modeBeforeReset = gate.mode
        _ = gate.evaluateKeyDown(keyCode: chord.keyCode, flags: chord.requiredFlags, isAutoRepeat: false)
        gate.resetTransientState()
        XCTAssertFalse(
            gate.evaluateKeyUp(keyCode: chord.keyCode, flags: []).suppress,
            "resetTransientState must clear pendingKeyUps"
        )
        XCTAssertEqual(
            gate.mode, modeBeforeReset,
            "mode is untouched by the reset (the .activateHintMode intent owns the transition)"
        )
        XCTAssertEqual(gate.activationChord, chord, "chord is untouched by the reset")
    }

    func testResetTransientStateInHintCaptureKeepsCaptureAlive() {
        let gate = makeGate(mode: .hintCapture)
        let letter = PhysicalKey.s.cgKeyCode
        _ = gate.evaluateKeyDown(keyCode: letter, flags: [], isAutoRepeat: false)
        gate.resetTransientState()
        XCTAssertEqual(gate.mode, .hintCapture, "capture mode survives the reset")
        XCTAssertFalse(gate.evaluateKeyUp(keyCode: letter, flags: []).suppress)
    }

    // MARK: - Pass-through decisions carry intents

    /// Pass-through decisions must carry a non-nil intent so the tap layer
    /// dispatches it even though the event itself is not suppressed.
    func testPassThroughDecisionsCarryCancelIntent() {
        let otherGate = makeGate(mode: .hintCapture)
        let other = otherGate.evaluateOther(.scrollWheel)
        XCTAssertFalse(other.suppress)
        XCTAssertEqual(other.intent, .cancelHintMode)

        let modifierGate = makeGate(mode: .hintCapture)
        let modifier = modifierGate.evaluateKeyDown(
            keyCode: PhysicalKey.x.cgKeyCode, flags: [.maskCommand], isAutoRepeat: false
        )
        XCTAssertFalse(modifier.suppress)
        XCTAssertEqual(modifier.intent, .cancelHintMode)

        let unrecognizedGate = makeGate(mode: .hintCapture)
        let unrecognized = unrecognizedGate.evaluateKeyDown(
            keyCode: 0x24, flags: [], isAutoRepeat: false // Return key
        )
        XCTAssertFalse(unrecognized.suppress)
        XCTAssertEqual(unrecognized.intent, .cancelHintMode)
    }

    // MARK: - Configured hint alphabet

    func testDefaultConfiguredHintKeyCodesCoverEveryPhysicalLetter() {
        XCTAssertEqual(
            InputGate().configuredHintKeyCodes,
            Set(PhysicalKey.allCases.map(\.cgKeyCode))
        )
    }

    func testLetterOutsideConfiguredAlphabetPassesThroughAndCancelsWithoutPendingKeyUp() {
        let gate = makeGate(mode: .hintCapture)
        gate.configuredHintKeyCodes = Set(PhysicalKey.allCases.map(\.cgKeyCode))
            .subtracting([PhysicalKey.a.cgKeyCode])

        let d = gate.evaluateKeyDown(keyCode: PhysicalKey.a.cgKeyCode, flags: [], isAutoRepeat: false)
        XCTAssertFalse(d.suppress)
        XCTAssertEqual(d.intent, .cancelHintMode)
        XCTAssertEqual(gate.mode, .activationOnly)
        XCTAssertFalse(
            gate.evaluateKeyUp(keyCode: PhysicalKey.a.cgKeyCode, flags: []).suppress,
            "a passed-through letter must not pend an orphan keyUp"
        )
    }

    func testLetterInsideConfiguredAlphabetStillSuppressesWithHintIntent() {
        let gate = makeGate(mode: .hintCapture)
        gate.configuredHintKeyCodes = [PhysicalKey.s.cgKeyCode]

        let d = gate.evaluateKeyDown(keyCode: PhysicalKey.s.cgKeyCode, flags: [], isAutoRepeat: false)
        XCTAssertEqual(d, InputDecision(suppress: true, intent: .hintKey(.s)))
        XCTAssertTrue(gate.evaluateKeyUp(keyCode: PhysicalKey.s.cgKeyCode, flags: []).suppress)
    }
}

/// Small deterministic PRNG so the orphan-keyUp property test is reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private extension RandomNumberGenerator {
    mutating func next(upperBound bound: UInt64) -> UInt64 {
        next() % bound
    }
}
