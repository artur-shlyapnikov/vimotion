import XCTest

@testable import Vimotion

// MARK: - Scriptable driver mock

/// Thread-safe call recorder shared across actor boundaries.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ item: String) {
        lock.withLock { items.append(item) }
    }

    func entries() -> [String] {
        lock.withLock { items }
    }
}

actor MockCuaServing: CuaDriverServing {

    enum SnapshotStep: Sendable {
        case success(CuaWindowSnapshot, Duration)
        case failure(CuaError, Duration)
        case ownerMismatch(actualPID: pid_t, Duration)
    }

    enum ClickStep: Sendable {
        case success(Duration)
        case failure(CuaError, Duration)
    }

    let log = CallLog()

    private var windowSteps: [Result<[CuaWindow], CuaError>]
    private let windowDelay: Duration
    private var snapshotSteps: [SnapshotStep]
    private var clickSteps: [ClickStep]

    init(
        windows: [Result<[CuaWindow], CuaError>] = [],
        windowDelay: Duration = .zero,
        snapshots: [SnapshotStep] = [],
        clicks: [ClickStep] = []
    ) {
        self.windowSteps = windows
        self.windowDelay = windowDelay
        self.snapshotSteps = snapshots
        self.clickSteps = clicks
    }

    func health() async throws -> CuaHealth {
        CuaHealth(schemaVersion: nil, binaryVersion: nil, platformSupported: nil,
                  sessionActive: nil, bundleIdentity: nil, tccAccessibility: nil, axCapability: nil)
    }

    func listWindows(onScreenOnly: Bool) async throws -> [CuaWindow] {
        log.append("listWindows")
        guard !windowSteps.isEmpty else {
            // Unscripted call → loud failure so tests catch unexpected traffic.
            throw CuaError.transportDisconnected
        }
        try await pacedSleep(windowDelay)
        switch windowSteps.removeFirst() {
        case .success(let windows): return windows
        case .failure(let error): throw error
        }
    }

    func snapshot(pid: pid_t, windowID: UInt32) async throws -> CuaWindowSnapshot {
        log.append("snapshot:\(pid):\(windowID)")
        guard !snapshotSteps.isEmpty else {
            throw CuaError.transportDisconnected
        }
        switch snapshotSteps.removeFirst() {
        case .success(let snap, let delay):
            try await pacedSleep(delay)
            return snap
        case .failure(let error, let delay):
            try await pacedSleep(delay)
            throw error
        case .ownerMismatch(let actualPID, let delay):
            try await pacedSleep(delay)
            throw CuaError.windowOwnerMismatch(actualPID: actualPID)
        }
    }

    func click(pid: pid_t, elementToken: String) async throws {
        log.append("click:\(pid):\(elementToken)")
        guard !clickSteps.isEmpty else {
            throw CuaError.transportDisconnected
        }
        switch clickSteps.removeFirst() {
        case .success(let delay):
            try await pacedSleep(delay)
        case .failure(let error, let delay):
            try await pacedSleep(delay)
            throw error
        }
    }

    /// Cancellation-aware delay; an interrupted step must not complete normally.
    private func pacedSleep(_ duration: Duration) async throws {
        do {
            try await Task.sleep(for: duration)
        } catch {
            throw CancellationError()
        }
    }
}

// MARK: - Fixtures

private struct FixtureWindow {
    static func make(
        id: UInt32,
        pid: pid_t,
        z: Int? = 1
    ) -> CuaWindow {
        CuaWindow(
            windowID: id,
            pid: pid,
            appName: nil,
            title: nil,
            bounds: CuaRect(x: 0, y: 0, width: 1200, height: 800),
            zIndex: z,
            isOnScreen: true,
            onCurrentSpace: true
        )
    }
}

@MainActor
final class HintModeControllerTests: XCTestCase {

    // MARK: Fixture helpers


    private let targetPID: pid_t = 4711
    /// UserDefaults suite names handed out by makeSettings; removed in
    /// tearDown so tests do not leak persistent domains. `nonisolated`
    /// because XCTest teardown hooks are not main-actor isolated; safe
    /// because XCTest runs one test case's setup/test/teardown serially.
    nonisolated(unsafe) private var createdSuites: [String] = []
    private let targetWindowID: UInt32 = 42

