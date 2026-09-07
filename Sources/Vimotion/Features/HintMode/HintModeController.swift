// HintModeController.swift — sole owner of Hint Mode session state (plan §3.15).
//
// Concurrency model: `handle(_:)` is the only entry point (event-tap dispatch
// hops to MainActor). The loading pipeline runs as a single Task that inherits
// MainActor isolation; every await hop re-checks the generation token and the
// expected state case, so late results are discarded silently.
//
// Error invariant (plan §3.29): every failure path leaves overlay hidden,
// input gate back to activationOnly, and state == idle — the HUD is shown
// only after the invariant has been applied.

import Foundation

@MainActor
final class HintModeController {

    // MARK: Frozen constants

    /// Historical test seam; timeout policy now lives in HintSessionBackend.
    static var scanTimeout: Duration {
        get { HintSessionBackend.scanTimeout }
        set { HintSessionBackend.scanTimeout = newValue }
    }
    /// Hint-session idle timeout since last accepted hint key. Test-overridable.
    static var idleTimeout: Duration = .seconds(10)

    // HUD copy is frozen user-visible text.
    static let hudDriverUnavailable = "Cua Driver unavailable"
    static let hudAccessibilityRequired = "Cua Accessibility required"
    static let hudScanTimedOut = "UI scan timed out"
    static let hudNoActionableElements = "No actionable elements"
    static let hudTargetChanged = "Target changed"
    static let hudIdleCancelled = "Idle timeout"
    // OSSignposter requires StaticString literals.
    private static let spTargetsToOverlay: StaticString = "targets_to_overlay"
    private static let spKeyToClick: StaticString = "key_to_click"

    // MARK: Dependencies

    private let backend: HintSessionBackend
    private let input: GlobalInput
    private let overlay: OverlayCoordinator

    // MARK: State

    private(set) var state: HintModeState = .idle

    /// Monotonic session token: bumped on every activation and every cancel,
    /// checked after every async hop.
    private var generation: UInt64 = 0

    private var loadTask: Task<Void, Never>?
    private var clickTask: Task<Void, Never>?
    private var idleTimeoutTask: Task<Void, Never>?

    init(backend: HintSessionBackend,
         overlay: OverlayCoordinator,
         input: GlobalInput) {
        self.backend = backend
        self.overlay = overlay
        self.input = input
    }

    convenience init(serving: any CuaDriverServing,
                     resolver: WindowTargetResolver,
                     overlay: OverlayCoordinator,
                     input: GlobalInput,
                     settings: SettingsStore) {
        self.init(
            backend: HintSessionBackend(
                serving: serving,
                resolver: resolver,
                settings: settings
            ),
            overlay: overlay,
            input: input
        )
    }

    /// Compatibility seam for the existing composition root and focused
    /// tests. Production composition uses the GlobalInput façade directly;
    /// this overload keeps tests that inspect the synchronous gate behavior
    /// source-compatible without making that engine the controller API.
    convenience init(serving: any CuaDriverServing,
         resolver: WindowTargetResolver,
         overlay: OverlayCoordinator,
         gate: InputGate,
         settings: SettingsStore) {
        self.init(
            backend: HintSessionBackend(
                serving: serving,
                resolver: resolver,
                settings: settings
            ),
            overlay: overlay,
            input: GlobalInput(gate: gate) { _ in }
        )
    }

    deinit {
        loadTask?.cancel()
        clickTask?.cancel()
        idleTimeoutTask?.cancel()
    }

    // MARK: Entry point

    func handle(_ intent: InputIntent) {
        switch intent {
        case .activateHintMode:
            switch state {
            case .idle:
                startLoading()
            case .loading, .active, .executing:
                cancelToIdle(hudText: nil)  // repeated activation = toggle-cancel
            }
        case .cancelHintMode:
            cancelToIdle(hudText: nil)
        case .hintKey(let key):
            handleKey(key)
        case .backspace:
            handleBackspace()
        }
    }

    // MARK: Lifecycle callbacks

    func frontmostAppDidChange() {
        guard !isIdle else { return }
        cancelToIdle(hudText: nil)
    }

