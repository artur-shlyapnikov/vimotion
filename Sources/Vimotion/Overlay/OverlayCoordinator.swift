// OverlayCoordinator.swift
// Owns screen-panel lifecycle for the overlay system (plan §3.19).
//
// Invariants:
// - One HintPanel per NSScreen, keyed by a stable display identity
//   (CGDirectDisplayID) so panels survive re-shows and are recreated
//   lazily only after a topology change destroys them.
// - Layout output is committed verbatim after present(targets:) performs the
//   one orchestration step, and applyPrefix NEVER re-runs layout — positions
//   are frozen for the session so labels cannot jump.
// - Codes are prefix-free ⇒ exact-match terminal; non-matching targets are
//   hidden entirely while matching targets keep their rects.
// - Every panel ignores mouse events: clicks always reach apps underneath.

import AppKit

@MainActor
final class OverlayCoordinator {

    // MARK: Screen identity

    /// Stable per-display key: the CGDirectDisplayID surfaced through
    /// NSScreen.deviceDescription ("NSScreenNumber"). Stable across app
    /// restarts for a given physical display arrangement.
    struct ScreenKey: Hashable {
        let displayID: UInt32

        init(displayID: UInt32) {
            self.displayID = displayID
        }

        init(screen: NSScreen) {
            self.init(
                displayID: (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber)?.uint32Value ?? 0
            )
        }
    }

    // MARK: State

    private var panels: [ScreenKey: HintPanel] = [:]

    private var hudPanel: NSPanel?
    private var hudLabel: NSTextField?
    private var hudDismissTask: Task<Void, Never>?

    /// Test seam: the text currently shown in the error HUD, or nil when no
    /// HUD is visible. Cleared on auto-dismiss, hideImmediately, destroyPanels.
    internal private(set) var currentHUDText: String?

    // MARK: Commit

    /// Feature-facing presentation operation. Screen ordering, AppKit-to-pure
    /// layout conversion, screen indices, and cell-size policy stay inside the
    /// overlay boundary; callers provide only the prepared targets.
    func present(targets: [HintTarget]) {
        let screens = NSScreen.screens
        let screenBoxes = screens.map { screen in
            ScreenBox(frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
        let placed = HintLayoutEngine.layout(
            targets: targets,
            codeFor: { index in targets[index].hintCode },
            screens: screenBoxes,
            cellSize: HintLayoutEngine.defaultCellSize
        )
        show(hints: placed, screens: screens)
    }

    /// Full commit of a freshly laid-out hint set. Groups by screenIndex,
    /// sizes each panel to its screen frame, updates the view model array,
    /// and orders front without activation.
    func show(hints: [PlacedHint], screens: [NSScreen]) {
        var groupedByScreen: [Int: [HintOverlayView.Entry]] = [:]
        for hint in hints {
            groupedByScreen[hint.screenIndex, default: []].append(
                HintOverlayView.Entry(
                    targetIndex: hint.targetIndex,
                    rect: hint.rect,
                    codeString: hint.code.displayString
                )
            )
        }

        var liveKeys = Set<ScreenKey>()
        for (index, screen) in screens.enumerated() {
            let key = ScreenKey(screen: screen)
            liveKeys.insert(key)
            let panel = reusablePanel(for: key, screenFrame: screen.frame)
            panel.setHints(groupedByScreen[index] ?? [])
            panel.present(at: screen.frame)
        }

        // Panels whose screen vanished stay deallocated-ready but off screen.
        for (key, panel) in panels where !liveKeys.contains(key) {
            panel.orderOut(nil)
        }
    }

    /// Applies typed-prefix filtering WITHOUT re-running layout: positions
    /// are frozen, only visibility and prefix dimming change.
    func applyPrefix(_ prefix: [PhysicalKey], matchedTargetIndexes: Set<Int>) {
        for panel in panels.values {
            panel.overlayView.applyPrefix(
                typedGlyphCount: prefix.count,
                matchedTargetIndexes: matchedTargetIndexes
            )
        }
    }

    /// Short error flash on every currently visible badge (0 matches).
    func flashInvalidKey() {
        for panel in panels.values where panel.isVisible {
            panel.overlayView.flashInvalidKey()
        }
    }

    // MARK: Error HUD

    /// Transient error HUD near top-center of the main screen.
    /// Auto-dismisses after 1.6 s; a new call cancels-and-replaces the
    /// pending dismissal task.
    func showHUD(_ text: String) {
        currentHUDText = text
        prepareHUDPanel(text: text)
        guard let hudPanel else { return }

        let mainScreen = NSScreen.main ?? NSScreen.screens.first
        if let mainScreen {
            let textSize = hudLabel?.intrinsicContentSize ?? NSSize(width: 80, height: 16)
            let padH: CGFloat = 12
            let padV: CGFloat = 7
            let panelSize = NSSize(
                width: textSize.width + 2 * padH,
                height: textSize.height + 2 * padV
            )
            let origin = NSPoint(
                x: mainScreen.frame.midX - panelSize.width / 2,
                y: mainScreen.frame.maxY - 56
            )
            hudPanel.setFrame(NSRect(origin: origin, size: panelSize), display: false)
            hudLabel?.frame = NSRect(
                x: padH,
                y: padV,
                width: textSize.width,
                height: textSize.height
            )
        }
        hudPanel.orderFrontRegardless()

        hudDismissTask?.cancel()
        hudDismissTask = Task { [weak self] in
            try? await Task.sleep(for: HintModeConstants.hudAutoDismissSeconds)
            guard !Task.isCancelled else { return }
            self?.hudPanel?.orderOut(nil)
            self?.currentHUDText = nil
        }
    }

    // MARK: Teardown

    /// Removes all overlay surfaces from screen immediately without
    /// deallocating panels (cheap re-show on next activation).
    func hideImmediately() {
        hudDismissTask?.cancel()
        hudDismissTask = nil
        currentHUDText = nil
        for panel in panels.values {
            panel.orderOut(nil)
        }
        hudPanel?.orderOut(nil)
    }

    /// Topology change path: closes and releases all panels; they are
    /// recreated lazily on the next show(hints:screens:).
    func destroyPanels() {
        hudDismissTask?.cancel()
        hudDismissTask = nil
        for panel in panels.values {
            panel.close()
        }
        panels.removeAll()

        hudPanel?.close()
        hudPanel = nil
        hudLabel = nil
        currentHUDText = nil
    }

    // MARK: Panel management

    private func reusablePanel(for key: ScreenKey, screenFrame: NSRect) -> HintPanel {
        if let existing = panels[key] {
            return existing
        }
        let panel = HintPanel(screenFrame: screenFrame)
        panels[key] = panel
        return panel
    }

    private func prepareHUDPanel(text: String) {
        if hudPanel == nil {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = NSColor.black.withAlphaComponent(0.85)
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isReleasedWhenClosed = false

            let label = NSTextField(labelWithString: text)
            label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
            label.textColor = .white
            panel.contentView = label

            hudPanel = panel
            hudLabel = label
        } else {
            hudLabel?.stringValue = text
        }
    }
}
