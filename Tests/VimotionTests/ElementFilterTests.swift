import XCTest

@testable import Vimotion

final class ElementFilterTests: XCTestCase {
    private let mainHeight: CGFloat = 800
    private lazy var windowCua = CuaRect(x: 100, y: 100, width: 600, height: 400)
    // Converted window bounds in AppKit space: (100, 300, 600, 400).

    private func appKitY(_ cuaY: CGFloat, _ height: CGFloat) -> CGFloat {
        mainHeight - (cuaY + height)
    }

    private func makeElement(
        index: Int,
        token: String,
        role: String = "AXButton",
        label: String? = nil,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        depth: Int = 0
    ) -> CuaElement {
        CuaElement(
            index: index,
            token: token,
            role: role,
            label: label,
            value: nil,
            frame: CuaRect(x: Double(x), y: Double(y), width: Double(width), height: Double(height)),
            parentIndex: nil,
            depth: depth
        )
    }

    private func makeSnapshot(elements: [CuaElement], windowBounds: CuaRect? = nil) -> CuaWindowSnapshot {
        CuaWindowSnapshot(
            pid: 4711,
            windowID: 42,
            snapshotID: "snap-1",
            windowBounds: windowBounds ?? windowCua,
            elements: elements,
            elementCount: elements.count,
            degradedReason: nil,
            offSpace: false
        )
    }

    private func filter(_ snapshot: CuaWindowSnapshot) -> [HintTarget] {
        ElementFilter.normalize(snapshot, mainDisplayHeight: mainHeight)
    }

    // MARK: Geometry filtering

    func testEmptySnapshotReturnsEmpty() {
        XCTAssertTrue(filter(makeSnapshot(elements: [])).isEmpty)
    }

    func testVirtualizedOneAndTwoPointRowsAreDropped() {
        let snapshot = makeSnapshot(elements: [
            makeElement(index: 0, token: "t1", x: 150, y: 150, width: 100, height: 1),
            makeElement(index: 1, token: "t2", x: 150, y: 150, width: 100, height: 2),
            makeElement(index: 2, token: "t3", x: 150, y: 150, width: 2, height: 100),
            makeElement(index: 3, token: "t4", x: 150, y: 150, width: 3, height: 100),
            makeElement(index: 4, token: "t5", x: 150, y: 150, width: 100, height: 3),
        ])
        let targets = filter(snapshot)
        // t5 has the higher AppKit midY (shorter element) → row-bucket
        // descending puts it before t4.
        XCTAssertEqual(targets.map(\.token), ["t5", "t4"])
    }

    func testNonFiniteCoordinatesAreDropped() {
        let snapshot = makeSnapshot(elements: [
            makeElement(index: 0, token: "nan", x: .nan, y: 10, width: 100, height: 40),
            makeElement(index: 1, token: "inf-w", x: 10, y: 10, width: .infinity, height: 40),
            makeElement(index: 2, token: "neg-inf-y", x: 10, y: -.infinity, width: 100, height: 40),
            makeElement(index: 3, token: "ok", x: 150, y: 150, width: 100, height: 40),
        ])
        XCTAssertEqual(filter(snapshot).map(\.token), ["ok"])
    }

    func testEmptyTokenIsDropped() {
        let snapshot = makeSnapshot(elements: [
            makeElement(index: 0, token: "", x: 150, y: 150, width: 100, height: 40),
            makeElement(index: 1, token: "keep", x: 150, y: 150, width: 100, height: 40),
        ])
        XCTAssertEqual(filter(snapshot).map(\.token), ["keep"])
    }

    func testNoIntersectionWithWindowIsDropped() {
        let snapshot = makeSnapshot(elements: [
            makeElement(index: 0, token: "outside-right", x: 900, y: 150, width: 100, height: 40),
            makeElement(index: 1, token: "outside-above", x: 150, y: 20, width: 100, height: 40),
            makeElement(index: 2, token: "inside", x: 150, y: 150, width: 100, height: 40),
        ])
        XCTAssertEqual(filter(snapshot).map(\.token), ["inside"])
    }

    func testVisibleFrameIsClippedToWindowBoundsAndSourceFrameKept() {
        // Element sticks out left and above the window.
        let snapshot = makeSnapshot(elements: [
            makeElement(index: 0, token: "clipped", x: 50, y: 50, width: 200, height: 100),
        ])
        let targets = filter(snapshot)
        XCTAssertEqual(targets.count, 1)
        let target = targets[0]
        XCTAssertEqual(target.sourceFrame, CGRect(x: 50, y: appKitY(50, 100), width: 200, height: 100))
        XCTAssertEqual(
            target.visibleFrame,
            CGRect(x: 100, y: appKitY(50, 100), width: 150, height: 50)
        )
        XCTAssertEqual(target.fingerprint.center, CGPoint(x: 175, y: appKitY(50, 100) + 25))
        XCTAssertEqual(target.fingerprint.size, CGSize(width: 150, height: 50))
    }

