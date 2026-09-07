// HintOverlayView.swift
// One custom NSView per screen drawing ALL hint badges in a single draw
// pass (plan §3.20). No subview-per-hint: several thousand targets must not
// become several thousand views.
//
// Privacy: only canonical key glyphs are ever drawn. AX labels, values, and
// element tokens are structurally absent from this view's model.
//
// Invariants:
// - Badge rects arrive from HintLayoutEngine and are IMMUTABLE during prefix
//   filtering; applyPrefix changes visibility/dimming only, so labels never
//   jump (plan §3.21).
// - Codes are prefix-free ⇒ a fully typed code is an exact-match terminal.

import AppKit

final class HintOverlayView: NSView {

    /// Immutable draw model for one badge. `rect` is in this view's local
    /// coordinates (= the panel's screen-local AppKit space).
    struct Entry: Equatable {
        var targetIndex: Int
        var rect: CGRect
        var codeString: String
    }

    // MARK: State

    private var entries: [Entry] = []
    /// Internal getter so tests can observe prefix filtering and flash reset.
    private(set) var visibleTargetIndexes: Set<Int> = []
    private var typedGlyphCount = 0

    private var flashTimer: Timer?
    /// Internal getter so tests can observe the invalid-key flash lifecycle.
    private(set) var isFlashActive = false

    // MARK: Cached draw resources

    // Font and colors are theme-fixed and backing-scale-independent (the
    // scale only affects layer contentsScale), so they are built lazily once
    // and reused across frames instead of being re-allocated every draw pass;
    // no viewDidChangeBackingProperties refresh hook is needed.
    private static let badgeFont = NSFont.monospacedSystemFont(
        ofSize: HintLayoutEngine.badgeFontSize,
        weight: .semibold
    )
    private lazy var normalAttributes: [NSAttributedString.Key: Any] = [
        .font: Self.badgeFont,
        .foregroundColor: NSColor.black,
    ]
    private lazy var dimAttributes: [NSAttributedString.Key: Any] = [
        .font: Self.badgeFont,
        .foregroundColor: NSColor.black.withAlphaComponent(HintModeConstants.prefixDimOpacity),
    ]
    /// Opaque systemYellow-derived fill (§3.20 default style).
    private lazy var badgeFill: NSColor =
        NSColor.systemYellow.blended(withFraction: 0.1, of: NSColor.systemOrange) ?? NSColor.systemYellow
    /// Text extent per glyph count. The frozen font is monospaced, so the
    /// extent depends only on the glyph count; values come from the engine's
    /// frozen metrics — the single source shared with collision layout — and
    /// are cached for the view's lifetime.
    private var textSizeCache: [Int: CGSize] = [:]

    // MARK: Model updates

    /// Commits a fresh full hint set (fresh layout). Resets prefix state:
    /// everything visible, nothing dimmed.
    func setEntries(_ newEntries: [Entry]) {
        // A new session must not inherit a stale invalid-key flash.
        endFlash()
        entries = newEntries
        visibleTargetIndexes = Set(newEntries.map(\.targetIndex))
        typedGlyphCount = 0
        needsDisplay = true
    }

    /// Prefix filtering WITHOUT re-layout: positions are frozen. Non-matching
    /// targets are hidden entirely; matching targets keep their rects with
    /// the first `typedGlyphCount` glyphs drawn at the dim opacity.
    func applyPrefix(typedGlyphCount newTypedCount: Int, matchedTargetIndexes: Set<Int>) {
        typedGlyphCount = max(0, newTypedCount)
        visibleTargetIndexes = matchedTargetIndexes
        needsDisplay = true
    }

