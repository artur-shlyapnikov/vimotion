// HintLayoutEngine.swift
// Pure, deterministic hint placement (plan §3.21).
//
// This file intentionally does NOT import AppKit: it operates exclusively on
// CGGeometry values so it stays unit-testable off-main and free of UI state.
//
// Invariants:
// - Layout is a SINGLE deterministic forward pass over `targets.indices`;
//   identical inputs always yield identical output (stable screen choice,
//   stable candidate order, stable spatial-hash iteration).
// - Collision detection is O(1) amortized per candidate via a uniform
//   spatial hash grid (cell size 32 pt) — never pairwise O(N²).
// - Codes are prefix-free (plan §3.12), therefore every rendered badge
//   corresponds to exactly one resolvable target: a fully typed code is an
//   exact-match terminal event.
// - Positions produced here are FROZEN for the lifetime of a hint session;
//   prefix filtering only changes visibility/dimming, never rects, so
//   labels never jump (plan §3.21).

import Foundation

/// Per-screen geometry snapshot in AppKit global coordinates.
struct ScreenBox: Sendable, Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
}

/// One resolved badge placement. `rect` is in screen-LOCAL AppKit
/// coordinates (origin = bottom-left of `screens[screenIndex].frame`).
struct PlacedHint: Sendable, Equatable {
    var targetIndex: Int
    var screenIndex: Int        // index into the screens array passed to layout
    var rect: CGRect            // screen-LOCAL AppKit coords of badge frame
    var code: HintCode
}

enum HintLayoutEngine {

    // MARK: Shared visual metrics (single source for engine + drawing view)

    /// Badge typography: monospacedSystemFont(12, .semibold).
    static let badgeFontSize: CGFloat = 12
    /// Approximate monospaced advance per glyph at the badge font.
    static let badgeGlyphAdvance: CGFloat = 8
    /// Horizontal badge padding (§3.20).
    static let badgePaddingH: CGFloat = 3
    /// Vertical badge padding (§3.20).
    static let badgePaddingV: CGFloat = 1
    /// Fixed badge height: glyph box + vertical padding on both sides.
    static let badgeHeight: CGFloat = 14
    /// Corner radius (§3.20).
    static let badgeCornerRadius: CGFloat = 3
    /// Frozen constant: spatial grid cell size 32 pt.
    static let defaultCellSize: CGFloat = 32

    /// Size of a badge for a code with `glyphCount` characters.
    /// width ≈ 8 pt × glyphs + 2 × 3 pt horizontal padding; height ≈ 14 pt.
    /// Used by both this engine and HintOverlayView so measured and drawn
    /// geometry can never diverge.
    static func badgeSize(forGlyphCount glyphCount: Int) -> CGSize {
        CGSize(
            width: CGFloat(max(glyphCount, 1)) * badgeGlyphAdvance + 2 * badgePaddingH,
            height: badgeHeight
        )
    }

    // MARK: Layout

    /// Places one badge per target. Pure function; single deterministic pass.
    ///
    /// Screen selection per target:
    /// 1. the screen whose `frame` contains the target's `visibleFrame`
    ///    center (first such screen in order);
    /// 2. otherwise the screen with the largest intersection area with
    ///    `visibleFrame` (ties resolve to the earliest screen);
    /// 3. otherwise (no intersection anywhere) screen 0 — overlap beats a
    ///    missing hint.
    ///
    /// Candidates are tried inside the target's `visibleFrame` converted to
    /// the chosen screen's LOCAL coordinates, in order: top-left, top-right,
    /// bottom-left, bottom-right, center. Each candidate is clamped into the
    /// screen bounds; the first candidate that does not collide with any
    /// already-placed badge on the SAME screen wins. If every candidate
    /// collides, the clamped top-left candidate is emitted anyway — overlap
    /// is preferable to a missing hint.
    static func layout(
        targets: [HintTarget],
        codeFor: (Int) -> HintCode,
        screens: [ScreenBox],
        cellSize: CGFloat
    ) -> [PlacedHint] {
        guard !screens.isEmpty else { return [] }

        var placed: [PlacedHint] = []
        placed.reserveCapacity(targets.count)
        // ONE grid across all screens; cells are keyed by (screen, x, y) so
        // rects only ever collide with same-screen placements. A single
        // instance mutated in place for the whole pass is essential: copying
        // a per-screen grid per badge (the COW trap of `dict[key, default:]`
        // → mutate → write back) costs O(N²) at the documented ~3000-target
        // scale.
        var grid = SpatialGrid(cellSize: cellSize)

        for index in targets.indices {
            let visibleFrame = targets[index].visibleFrame
            let screenIndex = self.screenIndex(forVisibleFrame: visibleFrame, screens: screens)
            let screen = screens[screenIndex]

            let badgeSize = badgeSize(
                forGlyphCount: codeFor(index).displayString.count
            )
            let candidates = candidateRects(
                visibleFrame: visibleFrame,
                screen: screen,
                badgeSize: badgeSize
            )

            // First non-colliding candidate wins; fallback = top-left even
            // if colliding (overlap beats missing hint).
            let winning = candidates.first { !grid.collides($0, screen: screenIndex) } ?? candidates[0]

            grid.insert(winning, screen: screenIndex)
            placed.append(
                PlacedHint(
                    targetIndex: index,
                    screenIndex: screenIndex,
                    rect: winning,
                    code: codeFor(index)
                )
            )
        }

        return placed
    }