    // MARK: Dedupe

    func testExactDuplicateTokenKeepsFirstOccurrence() {
        let snapshot = makeSnapshot(elements: [
            makeElement(index: 0, token: "dup", x: 150, y: 150, width: 100, height: 40),
            makeElement(index: 1, token: "dup", x: 300, y: 300, width: 100, height: 40),
            makeElement(index: 2, token: "other", x: 150, y: 250, width: 100, height: 40),
        ])
        let targets = filter(snapshot)
        XCTAssertEqual(targets.count, 2)
        XCTAssertTrue(targets.allSatisfy { $0.token != "dup" || $0.visibleFrame.minX == 150 })
        XCTAssertEqual(Set(targets.map(\.token)), ["dup", "other"])
    }

    func testIoUDedupeSurvivorPrefersHigherDepthThenSmallerAreaThenLowerIndex() {
        let base = (x: CGFloat(150), y: CGFloat(150))
        // Higher depth wins over identical-frame peers.
        // Smaller area wins among equal depths (IoU ≈ 0.98 ≥ 0.97).
        // Lower original index wins among equal depth and equal area.
        let snapshot = makeSnapshot(elements: [
            makeElement(index: 0, token: "area-loser", label: "L2",
                        x: base.x, y: base.y, width: 102, height: 40, depth: 1),
            makeElement(index: 1, token: "index-loser", label: "L3",
                        x: base.x, y: base.y, width: 100, height: 40, depth: 0),
            makeElement(index: 2, token: "index-winner", label: "L3",
                        x: base.x, y: base.y, width: 100, height: 40, depth: 0),
            makeElement(index: 3, token: "depth-winner", label: "L1",
                        x: base.x, y: base.y, width: 100, height: 40, depth: 5),
            makeElement(index: 4, token: "bigger", label: "L2",
                        x: base.x, y: base.y, width: 103, height: 40, depth: 1),
        ])
        let targets = filter(snapshot)
        // Survivors: depth-winner (depth 5), area-loser (smaller area in its
        // label group), index-loser (lower original index among equals).
        XCTAssertEqual(targets.map(\.token), ["depth-winner", "area-loser", "index-loser"])
        XCTAssertEqual(targets.first { $0.token == "area-loser" }?.visibleFrame.width, 102)

        // Direct check: a lone pair differing only in area keeps the smaller one.
        let pair = makeSnapshot(elements: [
            makeElement(index: 0, token: "big", label: "same",
                        x: 200, y: 200, width: 103, height: 40, depth: 0),
            makeElement(index: 1, token: "small", label: "same",
                        x: 200, y: 200, width: 100, height: 40, depth: 0),
        ])
        let pairTargets = filter(pair)
        XCTAssertEqual(pairTargets.map(\.token), ["small"])
        XCTAssertEqual(pairTargets[0].visibleFrame.width, 100)
    }

    func testIdenticalFramesWithDifferentLabelsAreNotMerged() {
        let snapshot = makeSnapshot(elements: [
            makeElement(index: 0, token: "save", role: "AXButton", label: "Save",
                        x: 150, y: 150, width: 120, height: 40),
            makeElement(index: 1, token: "open", role: "AXButton", label: "Open",
                        x: 150, y: 150, width: 120, height: 40),
        ])
        let targets = filter(snapshot)
        XCTAssertEqual(Set(targets.map(\.token)), ["save", "open"])
    }

    func testIdenticalFramesWithDifferentRolesAreNotMerged() {
        let snapshot = makeSnapshot(elements: [
            makeElement(index: 0, token: "btn", role: "AXButton", label: "Send",
                        x: 150, y: 150, width: 120, height: 40),
            makeElement(index: 1, token: "link", role: "AXLink", label: "Send",
                        x: 150, y: 150, width: 120, height: 40),
        ])
        XCTAssertEqual(filter(snapshot).count, 2)
    }

    func testIdenticalFramesWithoutLabelsAreNotMerged() {
        let snapshot = makeSnapshot(elements: [
            makeElement(index: 0, token: "a", role: "AXButton",
                        x: 150, y: 150, width: 120, height: 40),
            makeElement(index: 1, token: "b", role: "AXButton",
                        x: 150, y: 150, width: 120, height: 40),
        ])
        XCTAssertEqual(filter(snapshot).count, 2)
    }

    func testIoUBelowThresholdIsNotMerged() {
        // Same-size squares offset by half their side: IoU = 1/3 < 0.97.
        let snapshot = makeSnapshot(elements: [
            makeElement(index: 0, token: "one", role: "AXButton", label: "x",
                        x: 150, y: 150, width: 40, height: 40),
            makeElement(index: 1, token: "two", role: "AXButton", label: "x",
                        x: 170, y: 170, width: 40, height: 40),
        ])
        XCTAssertEqual(filter(snapshot).count, 2)
    }

    // MARK: Fingerprint