    /// Brief red-tinted border flash on all badges (~150 ms), cancelled by
    /// timer invalidation on repeat calls.
    func flashInvalidKey() {
        flashTimer?.invalidate()
        isFlashActive = true
        needsDisplay = true
        // The timer block runs on the main runloop, not the MainActor
        // executor, so MainActor.assumeIsolated would trap. Hop instead.
        flashTimer = Timer.scheduledTimer(
            withTimeInterval: HintModeConstants.invalidKeyFlashSeconds,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.endFlash()
            }
        }
    }

    private func endFlash() {
        flashTimer?.invalidate()
        flashTimer = nil
        guard isFlashActive else { return }
        isFlashActive = false
        needsDisplay = true
    }

    // MARK: Backing scale

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncBackingScale()
    }

    private func syncBackingScale() {
        guard let window else { return }
        // AppKit equivalent of contentScaleFactor: keep any (future) backing
        // layer at the screen's native scale so glyphs render crisply.
        layer?.contentsScale = window.backingScaleFactor
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let fill = badgeFill
        let flashStroke = NSColor.systemRed

        for entry in entries where visibleTargetIndexes.contains(entry.targetIndex) {
            let path = NSBezierPath(
                roundedRect: entry.rect,
                xRadius: HintLayoutEngine.badgeCornerRadius,
                yRadius: HintLayoutEngine.badgeCornerRadius
            )

            // Shadow applies to the fill only; the flash stroke and glyphs
            // draw unshadowed after restore.
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(
                HintModeConstants.badgeShadowAlpha
            )
            shadow.shadowBlurRadius = HintModeConstants.badgeShadowBlurRadius
            shadow.shadowOffset = NSSize(width: 0, height: -1)  // down (view is not flipped)
            shadow.set()
            fill.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()

            if isFlashActive {
                flashStroke.setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }

            draw(code: entry.codeString, in: entry.rect)
        }
    }

    /// Draws centered monospaced glyphs; the typed prefix portion is drawn
    /// separately at the frozen 0.55 dim opacity, remainder at full opacity.
    private func draw(code: String, in rect: CGRect) {
        let whole = code as NSString
        let wholeSize = textSize(forGlyphCount: whole.length)
        let originX = rect.midX - wholeSize.width / 2
        let originY = rect.midY - wholeSize.height / 2

        let typedLength = min(max(typedGlyphCount, 0), whole.length)
        if typedLength == 0 {
            whole.draw(at: CGPoint(x: originX, y: originY), withAttributes: normalAttributes)
            return
        }
        if typedLength >= whole.length {
            whole.draw(at: CGPoint(x: originX, y: originY), withAttributes: dimAttributes)
            return
        }

        let prefix = whole.substring(to: typedLength) as NSString
        let rest = whole.substring(from: typedLength) as NSString
        // Monospaced advance ⇒ prefix width scales linearly with glyph count;
        // no per-frame text measurement needed.
        let prefixWidth = CGFloat(typedLength) * HintLayoutEngine.badgeGlyphAdvance

        prefix.draw(at: CGPoint(x: originX, y: originY), withAttributes: dimAttributes)
        rest.draw(
            at: CGPoint(x: originX + prefixWidth, y: originY),
            withAttributes: normalAttributes
        )
    }

    private func textSize(forGlyphCount glyphCount: Int) -> CGSize {
        if let cached = textSizeCache[glyphCount] { return cached }
        let size = HintLayoutEngine.badgeSize(forGlyphCount: glyphCount)
        textSizeCache[glyphCount] = size
        return size
    }
}

/// Frozen UI constants shared across overlay components (contract "Frozen
/// constants"). Defined here as the overlay-local single source.
enum HintModeConstants {
    static let prefixDimOpacity: CGFloat = 0.55
    static let hudAutoDismissSeconds: Duration = .seconds(2.4)
    static let invalidKeyFlashSeconds: TimeInterval = 0.15
    /// Soft drop shadow under badges: keeps the yellow fill legible over
    /// yellow-tinted app content (§3.20 style, additive contrast only).
    static let badgeShadowAlpha: CGFloat = 0.3
    static let badgeShadowBlurRadius: CGFloat = 2
}
