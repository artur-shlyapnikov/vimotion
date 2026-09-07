// KeyboardEventTap.swift — session-wide CGEventTap pump (plan §3.17).
//
// Owns one dedicated Thread running its own CFRunLoop so the tap callback
// never shares a run loop with the main thread. The callback is strictly
// synchronous and lock-guarded: it consults the shared InputGate (unfair-lock
// protected) and hops intents to the MainActor via DispatchQueue.main.async;
// it never touches MainActor state directly.
//
// Suppression rule: a nil return from the callback suppresses the event; a
// non-nil intent dispatches to the registered MainActor handler regardless of
// whether the decision suppresses or passes the event through.
//
// Resilience: when the system disables the tap (.tapDisabledBy* arrives with
// a nil event) the callback re-enables it with CGEvent.tapEnable(_:true).

import ApplicationServices
import CoreGraphics
import Foundation
import os

enum KeyboardEventTapError: Error, Equatable {
    /// Accessibility trust missing; tap creation cannot succeed.
    case accessibilityNotGranted
    /// Trusted, but tap creation still returned nil (e.g. session tap limit).
    case tapCreationFailed
    /// start() timed out waiting for the tap thread readiness signal.
    case tapStartTimedOut
}

final class KeyboardEventTap: @unchecked Sendable {

    /// Opaque wrapper letting CoreFoundation handles cross @Sendable lock
    /// boundaries. Safety comes from confinement behind `stateLock`.
    private final class Handle<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private struct HandlerBox: @unchecked Sendable {
        let handler: @MainActor (InputIntent) -> Void
    }

    // All CF handles live only on the dedicated tap thread; every access is
    // serialized by the unfair lock below.
    private struct TapState {
        var tap: Handle<CFMachPort>?
        var runLoopSource: Handle<CFRunLoopSource>?
        var runLoop: Handle<CFRunLoop>?
        var stopSignal = DispatchSemaphore(value: 0)
        var creationError: (any Error)?
        /// Set by stop() before the tap thread finishes installing handles;
        /// a wedged/slow creation must then discard its tap instead of
        /// leaking an unowned live mach port.
        var stopping = false
    }

    private let gate: InputGate
    private let handlerBox: HandlerBox
    private let stateLock = OSAllocatedUnfairLock<TapState>(initialState: TapState())

    /// True iff a tap exists and the system currently has it enabled.
    var isRunning: Bool {
        let boxed = stateLock.withLock { $0.tap }
        guard let boxed else { return false }
        return CGEvent.tapIsEnabled(tap: boxed.value)
    }

    init(gate: InputGate, intentHandler: @escaping @MainActor (InputIntent) -> Void) {
        self.gate = gate
        self.handlerBox = HandlerBox(handler: intentHandler)
    }

    // MARK: - Lifecycle

    /// Creates the tap on a dedicated thread and parks it in CFRunLoopRun.
    /// Throws typed errors when Accessibility is missing or creation fails.
    func start() throws {
        guard AXIsProcessTrusted() else {
            throw KeyboardEventTapError.accessibilityNotGranted
        }
        let alreadyRunning: Bool = stateLock.withLock { state in
            // already started: idempotent — a second start() must not spawn a
            // duplicate tap thread (plan §3.17 lifecycle).
            guard state.tap == nil else { return true }
            state.creationError = nil
            state.stopSignal = DispatchSemaphore(value: 0)
            state.stopping = false
            return false
        }
        if alreadyRunning { return }

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.runTapThread(signalling: ready)
        }
        thread.name = "local.vimotion.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()