    // MARK: Screen selection

    private static func screenIndex(
        forVisibleFrame visibleFrame: CGRect,
        screens: [ScreenBox]
    ) -> Int {
        let center = CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)
        // 1. First screen containing the visibleFrame center.
        for (offset, screen) in screens.enumerated() where screen.frame.contains(center) {
            return offset
        }
        // 2. Largest intersection area (earliest wins ties).
        var bestOffset = 0
        var bestArea: CGFloat = -1
        for (offset, screen) in screens.enumerated() {
            let area = screen.frame.intersection(visibleFrame).width
                * screen.frame.intersection(visibleFrame).height
            if area > bestArea {
                bestArea = area
                bestOffset = offset
            }
        }
        return bestOffset
    }

    // MARK: Candidate generation

    /// Candidate badge origins, in §3.21 order, expressed in the screen's
    /// LOCAL coordinate space and clamped into the screen bounds.
    private static func candidateRects(
        visibleFrame: CGRect,
        screen: ScreenBox,
        badgeSize: CGSize
    ) -> [CGRect] {
        let localBounds = CGRect(origin: .zero, size: screen.frame.size)
        // Convert global AppKit visibleFrame to screen-local coordinates.
        let localVisible = CGRect(
            x: visibleFrame.origin.x - screen.frame.origin.x,
            y: visibleFrame.origin.y - screen.frame.origin.y,
            width: visibleFrame.width,
            height: visibleFrame.height
        )
        let w = badgeSize.width
        let h = badgeSize.height

        let unclamped: [CGRect] = [
            // top-left
            CGRect(x: localVisible.minX, y: localVisible.maxY - h, width: w, height: h),
            // top-right
            CGRect(x: localVisible.maxX - w, y: localVisible.maxY - h, width: w, height: h),
            // bottom-left
            CGRect(x: localVisible.minX, y: localVisible.minY, width: w, height: h),
            // bottom-right
            CGRect(x: localVisible.maxX - w, y: localVisible.minY, width: w, height: h),
            // center
            CGRect(
                x: localVisible.midX - w / 2,
                y: localVisible.midY - h / 2,
                width: w,
                height: h
            ),
        ]

        return unclamped.map { clamped($0, into: localBounds) }
    }

    /// Clamps `rect` fully inside `bounds`; oversized badges pin to `bounds`
    /// origin so they remain addressable.
    private static func clamped(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        let x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        let y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
        return CGRect(
            x: max(x, bounds.minX),
            y: max(y, bounds.minY),
            width: rect.width,
            height: rect.height
        )
    }
}

// MARK: - Spatial hash grid

/// Uniform spatial hash over placed rects for ALL screens. Cells are keyed
/// by (screen, x, y) so a rect is only compared against placements on the
/// SAME screen; query and insert touch only the cells a rect overlaps,
/// keeping layout off the O(N²) path.
struct SpatialGrid {
    let cellSize: CGFloat
    private var cells: [CellIndex: [CGRect]] = [:]

    struct CellIndex: Hashable {
        var screen: Int
        var x: Int
        var y: Int
    }

    init(cellSize: CGFloat) {
        self.cellSize = cellSize > 0 ? cellSize : HintLayoutEngine.defaultCellSize
    }

    func collides(_ rect: CGRect, screen: Int) -> Bool {
        for index in overlappedCells(of: rect, screen: screen) {
            if let bucket = cells[index], bucket.contains(where: { $0.intersects(rect) }) {
                return true
            }
        }
        return false
    }

    /// In-place insertion; mutating avoids copying the whole cell dictionary
    /// per badge (quadratic overall). Query API (`collides`) is unchanged.
    mutating func insert(_ rect: CGRect, screen: Int) {
        for index in overlappedCells(of: rect, screen: screen) {
            cells[index, default: []].append(rect)
        }
    }

    private func overlappedCells(of rect: CGRect, screen: Int) -> [CellIndex] {
        let minX = Int(floor(rect.minX / cellSize))
        let maxX = Int(floor(rect.maxX / cellSize))
        let minY = Int(floor(rect.minY / cellSize))
        let maxY = Int(floor(rect.maxY / cellSize))
        var result: [CellIndex] = []
        result.reserveCapacity((maxX - minX + 1) * (maxY - minY + 1))
        for x in minX...maxX {
            for y in minY...maxY {
                result.append(CellIndex(screen: screen, x: x, y: y))
            }
        }
        return result
    }
}