    func testFingerprintNormalization() {
        let snapshot = makeSnapshot(elements: [
            makeElement(index: 0, token: "t", role: "  AXButton \n", label: "  Send   Mail  ",
                        x: 150, y: 150, width: 100, height: 40),
        ])
        let targets = filter(snapshot)
        XCTAssertEqual(targets[0].fingerprint.normalizedRole, "axbutton")
        XCTAssertEqual(targets[0].fingerprint.normalizedLabel, "send mail")
        XCTAssertEqual(targets[0].role, "  AXButton \n")
        XCTAssertEqual(targets[0].label, "  Send   Mail  ")
        XCTAssertEqual(targets[0].pid, 4711)
        XCTAssertEqual(targets[0].windowID, 42)
    }

    func testWhitespaceOnlyOrMissingLabelNormalizesToNil() {
        let snapshot = makeSnapshot(elements: [
            makeElement(index: 0, token: "blank", role: "AXButton", label: "   ",
                        x: 150, y: 150, width: 100, height: 40),
            makeElement(index: 1, token: "missing", role: "AXButton", label: nil,
                        x: 150, y: 250, width: 100, height: 40),
        ])
        let targets = filter(snapshot)
        XCTAssertNil(targets[0].fingerprint.normalizedLabel)
        XCTAssertNil(targets[1].fingerprint.normalizedLabel)
    }

    // MARK: Reading order & placeholders

    func testReadingOrderRowBucketThenXThenDepthDescendingThenIndex() throws {
        // After conversion: rows at centerY 645 (bucket 80) and 580 (bucket 72).
        let snapshot = makeSnapshot(elements: [
            makeElement(index: 0, token: "b", label: "b", x: 300, y: 142, width: 60, height: 26),
            makeElement(index: 1, token: "c", label: "c", x: 200, y: 200, width: 50, height: 40),
            makeElement(index: 2, token: "e2", label: "e", x: 120, y: 140, width: 60, height: 30, depth: 0),
            makeElement(index: 3, token: "d", label: "d", x: 120, y: 140, width: 60, height: 30, depth: 1),
            makeElement(index: 4, token: "a", label: "a", x: 120, y: 140, width: 60, height: 30, depth: 0),
        ])
        let targets = filter(snapshot)
        // Bucket 80 first ("b" and the x=120 group — visually highest row),
        // ordered by x (120 before 300); among x=120: depth descending ("d"),
        // then original index ("e2" idx 2 before "a" idx 4). Bucket 72 ("c",
        // lower on screen) comes last.
        XCTAssertEqual(targets.map(\.token), ["d", "e2", "a", "b", "c"])
        let b = try XCTUnwrap(targets[3])
        XCTAssertEqual(b.visibleFrame.midY, appKitY(142, 26) + 13, accuracy: 0.001)
    }

    func testPlaceholderHintCodesAssignedByAssigner() {
        let snapshot = makeSnapshot(elements: (0..<8).map { i in
            makeElement(index: i, token: "t\(i)", label: "l\(i)",
                        x: 120 + CGFloat(i) * 55, y: 140 + CGFloat(i) * 45, width: 50, height: 40)
        })
        let targets = filter(snapshot)
        XCTAssertEqual(targets.count, 8)
        XCTAssertTrue(targets.allSatisfy { $0.hintCode == HintCode([]) })

        let alphabet: [PhysicalKey] = [.a, .s, .d, .f]
        let assigned = HintCodeAssigner.assign(to: targets, alphabet: alphabet)
        XCTAssertEqual(assigned.map(\.hintCode.displayString),
                       HintCodeGenerator.generate(targetCount: 8, alphabet: alphabet).map(\.displayString))
        XCTAssertEqual(assigned.map(\.token), targets.map(\.token))
    }

    // MARK: prepare (deep entry point)

    func testPrepareReturnsCodedTargetsInOneStep() {
        let snapshot = makeSnapshot(elements: (0..<8).map { i in
            makeElement(index: i, token: "t\(i)", label: "l\(i)",
                        x: 120 + CGFloat(i) * 55, y: 140 + CGFloat(i) * 45, width: 50, height: 40)
        })
        let alphabet: [PhysicalKey] = [.a, .s, .d, .f]
        let prepared = ElementFilter.prepare(snapshot, alphabet: alphabet, mainDisplayHeight: mainHeight)
        let expected = HintCodeGenerator.generate(targetCount: 8, alphabet: alphabet).map(\.displayString)
        XCTAssertEqual(prepared.map(\.hintCode.displayString), expected)
        XCTAssertEqual(prepared.map(\.token), filter(snapshot).map(\.token))
    }

    func testPrepareEmptySnapshotReturnsEmpty() {
        let prepared = ElementFilter.prepare(
            makeSnapshot(elements: []), alphabet: [.a, .b, .c, .d], mainDisplayHeight: mainHeight)
        XCTAssertTrue(prepared.isEmpty)
    }
}
