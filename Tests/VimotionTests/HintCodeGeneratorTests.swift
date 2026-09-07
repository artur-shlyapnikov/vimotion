import XCTest

@testable import Vimotion

final class HintCodeGeneratorTests: XCTestCase {
    /// Default ergonomic order A S D F G H J K L Q W E R T Y U I O P Z X C V B N M
    /// spelled out locally so these tests do not depend on PhysicalKey helpers.
    private let alphabet: [PhysicalKey] = [
        .a, .s, .d, .f, .g, .h, .j, .k, .l,
        .q, .w, .e, .r, .t, .y, .u, .i, .o, .p,
        .z, .x, .c, .v, .b, .n, .m,
    ]

    private var glyphAlphabet: [Character] {
        alphabet.map(\.displayGlyph)
    }

    /// Smallest L such that K^L >= n — the minimal max depth achievable by this
    /// construction (it fills the K-ary tree breadth-first).
    private func boundMaxLength(_ n: Int, _ k: Int) -> Int {
        guard n > 0 else { return 0 }
        var depth = 1
        var capacity = k
        while capacity < n {
            capacity *= k
            depth += 1
        }
        return depth
    }

    private func assertValidSet(_ codes: [HintCode], targetCount: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(codes.count, targetCount, "exact count", file: file, line: line)
        let strings = codes.map(\.displayString)
        let unique = Set(strings)
        XCTAssertEqual(unique.count, strings.count, "no duplicates", file: file, line: line)
        // Prefix freedom: no proper prefix of any code is itself a full code.
        for string in strings {
            for end in string.indices.dropLast() {
                let prefix = String(string[...end])
                XCTAssertFalse(
                    unique.contains(prefix),
                    "'\(prefix)' is a prefix of '\(string)'",
                    file: file, line: line
                )
            }
        }
        for code in codes {
            XCTAssertFalse(code.keys.isEmpty, file: file, line: line)
            XCTAssertTrue(code.keys.allSatisfy { alphabet.contains($0) }, file: file, line: line)
        }
    }

    /// Sampled instead of exhaustive `0...5000`: the full sweep costs ~137 s
    /// of suite wall time. These samples cover N=0, N=1, the k/k±1 boundary
    /// region (25/26/27 for the default k=26), the two-key depth transition
    /// (51/52) and its three-key counterpart (701/702), mid-range and extreme
    /// sizes — every construction-depth branch is hit while keeping each
    /// per-sample invariant assertion intact.
    private static let sampledCounts = [0, 1, 25, 26, 27, 51, 52, 100, 701, 702, 2500, 5000]

    func testExactCountUniquenessAndPrefixFreedomAcrossSampledSizes() {
        let k = alphabet.count
        for n in Self.sampledCounts {
            let codes = HintCodeGenerator.generate(targetCount: n, alphabet: alphabet)
            assertValidSet(codes, targetCount: n)
            if n <= k {
                XCTAssertEqual(
                    codes.map(\.displayString),
                    glyphAlphabet.prefix(n).map(String.init),
                    "first N single keys",
                    file: #filePath, line: #line
                )
            }
        }
    }
    func testDeterminismAcrossCalls() {
        for n in [0, 1, 5, k(), k() + 1, 137, 999, 5000] {
            let first = HintCodeGenerator.generate(targetCount: n, alphabet: alphabet)
            let second = HintCodeGenerator.generate(targetCount: n, alphabet: alphabet)
            XCTAssertEqual(first, second, "N=\(n)", file: #filePath, line: #line)
        }
    }

    func testMaxLengthEqualsMinimalConstructionDepthBound() {
        let k = alphabet.count
        // Same sampled sweep as above — see the rationale on sampledCounts.
        for n in Self.sampledCounts {
            let codes = HintCodeGenerator.generate(targetCount: n, alphabet: alphabet)
            let expected = boundMaxLength(n, k)
            let actualMax = codes.map(\.keys.count).max() ?? 0
            XCTAssertEqual(actualMax, expected, "N=\(n)", file: #filePath, line: #line)
        }
    }

    func testExpansionAtKPlus1ReplacesLeastErgonomicSingleKey() {
        let k = alphabet.count
        let codes = HintCodeGenerator.generate(targetCount: k + 1, alphabet: alphabet)
        let lastGlyph = String(glyphAlphabet[k - 1])
        // Exactly one expanded leaf: the least ergonomic single key gains
        // children and stops being a standalone code.
        let singles = codes.filter { $0.keys.count == 1 }
        XCTAssertEqual(singles.count, k - 1)
        XCTAssertFalse(singles.contains { $0.displayString == lastGlyph })
        let expanded = codes.filter { $0.keys.count == 2 }
        XCTAssertEqual(expanded.count, 2)
        XCTAssertTrue(expanded.allSatisfy { $0.displayString.hasPrefix(lastGlyph) })
        XCTAssertEqual(expanded.map(\.displayString), [lastGlyph + String(glyphAlphabet[0]), lastGlyph + String(glyphAlphabet[1])])
    }

    /// Plan §3.13: output must be sorted by (length asc, alphabet-index
    /// lexicographic asc). The construction alone emits leaves worst-first;
    /// verified at the single→two-key boundary (27), mid two-key range (52),
    /// and the two→three-key boundary (702), over the default alphabet.
    func testOutputIsSortedByLengthThenAlphabetIndex() {
        let defaultAlphabet = PhysicalKey.defaultAlphabetOrder
        func sortedByLengthThenIndex(_ lhs: [Int], _ rhs: [Int]) -> Bool {
            lhs.count != rhs.count ? lhs.count < rhs.count : lhs.lexicographicallyPrecedes(rhs)
        }
        for n in [27, 52, 702] {
            let codes = HintCodeGenerator.generate(targetCount: n, alphabet: defaultAlphabet)
            let paths = codes.map { code in
                code.keys.map { key in defaultAlphabet.firstIndex(of: key)! }
            }
            XCTAssertEqual(
                paths,
                paths.sorted(by: sortedByLengthThenIndex),
                "N=\(n) not in (length, alphabet-index) ascending order",
                file: #filePath, line: #line
            )
        }
    }

    private func k() -> Int { alphabet.count }
}