    private func makeSettings(alphabet: [PhysicalKey]? = nil) -> SettingsStore {
        let suiteName = "vimotion-tests-\(UUID().uuidString)"
        createdSuites.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = SettingsStore(defaults: defaults)
        if let alphabet {
            store.setHintAlphabet(alphabet)
        }
        return store
    }

    override func tearDown() {
        for suiteName in createdSuites {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        createdSuites.removeAll()
        super.tearDown()
    }

    private func makeElement(
        index: Int,
        token: String,
        role: String = "AXButton",
        label: String? = "OK",
        x: Double,
        y: Double,
        width: Double = 60,
        height: Double = 24,
        depth: Int = 0
    ) -> CuaElement {
        CuaElement(
            index: index,
            token: token,
            role: role,
            label: label,
            value: nil,
            frame: CuaRect(x: x, y: y, width: width, height: height),
            parentIndex: nil,
            depth: depth
        )
    }

    private func makeSnapshot(elements: [CuaElement], pid: pid_t) -> CuaWindowSnapshot {
        CuaWindowSnapshot(
            pid: pid,
            windowID: targetWindowID,
            snapshotID: "snap-1",
            windowBounds: CuaRect(x: 0, y: 0, width: 1200, height: 800),
            elements: elements,
            elementCount: elements.count,
            degradedReason: nil,
            offSpace: false
        )
    }

    private struct Harness {
        let controller: HintModeController
        let serving: MockCuaServing
        let overlay: OverlayCoordinator
        let gate: InputGate
    }

    private func makeHarness(
        windows: [CuaWindow] = [],
        windowResults: [Result<[CuaWindow], CuaError>]? = nil,
        windowDelay: Duration = .zero,
        snapshots: [MockCuaServing.SnapshotStep],
        clicks: [MockCuaServing.ClickStep] = [],
        alphabet: [PhysicalKey]? = [.a, .b, .c, .d]
    ) -> Harness {
        let serving = MockCuaServing(
            windows: windowResults ?? [.success(windows)],
            windowDelay: windowDelay,
            snapshots: snapshots,
            clicks: clicks
        )
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let resolver = WindowTargetResolver(
            providers: WindowTargetingProviders(
                listWindows: { onScreenOnly in
                    try await serving.listWindows(onScreenOnly: onScreenOnly)
                },
                quartzLayer0FrontToBack: { [] }
            ),
            ownPID: ownPID
        )
        let overlay = OverlayCoordinator()
        let gate = InputGate()
        let controller = HintModeController(
            serving: serving,
            resolver: resolver,
            overlay: overlay,
            gate: gate,
            settings: makeSettings(alphabet: alphabet)
        )
        return Harness(controller: controller, serving: serving, overlay: overlay, gate: gate)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func waitUntilIdle(_ harness: Harness, timeout: TimeInterval = 2) async -> Bool {
        await waitUntil(timeout: timeout) {
            if case .idle = harness.controller.state { return true }
            return false
        }
    }

    private func waitUntilActive(_ harness: Harness, timeout: TimeInterval = 2) async -> Bool {
        await waitUntil(timeout: timeout) {
            if case .active = harness.controller.state { return true }
            return false
        }
    }

    private func hudText(of overlay: OverlayCoordinator) -> String? {
        overlay.currentHUDText
    }

    private func sessionState(of state: HintModeState) -> HintSession? {
        if case .active(let session) = state { return session }
        return nil
    }

    // MARK: Happy path

    func testHappyPathOrderingAndActivation() async {
        let elements = [
            makeElement(index: 0, token: "t0", x: 40, y: 30),
            makeElement(index: 1, token: "t1", x: 300, y: 200),
        ]

        let harness = await makeHarness(
            windows: [FixtureWindow.make(id: targetWindowID, pid: targetPID)],
            snapshots: [.success(makeSnapshot(elements: elements, pid: targetPID), .zero)]
        )
        XCTAssertEqual(harness.gate.mode, .activationOnly)

        harness.controller.handle(.activateHintMode)

        // Gate flips to hint capture immediately (before any await).
        XCTAssertEqual(harness.gate.mode, .hintCapture)
        if case .loading = harness.controller.state {} else {
            XCTFail("expected loading state right after activation")
        }

        let active = await waitUntilActive(harness)
        XCTAssertTrue(active)
        XCTAssertEqual(harness.gate.mode, .hintCapture)

        let session = sessionState(of: harness.controller.state)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.targets.count, 2)
        XCTAssertEqual(session?.targetWindow.windowID, targetWindowID)
        XCTAssertEqual(session?.typedPrefix, [])
        XCTAssertFalse(session?.targets[0].hintCode.keys.isEmpty ?? true)

        let entries = await harness.serving.log.entries()
        XCTAssertEqual(entries, ["listWindows", "snapshot:\(targetPID):\(targetWindowID)"])

        // Toggle-cancel from active returns to idle invariant.
        harness.controller.handle(.activateHintMode)
        if case .idle = harness.controller.state {} else {
            XCTFail("toggle-cancel from active should reach idle")
        }
        XCTAssertEqual(harness.gate.mode, .activationOnly)
    }

    // MARK: Buffered keys

    func testBufferedKeyReplayExecutesImmediately() async {
        let harness = await makeHarness(
            windows: [FixtureWindow.make(id: targetWindowID, pid: targetPID)],
            snapshots: [.success(makeSnapshot(elements: [makeElement(index: 0, token: "t0", x: 40, y: 30)], pid: targetPID), .milliseconds(80))],
            clicks: [.success(.zero)]
        )

        harness.controller.handle(.activateHintMode)

        // Key pressed during loading is buffered.
        harness.controller.handle(.hintKey(.a))
        if case .loading(_, let buffered, _) = harness.controller.state {
            XCTAssertEqual(buffered, [.a])
        } else {
            XCTFail("expected loading state while buffering key")
        }

        // Once active, replay hits the exact single-key code and clicks.
        let idle = await waitUntilIdle(harness)
        XCTAssertTrue(idle)
        let entries = await harness.serving.log.entries()
        XCTAssertEqual(entries, [
            "listWindows",
            "snapshot:\(targetPID):\(targetWindowID)",
            "click:\(targetPID):t0",
        ])
        XCTAssertEqual(harness.gate.mode, .activationOnly)
    }

    func testBufferedBackspaceRemovesLastKey() async {
        let harness = await makeHarness(
            windows: [FixtureWindow.make(id: targetWindowID, pid: targetPID)],
            snapshots: [.success(makeSnapshot(elements: [makeElement(index: 0, token: "t0", x: 40, y: 30)], pid: targetPID), .milliseconds(60))],
            clicks: [.success(.zero)]
        )

        harness.controller.handle(.activateHintMode)
        harness.controller.handle(.hintKey(.a))
        harness.controller.handle(.hintKey(.b))
        harness.controller.handle(.backspace)
        if case .loading(_, let buffered, _) = harness.controller.state {
            XCTAssertEqual(buffered, [.a])
        } else {
            XCTFail("expected loading state")
        }

        let idle = await waitUntilIdle(harness)
        XCTAssertTrue(idle)  // replay of [.a] executed the single match
    }

    // MARK: Generation guards / late results

    func testCancelDuringScanDiscardsLateSnapshot() async throws {
        let harness = await makeHarness(
            windows: [FixtureWindow.make(id: targetWindowID, pid: targetPID)],
            snapshots: [.success(makeSnapshot(elements: [makeElement(index: 0, token: "t0", x: 40, y: 30)], pid: targetPID), .milliseconds(150))]
        )

        harness.controller.handle(.activateHintMode)
        // Park the pipeline inside the timed snapshot request so the cancel
        // below actually interrupts in-flight work (two consecutive sync
        // handles would cancel before anything ran and prove nothing).
        try await Task.sleep(for: .milliseconds(40))
        harness.controller.handle(.cancelHintMode)

        if case .idle = harness.controller.state {} else {
            XCTFail("cancel should return to idle immediately")
        }
        XCTAssertEqual(harness.gate.mode, .activationOnly)

        // Let the cancelled snapshot's (never-delivered) result land; it must
        // be discarded silently.
        let stayedIdle = await waitUntil(timeout: 0.4) {
            if case .idle = harness.controller.state { return true }
            return false
        }
        XCTAssertTrue(stayedIdle)
        if case .idle = harness.controller.state {} else {
            XCTFail("late result must not resurrect a session")
        }
        let entries = await harness.serving.log.entries()
        XCTAssertEqual(entries.filter { $0 == "listWindows" }.count, 1)
        XCTAssertEqual(entries.filter { $0.hasPrefix("snapshot:") }.count, 1)
        XCTAssertNil(entries.first(where: { $0.hasPrefix("click:") }))
    }

    func testToggleCancelFromActive() async {
        let harness = await makeHarness(
            windows: [FixtureWindow.make(id: targetWindowID, pid: targetPID)],
            snapshots: [.success(makeSnapshot(elements: [makeElement(index: 0, token: "t0", x: 40, y: 30)], pid: targetPID), .zero)]
        )

        harness.controller.handle(.activateHintMode)
        _ = await waitUntilActive(harness)
        harness.controller.handle(.activateHintMode)

        if case .idle = harness.controller.state {} else {
            XCTFail("expected idle after toggle-cancel")
        }
        XCTAssertEqual(harness.gate.mode, .activationOnly)
    }

    func testFrontmostChangeCancelsSilently() async {
        let harness = await makeHarness(
            windows: [FixtureWindow.make(id: targetWindowID, pid: targetPID)],
            snapshots: [.success(makeSnapshot(elements: [makeElement(index: 0, token: "t0", x: 40, y: 30)], pid: targetPID), .zero)]
        )

        harness.controller.handle(.activateHintMode)
        _ = await waitUntilActive(harness)
        harness.controller.frontmostAppDidChange()

        if case .idle = harness.controller.state {} else {
            XCTFail("expected idle after frontmost change")
        }
        XCTAssertEqual(harness.gate.mode, .activationOnly)
        XCTAssertNil(hudText(of: harness.overlay))
    }

    func testScanTimeoutReturnsToIdleWithHUD() async {
        let savedScan = HintModeController.scanTimeout
        HintModeController.scanTimeout = .milliseconds(50)
        defer { HintModeController.scanTimeout = savedScan }
        let harness = await makeHarness(
            windows: [FixtureWindow.make(id: targetWindowID, pid: targetPID)],
            snapshots: [.success(makeSnapshot(elements: [makeElement(index: 0, token: "t0", x: 40, y: 30)], pid: targetPID), .seconds(2))]
        )

        harness.controller.handle(.activateHintMode)
        let idle = await waitUntilIdle(harness)
        XCTAssertTrue(idle)
        XCTAssertEqual(harness.gate.mode, .activationOnly)
        XCTAssertEqual(hudText(of: harness.overlay), HintModeController.hudScanTimedOut)
    }

    func testIdleTimeoutCancelsWithHUD() async {
        let savedIdle = HintModeController.idleTimeout
        HintModeController.idleTimeout = .milliseconds(120)
        defer { HintModeController.idleTimeout = savedIdle }
        let harness = await makeHarness(
            windows: [FixtureWindow.make(id: targetWindowID, pid: targetPID)],
            snapshots: [.success(makeSnapshot(elements: [makeElement(index: 0, token: "t0", x: 40, y: 30)], pid: targetPID), .zero)]
        )

        harness.controller.handle(.activateHintMode)
        let active = await waitUntilActive(harness)
        XCTAssertTrue(active)

        let idle = await waitUntilIdle(harness, timeout: 3)
        XCTAssertTrue(idle)
        XCTAssertEqual(harness.gate.mode, .activationOnly)
        XCTAssertEqual(hudText(of: harness.overlay), HintModeController.hudIdleCancelled)
    }

    func testAcceptedPrefixKeyResetsIdleTimer() async {
        // Deterministic reset proof, no real-time race: keys arrive well
        // inside the timeout (≥10× margin), and the keep-alive phase lasts
        // longer than the timeout itself — a controller that failed to reset
        // would expire mid-keep-alive. Only eventual outcomes are asserted.
        let savedIdle = HintModeController.idleTimeout
        HintModeController.idleTimeout = .seconds(1)
        defer { HintModeController.idleTimeout = savedIdle }
        let elements = (0..<6).map { i in
            makeElement(index: i, token: "t\(i)", x: 40 + Double(i % 3) * 220, y: 30 + Double(i / 3) * 90)
        }
        let harness = await makeHarness(
            windows: [FixtureWindow.make(id: targetWindowID, pid: targetPID)],
            snapshots: [.success(makeSnapshot(elements: elements, pid: targetPID), .zero)]
        )

        harness.controller.handle(.activateHintMode)
        let active = await waitUntilActive(harness)
        XCTAssertTrue(active)

        // §3.13 ordering: single-key codes come first, so pick any target
        // with a two-key code rather than assuming the first target has one.
        guard let session = sessionState(of: harness.controller.state),
              let twoKeyTarget = session.targets.first(where: { $0.hintCode.keys.count == 2 }) else {
            XCTFail("expected a two-key code among targets")
            return
        }
        let firstCode = twoKeyTarget.hintCode.keys

        // Keep-alive: each accepted prefix key reschedules the timeout.
        // A repeated identical key would be a zero-match ([D,D] matches
        // nothing), so clear the prefix with backspace between presses;
        // backspace itself keeps the session alive without resetting.
        // Presses span ~1.2 s, outlasting the 1 s deadline — a controller
        // that failed to reset would drop the session mid-loop.
        let firstKey = firstCode[0]
        for _ in 0..<12 {
            harness.controller.handle(.hintKey(firstKey))
            try? await Task.sleep(for: .milliseconds(100))
            guard case .active = harness.controller.state else {
                XCTFail("session expired despite accepted-prefix resets")
                return
            }
            if case .active(let typed) = harness.controller.state {
                XCTAssertEqual(typed.typedPrefix, [firstKey])
            }
            harness.controller.handle(.backspace)
        }

        // Once typing stops, the session times out on the reset schedule.
        let idle = await waitUntilIdle(harness, timeout: 3)
        XCTAssertTrue(idle)
        XCTAssertEqual(harness.gate.mode, .activationOnly)
    }

    // MARK: Empty tree + error mapping

    func testEmptyTreeShowsNoActionableElementsHUD() async {
        let harness = await makeHarness(
            windows: [FixtureWindow.make(id: targetWindowID, pid: targetPID)],
            snapshots: [.success(makeSnapshot(elements: [], pid: targetPID), .zero)]
        )

        harness.controller.handle(.activateHintMode)
        let idle = await waitUntilIdle(harness)
        XCTAssertTrue(idle)
        XCTAssertEqual(hudText(of: harness.overlay), "No actionable elements")
        XCTAssertEqual(harness.gate.mode, .activationOnly)
    }

    func testTransportFailureShowsDriverUnavailableHUD() async {
        let harness = await makeHarness(
            windowResults: [.failure(CuaError.driverNotInstalled)],
            snapshots: []
        )

        harness.controller.handle(.activateHintMode)
        let idle = await waitUntilIdle(harness)
        XCTAssertTrue(idle)
        XCTAssertEqual(hudText(of: harness.overlay), "Cua Driver unavailable")
        XCTAssertEqual(harness.gate.mode, .activationOnly)
    }

    func testAccessibilityDeniedShowsAccessibilityHUD() async {
        let harness = await makeHarness(
            windowResults: [.failure(CuaError.accessibilityDenied)],
            snapshots: []
        )

        harness.controller.handle(.activateHintMode)
        let idle = await waitUntilIdle(harness)
        XCTAssertTrue(idle)
        XCTAssertEqual(hudText(of: harness.overlay), "Cua Accessibility required")
    }

    // MARK: Owner-mismatch retry (§3.8 race)

    func testOwnerMismatchRetriesOnceThenAbortsOnRepeat() async {
        let window = FixtureWindow.make(id: targetWindowID, pid: targetPID)
        let harness = await makeHarness(
            windows: [window],
            windowResults: [.success([window]), .success([window])],
            snapshots: [
                .ownerMismatch(actualPID: 99, .zero),
                .ownerMismatch(actualPID: 100, .zero),
            ]
        )

        harness.controller.handle(.activateHintMode)
        let idle = await waitUntilIdle(harness)
        XCTAssertTrue(idle)
        XCTAssertEqual(hudText(of: harness.overlay), "Cua Driver unavailable")

        let entries = await harness.serving.log.entries()
        XCTAssertEqual(entries, [
            "listWindows",
            "snapshot:\(targetPID):\(targetWindowID)",
            "listWindows",                       // existence verification
            "snapshot:99:\(targetWindowID)",     // retry against reported owner
        ])
        XCTAssertEqual(harness.gate.mode, .activationOnly)
    }

    func testOwnerMismatchRetryWithNewOwnerSucceeds() async {
        let window = FixtureWindow.make(id: targetWindowID, pid: targetPID)
        let element = makeElement(index: 0, token: "t0", x: 40, y: 30)
        let harness = await makeHarness(
            windows: [window],
            windowResults: [.success([window]), .success([window])],
            snapshots: [
                .ownerMismatch(actualPID: 99, .zero),
                .success(makeSnapshot(elements: [element], pid: 99), .zero),
            ],
            clicks: [.success(.zero)]
        )

        harness.controller.handle(.activateHintMode)
        let active = await waitUntilActive(harness)
        XCTAssertTrue(active)
        let session = sessionState(of: harness.controller.state)
        XCTAssertEqual(session?.targetWindow.windowID, targetWindowID)
        XCTAssertEqual(session?.targets.first?.pid, 99)
    }

    // MARK: Prefix processing

    func testPrefixZeroMatchRestoresPrefixAndStaysActive() async {
        let elements = [
            makeElement(index: 0, token: "t0", label: "A", x: 40, y: 30),
            makeElement(index: 1, token: "t1", label: "B", x: 300, y: 200),
        ]
        let harness = await makeHarness(
            windows: [FixtureWindow.make(id: targetWindowID, pid: targetPID)],
            snapshots: [.success(makeSnapshot(elements: elements, pid: targetPID), .zero)]
        )

        harness.controller.handle(.activateHintMode)
        _ = await waitUntilActive(harness)

        // 'c' is in the alphabet but matches no code.
        harness.controller.handle(.hintKey(.c))
        if case .active(let session) = harness.controller.state {
            XCTAssertEqual(session.typedPrefix, [])
        } else {
            XCTFail("session must stay active after zero-match key")
        }

        // A subsequent valid key still works: 'a' exact-matches whichever
        // target the assigner gave code [a].
        guard let session = sessionState(of: harness.controller.state),
              let coded = session.targets.first(where: { $0.hintCode.keys == [.a] }) else {
            XCTFail("expected exactly one target with single-key code [a]")
            return
        }
        harness.controller.handle(.hintKey(.a))
        let idle = await waitUntilIdle(harness)
        XCTAssertTrue(idle)
        let entries = await harness.serving.log.entries()
        XCTAssertEqual(entries.last, "click:\(targetPID):\(coded.token)")
    }

    func testNonAlphabetKeyIgnoredDuringActive() async {
        let elements = [
            makeElement(index: 0, token: "t0", x: 40, y: 30),
            makeElement(index: 1, token: "t1", x: 300, y: 200),
        ]
        let harness = await makeHarness(
            windows: [FixtureWindow.make(id: targetWindowID, pid: targetPID)],
            snapshots: [.success(makeSnapshot(elements: elements, pid: targetPID), .zero)],
            alphabet: [.a, .b, .c, .d]
        )

        harness.controller.handle(.activateHintMode)
        _ = await waitUntilActive(harness)

        harness.controller.handle(.hintKey(.m))  // not in configured alphabet
        if case .active(let session) = harness.controller.state {
            XCTAssertEqual(session.typedPrefix, [])
        } else {
            XCTFail("expected active session")
        }
    }

    func testPartialPrefixThenBackspaceRestoresEmptyPrefix() async {
        // Six targets over four alphabet keys force two-key codes; target 0's
        // code is generated as [d, a].
        let elements = (0..<6).map { i in
            makeElement(index: i, token: "t\(i)", x: 40 + Double(i % 3) * 220, y: 30 + Double(i / 3) * 90)
        }
        let harness = await makeHarness(
            windows: [FixtureWindow.make(id: targetWindowID, pid: targetPID)],
            snapshots: [.success(makeSnapshot(elements: elements, pid: targetPID), .zero)]
        )

        harness.controller.handle(.activateHintMode)
        _ = await waitUntilActive(harness)

        // §3.13 ordering: single-key codes come first, so pick any target
        // with a two-key code rather than assuming the first target has one.
        guard let session = sessionState(of: harness.controller.state),
              let twoKeyTarget = session.targets.first(where: { $0.hintCode.keys.count == 2 }) else {
            XCTFail("expected a two-key code among targets")
            return
        }
        let firstCode = twoKeyTarget.hintCode.keys

        harness.controller.handle(.hintKey(firstCode[0]))
        if case .active(let typed) = harness.controller.state {
            XCTAssertEqual(typed.typedPrefix, [firstCode[0]])
        } else {
            XCTFail("expected partial prefix retained")
            return
        }

        harness.controller.handle(.backspace)
        if case .active(let cleared) = harness.controller.state {
            XCTAssertEqual(cleared.typedPrefix, [])
        } else {
            XCTFail("expected active session after backspace")
        }
    }

    // MARK: Stale-token recovery (§3.24)

    func testStaleRecoveryUniqueMatchClicksNewToken() async {
        let window = FixtureWindow.make(id: targetWindowID, pid: targetPID)
        // Same geometry/role/label under a new token → exactly one candidate.
        let freshElements = [makeElement(index: 0, token: "tok2", x: 100, y: 100)]
        let harness = await makeHarness(
            windows: [window],
            windowResults: [.success([window]), .success([window])],
            snapshots: [
                .success(makeSnapshot(elements: [makeElement(index: 0, token: "tok1", x: 100, y: 100)], pid: targetPID), .zero),
                .success(makeSnapshot(elements: freshElements, pid: targetPID), .zero),
            ],
            clicks: [
                .failure(CuaError.staleElementToken, .zero),
                .success(.zero),
            ]
        )

        harness.controller.handle(.activateHintMode)
        _ = await waitUntilActive(harness)

        // Single-key code 'a' → exact match on tok1 → stale click → recovery.
        harness.controller.handle(.hintKey(.a))

        let idle = await waitUntilIdle(harness)
        XCTAssertTrue(idle)
        let entries = await harness.serving.log.entries()
        XCTAssertEqual(entries, [
            "listWindows",
            "snapshot:\(targetPID):\(targetWindowID)",
            "click:\(targetPID):tok1",
            "listWindows",                        // recovery step 1: same frontmost
            "snapshot:\(targetPID):\(targetWindowID)",  // recovery step 2: fresh snapshot
            "click:\(targetPID):tok2",            // unique fingerprint match clicked
        ])
        XCTAssertNil(hudText(of: harness.overlay))
    }

    func testStaleRecoveryAmbiguousMatchAbortsSilently() async {
        let window = FixtureWindow.make(id: targetWindowID, pid: targetPID)
        // Two candidates share role+label, centers 12 pt apart (within tolerance)
        // but IoU < 0.97 so dedupe keeps both → ambiguous → abort.
        let freshElements = [
            makeElement(index: 0, token: "tok2", x: 100, y: 100),
            makeElement(index: 1, token: "tok3", x: 112, y: 100),
        ]
        let harness = await makeHarness(
            windows: [window],
            windowResults: [.success([window]), .success([window])],
            snapshots: [
                .success(makeSnapshot(elements: [makeElement(index: 0, token: "tok1", x: 100, y: 100)], pid: targetPID), .zero),
                .success(makeSnapshot(elements: freshElements, pid: targetPID), .zero),
            ],
            clicks: [.failure(CuaError.staleElementToken, .zero)]
        )

        harness.controller.handle(.activateHintMode)
        _ = await waitUntilActive(harness)
        harness.controller.handle(.hintKey(.a))

        let idle = await waitUntilIdle(harness)
        XCTAssertTrue(idle)
        let entries = await harness.serving.log.entries()
        XCTAssertEqual(entries.filter { $0.hasPrefix("click:") }.count, 1)  // no further recovery click
        XCTAssertNil(hudText(of: harness.overlay))  // silent abort
    }

    func testStaleRecoveryZeroMatchesAbortsSilently() async {
        let window = FixtureWindow.make(id: targetWindowID, pid: targetPID)
        // Different label → label rule excludes everything.
        let freshElements = [makeElement(index: 0, token: "tok2", label: "CANCEL", x: 100, y: 100)]
        let harness = await makeHarness(
            windows: [window],
            windowResults: [.success([window]), .success([window])],
            snapshots: [
                .success(makeSnapshot(elements: [makeElement(index: 0, token: "tok1", x: 100, y: 100)], pid: targetPID), .zero),
                .success(makeSnapshot(elements: freshElements, pid: targetPID), .zero),
            ],
            clicks: [.failure(CuaError.staleElementToken, .zero)]
        )

        harness.controller.handle(.activateHintMode)
        _ = await waitUntilActive(harness)
        harness.controller.handle(.hintKey(.a))

        let idle = await waitUntilIdle(harness)
        XCTAssertTrue(idle)
        let entries = await harness.serving.log.entries()
        XCTAssertEqual(entries.filter { $0.hasPrefix("click:") }.count, 1)
        XCTAssertNil(hudText(of: harness.overlay))
    }

    func testStaleRecoveryAbortsWhenFrontmostChanged() async {
        let oldWindow = FixtureWindow.make(id: targetWindowID, pid: targetPID)
        let otherWindow = FixtureWindow.make(id: 77, pid: 5000)
        let harness = await makeHarness(
            windows: [oldWindow],
            windowResults: [.success([oldWindow]), .success([otherWindow])],
            snapshots: [
                .success(makeSnapshot(elements: [makeElement(index: 0, token: "tok1", x: 100, y: 100)], pid: targetPID), .zero),
            ],
            clicks: [.failure(CuaError.staleElementToken, .zero)]
        )

        harness.controller.handle(.activateHintMode)
        _ = await waitUntilActive(harness)
        harness.controller.handle(.hintKey(.a))

        let idle = await waitUntilIdle(harness)
        XCTAssertTrue(idle)
        let entries = await harness.serving.log.entries()
        XCTAssertNil(entries.last(where: { $0.hasPrefix("click:tok2") }))
        XCTAssertEqual(entries.filter { $0.hasPrefix("snapshot:") }.count, 1)  // no second snapshot
        XCTAssertNil(hudText(of: harness.overlay))
    }

    // MARK: Overlay view flash reset

    func testSetEntriesClearsInvalidKeyFlashAndRebuildsVisibility() {
        let view = HintOverlayView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let first = HintOverlayView.Entry(
            targetIndex: 0,
            rect: CGRect(x: 10, y: 10, width: 20, height: 14),
            codeString: "A"
        )
        view.setEntries([first])

        // Hide everything via prefix filtering so the rebuild is observable.
        view.applyPrefix(typedGlyphCount: 1, matchedTargetIndexes: [])
        XCTAssertTrue(view.visibleTargetIndexes.isEmpty)

        view.flashInvalidKey()
        XCTAssertTrue(view.isFlashActive)

        // A fresh hint set must not inherit the stale flash and must make
        // its own entries visible again.
        let fresh = HintOverlayView.Entry(
            targetIndex: 1,
            rect: CGRect(x: 60, y: 40, width: 20, height: 14),
            codeString: "B"
        )
        view.setEntries([fresh])
        XCTAssertFalse(view.isFlashActive)
        XCTAssertEqual(view.visibleTargetIndexes, [1])
    }
}
