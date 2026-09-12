import CoreGraphics
import Foundation

/// CuaWindowSnapshot → [HintTarget] normalization pipeline (§3.9, §3.13):
/// convert → geometry filter → dedupe (token-exact, then role+label+IoU≥0.97)
/// → deterministic reading-order sort → positional code assignment.
///
/// New callers should use `prepare(_:alphabet:mainDisplayHeight:)` (or the
/// display-height convenience overload). `normalize(_:mainDisplayHeight:)`
/// remains as the uncoded intermediate for stale-token recovery, which
/// matches on fingerprints without hint codes.
enum ElementFilter {
    /// Deep entry point: snapshot in, fully-coded targets out. Hides the
    /// coordinate conversion, the normalize-then-assign order, the
    /// placeholder-code intermediate state, and the alphabet threading.
    /// Returns an empty array when nothing is actionable; the feature
    /// backend maps that to `.noActionableElements`.
    static func prepare(
        _ snapshot: CuaWindowSnapshot,
        alphabet: [PhysicalKey],
        mainDisplayHeight: CGFloat
    ) -> [HintTarget] {
        HintCodeAssigner.assign(
            to: normalize(snapshot, mainDisplayHeight: mainDisplayHeight),
            alphabet: alphabet
        )
    }

    /// Convenience overload that reads the main display height itself so
    /// feature code does not repeat the `CGDisplayBounds` lookup.
    static func prepare(
        _ snapshot: CuaWindowSnapshot,
        alphabet: [PhysicalKey]
    ) -> [HintTarget] {
        prepare(
            snapshot,
            alphabet: alphabet,
            mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height
        )
    }

