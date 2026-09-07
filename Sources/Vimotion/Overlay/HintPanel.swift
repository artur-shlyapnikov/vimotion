// HintPanel.swift
// One borderless, non-activating, click-transparent NSPanel per screen
// (plan §3.19). The panel hosts exactly one HintOverlayView filling its
// content; it never becomes key or main and is ordered front without
// activating the app.

import AppKit

final class HintPanel: NSPanel {

    /// Single custom view drawing ALL hints belonging to this screen.
    let overlayView: HintOverlayView

    init(screenFrame: NSRect) {
        let view = HintOverlayView(frame: NSRect(origin: .zero, size: screenFrame.size))
        overlayView = view

        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Clear, shadow-free, click-through chrome (§3.19).
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        contentView = view
    }

    // Overlay windows must never take key/main status; borderless panels
    // already default to false — pinned explicitly as a contract guarantee.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Replaces the full hint set rendered by this panel's view.
    func setHints(_ entries: [HintOverlayView.Entry]) {
        overlayView.setEntries(entries)
    }

    /// Orders the panel on screen WITHOUT activating the application.
    func present(at frame: NSRect) {
        setFrame(frame, display: false)
        orderFrontRegardless()
    }
}