    func screensDidChange() {
        if !isIdle {
            cancelToIdle(hudText: nil)
        }
        overlay.destroyPanels()
    }

    func shutdown() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        clickTask?.cancel()
        clickTask = nil
        idleTimeoutTask?.cancel()
        idleTimeoutTask = nil
        input.endHintCapture()
        overlay.hideImmediately()
        state = .idle
    }

    // MARK: Activation → loading pipeline

    private func startLoading() {
        generation += 1
        let gen = generation
        let startedAt = ContinuousClock.now
        input.beginHintCapture()  // immediately, before any await
        state = .loading(generation: gen, bufferedKeys: [], startedAt: startedAt)
        loadTask = Task { [weak self] in
            await self?.runLoadPipeline(generation: gen, startedAt: startedAt)
        }
    }

    private func runLoadPipeline(generation gen: UInt64, startedAt: ContinuousClock.Instant) async {
        guard generation == gen else { return }

        let loaded: HintSessionLoad
        do {
            loaded = try await backend.loadSession()
        } catch let error as HintSessionBackendError where error == .noActionableElements {
            // Keep the historical empty-tree transition: it bumps the
            // generation before showing the HUD, so no late scan result can
            // belong to the retired loading session.
            cancelToIdle(hudText: Self.hudNoActionableElements)
            return
        } catch {
            failSession(hudText(for: error), generation: gen)
            return
        }
        guard generation == gen else { return }

        let window = loaded.window
        let targets = loaded.targets

        // Layout orchestration belongs to the overlay feature boundary.
        do {
            let interval = PerformanceMetrics.signposter.beginInterval(Self.spTargetsToOverlay)
            defer { PerformanceMetrics.signposter.endInterval(Self.spTargetsToOverlay, interval) }
            overlay.present(targets: targets)
        }
        guard generation == gen else { return }

        let buffered = bufferedKeys(generation: gen)

        let session = HintSession(
            generation: gen,
            targetWindow: window,
            snapshotID: loaded.snapshotID,
            targets: targets,
            typedPrefix: [],
            startedAt: startedAt
        )
        state = .active(session)
        scheduleIdleTimeout()
        AppLogger.hint.info("hint session active gen=\(gen) pid=\(window.pid) window=\(window.windowID) targets=\(targets.count)")

        // Replay keys buffered during loading through normal prefix processing.
        for key in buffered {
            guard generation == gen, case .active = state else { break }
            handleKeyInActive(key)
        }
    }

    private func bufferedKeys(generation gen: UInt64) -> [PhysicalKey] {
        guard case .loading(let loadedGen, let buffered, _) = state, loadedGen == gen else { return [] }
        return buffered
    }

    // MARK: Key handling

    private func handleKey(_ key: PhysicalKey) {
        guard backend.acceptsHintKey(key) else { return }  // membership check
        switch state {
        case .loading(let gen, var buffered, let startedAt) where gen == generation:
            buffered.append(key)
            state = .loading(generation: gen, bufferedKeys: buffered, startedAt: startedAt)
        case .active:
            handleKeyInActive(key)
        case .idle, .executing, .loading:
            break
        }
    }

    private func handleBackspace() {
        switch state {
        case .loading(let gen, var buffered, let startedAt) where gen == generation:
            if !buffered.isEmpty { buffered.removeLast() }
            state = .loading(generation: gen, bufferedKeys: buffered, startedAt: startedAt)
        case .active(var session):
            guard !session.typedPrefix.isEmpty else { return }
            session.typedPrefix.removeLast()
            state = .active(session)
            let matches = matchedTargetIndexes(prefix: session.typedPrefix, targets: session.targets)
            overlay.applyPrefix(session.typedPrefix, matchedTargetIndexes: matches)
        case .idle, .executing, .loading:
            break
        }
    }

    private func handleKeyInActive(_ key: PhysicalKey) {
        guard case .active(var session) = state else { return }
        session.typedPrefix.append(key)

        let matches = matchedTargetIndexes(prefix: session.typedPrefix, targets: session.targets)

        if matches.count == 1, let only = matches.first,
           session.targets[only].hintCode.keys == session.typedPrefix {
            state = .active(session)
            execute(session.targets[only])
            return
        }

        if !matches.isEmpty {
            state = .active(session)
            overlay.applyPrefix(session.typedPrefix, matchedTargetIndexes: matches)
            scheduleIdleTimeout()  // accepted prefix key resets idle timer
        } else {
            // Zero matches: flash, remove ONLY the last key, stay active.
            session.typedPrefix.removeLast()
            state = .active(session)
            overlay.flashInvalidKey()
        }
    }

    private func matchedTargetIndexes(prefix: [PhysicalKey], targets: [HintTarget]) -> Set<Int> {
        Set(targets.indices.filter { targets[$0].hintCode.hasPrefix(prefix) })
    }

    // MARK: Click execution

    private func execute(_ target: HintTarget) {
        guard case .active(let session) = state else { return }
        let gen = session.generation
        cancelIdleTimeout()
        overlay.hideImmediately()
        input.endHintCapture()
        state = .executing(generation: gen, target: target)

        // §3.28 key_to_click: final key → click request dispatched.
        let keyInterval = PerformanceMetrics.signposter.beginInterval(Self.spKeyToClick)
        PerformanceMetrics.signposter.endInterval(Self.spKeyToClick, keyInterval)

        clickTask = Task { [weak self] in
            await self?.performActivation(generation: gen, target: target)
        }
    }

    private func performActivation(generation gen: UInt64, target: HintTarget) async {
        do {
            let result = try await backend.activate(target)
            guard generation == gen, case .executing = state else { return }  // superseded
            switch result {
            case .completed:
                transitionToIdle()
            case .abortedSilently:
                abortSilently(generation: gen)
            }
        } catch {
            guard generation == gen, case .executing = state else { return }
            failSession(hudText(for: error), generation: gen)
        }
    }

    // MARK: Transitions

    private var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    private func transitionToIdle() {
        clickTask = nil
        state = .idle
    }

    /// Cancel current mode → idle invariant, optionally showing an error HUD
    /// afterwards. Bumps generation so every in-flight result is discarded.
    private func cancelToIdle(hudText: String?) {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        clickTask?.cancel()
        clickTask = nil
        idleTimeoutTask?.cancel()
        idleTimeoutTask = nil
        overlay.hideImmediately()
        input.endHintCapture()
        state = .idle
        if let hudText {
            overlay.showHUD(hudText)
        }
    }

    /// Failure path: enforce the §3.29 invariant (overlay hidden, gate
    /// activationOnly, state idle), then surface the transient HUD.
    private func failSession(_ text: String, generation gen: UInt64) {
        guard generation == gen else { return }
        overlay.hideImmediately()
        input.endHintCapture()
        state = .idle
        loadTask?.cancel()
        loadTask = nil
        idleTimeoutTask?.cancel()
        idleTimeoutTask = nil
        overlay.showHUD(text)
    }

    /// Silent abort (recovery exhausted / context changed): same invariant, no HUD.
    private func abortSilently(generation gen: UInt64) {
        guard generation == gen else { return }
        clickTask = nil
        overlay.hideImmediately()
        input.endHintCapture()
        state = .idle
    }

    // MARK: Idle timeout

    private func scheduleIdleTimeout() {
        idleTimeoutTask?.cancel()
        idleTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled else { return }
            self?.idleTimedOut()
        }
    }

    private func cancelIdleTimeout() {
        idleTimeoutTask?.cancel()
        idleTimeoutTask = nil
    }

    private func idleTimedOut() {
        guard case .active = state else { return }
        // The user did not cause this dismissal (unlike toggle-cancel), so
        // the vanish gets a one-line explanation instead of silence.
        cancelToIdle(hudText: Self.hudIdleCancelled)
    }

    // MARK: Error mapping

    private func hudText(for error: any Error) -> String {
        guard let backendError = error as? HintSessionBackendError else {
            return Self.hudDriverUnavailable
        }
        switch backendError {
        case .scanTimedOut:
            return Self.hudScanTimedOut
        case .accessibilityRequired:
            return Self.hudAccessibilityRequired
        case .targetChanged:
            return Self.hudTargetChanged
        case .noActionableElements:
            return Self.hudNoActionableElements
        default:
            return Self.hudDriverUnavailable
        }
    }
}