        let waited = ready.wait(timeout: .now() + 5)
        let failure: (any Error)? = stateLock.withLock { state in
            if let creationError = state.creationError { return creationError }
            // A slow-but-successful creation is a timeout, not a creation
            // failure: stop() then tears the late tap down properly since
            // state.tap != nil.
            if waited != .success { return KeyboardEventTapError.tapStartTimedOut }
            if state.tap == nil { return KeyboardEventTapError.tapCreationFailed }
            return nil
        }
        if let failure {
            // Tear down whatever the (possibly slow) tap thread already
            // created so a timed-out start never leaks a live mach port.
            stop()
            throw failure
        }
        gate.resetTransientState()
        AppLogger.input.info("event tap started")
    }

    /// Removes the tap, stops the run loop, and joins the thread (bounded).
    func stop() {
        let (tap, loop): (Handle<CFMachPort>?, Handle<CFRunLoop>?) = stateLock.withLock { state in
            // Flag first: a creation thread still wedged inside tapCreate()
            // must see this when it finally installs its handles.
            state.stopping = true
            defer {
                state.tap = nil
                state.runLoop = nil
                state.runLoopSource = nil
                state.creationError = nil
            }
            return (state.tap, state.runLoop)
        }
        guard tap != nil || loop != nil else { return }
        // Tearing down the tap's mach port detaches it from all run loops;
        // there is no separate CGEventTapRemove entry point in this SDK.
        if let tap { CFMachPortInvalidate(tap.value) }
        if let loop { CFRunLoopStop(loop.value) }
        let joined = stateLock.withLock { $0.stopSignal }
        _ = joined.wait(timeout: .now() + 3)
        AppLogger.input.info("event tap stopped")
    }

    // MARK: - Tap thread

    private func runTapThread(signalling ready: DispatchSemaphore) {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)

        guard let machPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            stateLock.withLock { $0.creationError = KeyboardEventTapError.tapCreationFailed }
            ready.signal()
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0) else {
            CFMachPortInvalidate(machPort)
            stateLock.withLock { $0.creationError = KeyboardEventTapError.tapCreationFailed }
            ready.signal()
            return
        }
        guard let loop = CFRunLoopGetCurrent() else {
            CFMachPortInvalidate(machPort)
            stateLock.withLock { $0.creationError = KeyboardEventTapError.tapCreationFailed }
            ready.signal()
            return
        }
        CFRunLoopAddSource(loop, source, CFRunLoopMode.defaultMode)

        let tapHandle = Handle(machPort)
        let loopHandle = Handle(loop)
        let sourceHandle = Handle(source)
        let install: Bool = stateLock.withLock { state in
            // stop() ran while tapCreate() was wedged: install nothing, or
            // this thread's tap would run forever as an unowned live tap.
            if state.stopping {
                return false
            }
            state.tap = tapHandle
            state.runLoop = loopHandle
            state.runLoopSource = sourceHandle
            return true
        }
        ready.signal()
        guard install else {
            CFMachPortInvalidate(machPort)
            stateLock.withLock { _ = $0.stopSignal.signal() }
            return
        }
        CFRunLoopRun()
        CFRunLoopRemoveSource(loop, source, CFRunLoopMode.defaultMode)
        stateLock.withLock { _ = $0.stopSignal.signal() }
    }

    // MARK: - Callback

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let owner = Unmanaged<KeyboardEventTap>.fromOpaque(userInfo).takeUnretainedValue()
        return owner.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByUserInput, .tapDisabledByTimeout:
            // The system dropped our tap; re-enable and swallow the trigger.
            // Events observed while disabled bypassed the gate entirely, so
            // its pending-keyUp pairing may be stale — reset it (plan §3.17).
            let tap = stateLock.withLock { $0.tap }
            if let tap {
                CGEvent.tapEnable(tap: tap.value, enable: true)
                gate.resetTransientState()
            }
            return nil
        default:
            break
        }

        let decision: InputDecision
        switch type {
        case .keyDown:
            decision = gate.evaluateKeyDown(
                keyCode: keyCode(of: event),
                flags: event.flags,
                isAutoRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            )
        case .keyUp:
            decision = gate.evaluateKeyUp(keyCode: keyCode(of: event), flags: event.flags)
        case .leftMouseDown:
            decision = gate.evaluateOther(.leftMouseDown)
        case .rightMouseDown:
            decision = gate.evaluateOther(.rightMouseDown)
        case .otherMouseDown:
            decision = gate.evaluateOther(.otherMouseDown)
        case .scrollWheel:
            decision = gate.evaluateOther(.scrollWheel)
        default:
            // flagsChanged and anything unmasked pass through untouched; the
            // gate consumes the flags carried by each keyDown/keyUp event.
            return Unmanaged.passUnretained(event)
        }

        // Non-nil intents reach the MainActor handler regardless of
        // suppression: pass-through decisions like .cancelHintMode must
        // still cancel hint mode (plan §3.17).
        if let intent = decision.intent {
            let box = handlerBox
            DispatchQueue.main.async {
                MainActor.assumeIsolated { box.handler(intent) }
            }
        }
        if decision.suppress {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func keyCode(of event: CGEvent) -> UInt64 {
        UInt64(bitPattern: event.getIntegerValueField(.keyboardEventKeycode))
    }
}