    static func normalize(_ snapshot: CuaWindowSnapshot, mainDisplayHeight: CGFloat) -> [HintTarget] {
        let windowBounds = snapshot.windowBounds
        let window = GeometryMapper.appKitRect(
            fromCua: CGRect(x: windowBounds.x, y: windowBounds.y,
                            width: windowBounds.width, height: windowBounds.height),
            mainDisplayHeight: mainDisplayHeight
        )

        struct Candidate {
            var target: HintTarget
            var depth: Int
            var originalIndex: Int
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(snapshot.elements.count)

        for (index, element) in snapshot.elements.enumerated() {
            guard !element.token.isEmpty else { continue }
            let frame = element.frame
            guard frame.x.isFinite, frame.y.isFinite,
                  frame.width.isFinite, frame.height.isFinite else { continue }
            guard frame.width >= 3, frame.height >= 3 else { continue }
            let cgFrame = CGRect(x: frame.x, y: frame.y,
                                 width: frame.width, height: frame.height)
            let sourceFrame = GeometryMapper.appKitRect(
                fromCua: cgFrame,
                mainDisplayHeight: mainDisplayHeight
            )
            let visibleFrame = sourceFrame.intersection(window)
            guard !visibleFrame.isNull,
                  visibleFrame.width > 0, visibleFrame.height > 0 else { continue }

            let normalizedRole = normalized(element.role)
            let normalizedLabel = element.label.flatMap { normalized($0) }.flatMap {
                $0.isEmpty ? nil : $0
            }

            let target = HintTarget(
                token: element.token,
                pid: snapshot.pid,
                windowID: snapshot.windowID,
                role: element.role,
                label: element.label,
                sourceFrame: sourceFrame,
                visibleFrame: visibleFrame,
                hintCode: HintCode([]),
                fingerprint: TargetFingerprint(
                    normalizedRole: normalizedRole,
                    normalizedLabel: normalizedLabel,
                    center: CGPoint(x: visibleFrame.midX, y: visibleFrame.midY),
                    size: CGSize(width: visibleFrame.width, height: visibleFrame.height)
                )
            )
            candidates.append(
                Candidate(target: target, depth: element.depth, originalIndex: index)
            )
        }

        // Dedupe pass 1: exact duplicate tokens — keep first occurrence.
        var seenTokens = Set<String>()
        seenTokens.reserveCapacity(candidates.count)
        var unique: [Candidate] = []
        unique.reserveCapacity(candidates.count)
        for candidate in candidates where seenTokens.insert(candidate.target.token).inserted {
            unique.append(candidate)
        }

        // Dedupe pass 2: different tokens merge ONLY when same normalized role,
        // both labels normalize to the same non-empty string, and IoU ≥ 0.97.
        // Two distinct actions may legitimately share a frame; geometry alone
        // never merges.
        var passthrough: [Candidate] = []
        passthrough.reserveCapacity(unique.count)
        var groups: [String: [Candidate]] = [:]
        for candidate in unique {
            if let label = candidate.target.fingerprint.normalizedLabel, !label.isEmpty {
                let key = candidate.target.fingerprint.normalizedRole + "\u{1F}" + label
                groups[key, default: []].append(candidate)
            } else {
                passthrough.append(candidate)
            }
        }

        var survivors: [Candidate] = passthrough
        for group in groups.values {
            let ordered = group.sorted { a, b in
                if a.depth != b.depth { return a.depth > b.depth }
                let areaA = a.target.visibleFrame.width * a.target.visibleFrame.height
                let areaB = b.target.visibleFrame.width * b.target.visibleFrame.height
                if areaA != areaB { return areaA < areaB }
                return a.originalIndex < b.originalIndex
            }
            var keptFrames: [CGRect] = []
            keptFrames.reserveCapacity(ordered.count)
            for candidate in ordered {
                if !keptFrames.contains(where: { iou($0, candidate.target.visibleFrame) >= 0.97 }) {
                    keptFrames.append(candidate.target.visibleFrame)
                    survivors.append(candidate)
                }
            }
        }

        // Reading order (§3.13): row bucket floor(centerY/8pt) DESCENDING (AppKit
        // +Y is up, so higher buckets are closer to the top of the UI and receive
        // the shorter codes), then x ascending, then depth descending, then
        // original index ascending.
        survivors.sort { a, b in
            let bucketA = rowBucket(a.target.visibleFrame)
            let bucketB = rowBucket(b.target.visibleFrame)
            if bucketA != bucketB { return bucketA > bucketB }
            if a.target.visibleFrame.minX != b.target.visibleFrame.minX {
                return a.target.visibleFrame.minX < b.target.visibleFrame.minX
            }
            if a.depth != b.depth { return a.depth > b.depth }
            return a.originalIndex < b.originalIndex
        }

        return survivors.map(\.target)
    }

    /// Returns the single candidate whose fingerprint matches the original,
    /// or nil when the match is not unique. Stale-token recovery clicks only
    /// on a proven unique replacement and stays silent otherwise.
    static func uniqueFingerprintMatch(
        in candidates: [HintTarget],
        original: HintTarget
    ) -> HintTarget? {
        let matches = candidates.filter { matchesFingerprint($0, original: original) }
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    private static func matchesFingerprint(_ candidate: HintTarget, original: HintTarget) -> Bool {
        let originalFingerprint = original.fingerprint
        let candidateFingerprint = candidate.fingerprint

        guard candidate.role == original.role
                || candidateFingerprint.normalizedRole == originalFingerprint.normalizedRole else {
            return false
        }

        if let label = originalFingerprint.normalizedLabel,
           !label.isEmpty,
           candidateFingerprint.normalizedLabel != label {
            return false
        }

        let dx = Double(candidateFingerprint.center.x - originalFingerprint.center.x)
        let dy = Double(candidateFingerprint.center.y - originalFingerprint.center.y)
        guard (dx * dx + dy * dy).squareRoot() <= 12 else { return false }

        let widthTolerance = max(12, originalFingerprint.size.width * 0.25)
        let heightTolerance = max(12, originalFingerprint.size.height * 0.25)
        guard abs(candidateFingerprint.size.width - originalFingerprint.size.width) <= widthTolerance,
              abs(candidateFingerprint.size.height - originalFingerprint.size.height) <= heightTolerance else {
            return false
        }
        return true
    }

    /// Lowercase, trimmed, internal whitespace collapsed to single spaces.
    private static func normalized(_ value: String) -> String {
        value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func rowBucket(_ rect: CGRect) -> Double {
        (rect.midY / 8).rounded(.down)
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull,
              intersection.width > 0, intersection.height > 0 else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = a.width * a.height + b.width * b.height - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }
}

/// Replaces placeholder hint codes positionally with generator output (§3.13).
enum HintCodeAssigner {
    static func assign(to targets: [HintTarget], alphabet: [PhysicalKey]) -> [HintTarget] {
        let codes = HintCodeGenerator.generate(targetCount: targets.count, alphabet: alphabet)
        precondition(
            codes.count == targets.count,
            "code count \(codes.count) does not match target count \(targets.count)"
        )
        var assigned = targets
        for index in assigned.indices {
            assigned[index].hintCode = codes[index]
        }
        return assigned
    }
}
