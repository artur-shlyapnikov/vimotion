import Foundation

/// A prefix-free hint code: an ordered sequence of physical keys.
/// If one code is a prefix of another, typing would be ambiguous; the
/// generator guarantees no such pair exists in a produced set.
struct HintCode: Sendable, Hashable {
    let keys: [PhysicalKey]

    init(_ keys: [PhysicalKey]) {
        self.keys = keys
    }

    /// Concatenated canonical glyphs, e.g. "MA".
    var displayString: String {
        String(keys.map(\.displayGlyph))
    }

    /// True when this code starts with exactly the given key sequence.
    func hasPrefix(_ prefix: [PhysicalKey]) -> Bool {
        guard prefix.count <= keys.count else { return false }
        return zip(keys, prefix).allSatisfy { $0 == $1 }
    }
}
