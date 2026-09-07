import Foundation

/// Exact-N prefix-free hint-code generation over a physical-key alphabet (§3.12).
///
/// Construction: start with the K single-key leaves. While fewer than N leaves
/// exist, repeatedly take a leaf of minimal length — among ties the least
/// ergonomic one (lexicographically greatest alphabet-index path) — and replace
/// it with its first min(K, remaining + 1) children.
enum HintCodeGenerator {
    static func generate(targetCount: Int, alphabet: [PhysicalKey]) -> [HintCode] {
        let n = max(0, targetCount)
        let k = alphabet.count
        guard n > 0, k > 0 else { return [] }
        if k == 1 {
            // A single symbol yields only one prefix-free code; asking for
            // more is a caller bug (ElementFilter's assign precondition would
            // trip downstream), so fail here where the cause is visible.
            precondition(n <= 1, "prefix-free codes impossible with a single symbol")
            return n == 0 ? [] : [HintCode([alphabet[0]])]
        }
        if n <= k {
            return alphabet.prefix(n).map { HintCode([$0]) }
        }

        // Index paths into `alphabet`; level-by-level because the minimal-length
        // rule drains each depth completely before any deeper leaf is expanded,
        // so every level's membership is fixed before it is processed.
        var finalPaths: [[Int]] = []
        finalPaths.reserveCapacity(n)
        var total = 0
        var level: [[Int]] = (0..<k).map { [$0] }
        total = k
        var nextLevel: [[Int]] = []
        nextLevel.reserveCapacity(k * k)

        outer: while true {
            level.sort { $0.lexicographicallyPrecedes($1) } // ascending
            var i = level.count - 1
            while i >= 0 {
                let remaining = n - total // computed BEFORE removing this leaf
                let path = level[i]
                i -= 1
                if remaining <= k - 1 {
                    // childrenCount == remaining + 1 completes the set exactly.
                    let childrenCount = remaining + 1
                    for j in 0..<childrenCount { finalPaths.append(path + [j]) }
                    while i >= 0 {
                        finalPaths.append(level[i])
                        i -= 1
                    }
                    finalPaths.append(contentsOf: nextLevel)
                    break outer
                }
                for j in 0..<k { nextLevel.append(path + [j]) }
                total += k - 1
            }
            level = nextLevel
            nextLevel.removeAll(keepingCapacity: true)
        }
        // Plan §3.13 requires ergonomic-first ascending assignment: order the
        // final leaf paths by (length asc, then alphabet-index lexicographic).
        // The construction above emits them scrambled worst-first.
        finalPaths.sort {
            $0.count != $1.count ? $0.count < $1.count : $0.lexicographicallyPrecedes($1)
        }

        return finalPaths.map { path in
            HintCode(path.map { alphabet[$0] })
        }
    }
}
