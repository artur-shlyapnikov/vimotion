import XCTest

@testable import Vimotion

@MainActor
final class HintSessionBackendTests: XCTestCase {

    nonisolated(unsafe) private var createdSuites: [String] = []

    override func tearDown() {
        for suiteName in createdSuites {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        createdSuites.removeAll()
        super.tearDown()
    }

    private func makeSettings() -> SettingsStore {
        let suiteName = "vimotion-backend-tests-\(UUID().uuidString)"
        createdSuites.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = SettingsStore(defaults: defaults)
        settings.setHintAlphabet([.a, .b, .c, .d])
        return settings
    }

    private func makeWindow(id: UInt32 = 42, pid: pid_t = 4711) -> CuaWindow {
        CuaWindow(
            windowID: id,
            pid: pid,
            appName: nil,
            title: nil,
            bounds: CuaRect(x: 0, y: 0, width: 1200, height: 800),
            zIndex: 1,
            isOnScreen: true,
            onCurrentSpace: true
        )
    }

    private func makeSnapshot(
        windowID: UInt32 = 42,
        pid: pid_t = 4711,
        token: String = "token"
    ) -> CuaWindowSnapshot {
        CuaWindowSnapshot(
            pid: pid,
            windowID: windowID,
            snapshotID: "snapshot",
            windowBounds: CuaRect(x: 0, y: 0, width: 1200, height: 800),
            elements: [
                CuaElement(
                    index: 0,
                    token: token,
                    role: "AXButton",
                    label: "OK",
                    value: nil,
                    frame: CuaRect(x: 40, y: 30, width: 60, height: 24),
                    parentIndex: nil,
                    depth: 0
                ),
            ],
            elementCount: 1,
            degradedReason: nil,
            offSpace: false
        )
    }

    private func makeBackend(
        serving: MockCuaServing,
        settings: SettingsStore
    ) -> HintSessionBackend {
        let resolver = WindowTargetResolver(
            providers: WindowTargetingProviders(
                listWindows: { onScreenOnly in
                    try await serving.listWindows(onScreenOnly: onScreenOnly)
                },
                quartzLayer0FrontToBack: { [] }
            ),
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
        return HintSessionBackend(
            serving: serving,
            resolver: resolver,
            settings: settings
        )
    }

    func testLoadSessionOwnsTargetPreparationAndCodeAssignment() async throws {
        let window = makeWindow()
        let serving = MockCuaServing(
            windows: [.success([window])],
            snapshots: [.success(makeSnapshot(), .zero)]
        )
        let backend = makeBackend(serving: serving, settings: makeSettings())

        let loaded = try await backend.loadSession()

        XCTAssertEqual(loaded.window, window)
        XCTAssertEqual(loaded.snapshotID, "snapshot")
        XCTAssertEqual(loaded.targets.map(\.token), ["token"])
        XCTAssertEqual(loaded.targets.first?.hintCode.keys, [.a])
    }

    func testLoadSessionExposesFeatureErrorInsteadOfRawCuaError() async {
        let serving = MockCuaServing(
            windows: [.failure(CuaError.accessibilityDenied)],
            snapshots: []
        )
        let backend = makeBackend(serving: serving, settings: makeSettings())

        do {
            _ = try await backend.loadSession()
            XCTFail("expected feature-level accessibility error")
        } catch let error as HintSessionBackendError {
            XCTAssertEqual(error, .accessibilityRequired)
        } catch {
            XCTFail("unexpected raw error: \(error)")
        }
    }

    func testActivatePerformsOnlyTheSingleStaleRecoveryAttempt() async throws {
        let window = makeWindow()
        let serving = MockCuaServing(
            windows: [.success([window]), .success([window])],
            snapshots: [
                .success(makeSnapshot(token: "old-token"), .zero),
                .success(makeSnapshot(token: "new-token"), .zero),
            ],
            clicks: [
                .failure(CuaError.staleElementToken, .zero),
                .success(.zero),
            ]
        )
        let backend = makeBackend(serving: serving, settings: makeSettings())

        let loaded = try await backend.loadSession()
        let result = try await backend.activate(loaded.targets[0])

        XCTAssertEqual(result, .completed)
        let entries = serving.log.entries()
        XCTAssertEqual(entries, [
            "listWindows",
            "snapshot:4711:42",
            "click:4711:old-token",
            "listWindows",
            "snapshot:4711:42",
            "click:4711:new-token",
        ])
    }
}
