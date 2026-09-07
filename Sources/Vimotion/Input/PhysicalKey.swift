import Foundation

/// A physical letter key on an ANSI keyboard layout.
///
/// Frozen interface per `docs/architecture.md` / contract. The ANSI virtual
/// keycode table below is hardcoded from `Carbon.HIToolbox.Events.kVK_ANSI_*`
/// constants (documentation reference only — Carbon is NOT linked at runtime).
/// Verified pairs (kVK_ANSI_ name : value):
///   kVK_ANSI_A=0x00, S=0x01, D=0x02, F=0x03, H=0x04, G=0x05, Z=0x06,
///   X=0x07, C=0x08, V=0x09, B=0x0B, Q=0x0C, W=0x0D, E=0x0E, R=0x0F,
///   Y=0x10, T=0x11, O=0x1F (=31), P=0x23, U=0x20, I=0x22, L=0x25,
///   J=0x26, K=0x28, N=0x2D, M=0x2E
enum PhysicalKey: String, CaseIterable, Codable, Hashable, Sendable {
    case a, s, d, f, g, h, j, k, l            // home row first
    case q, w, e, r, t, y, u, i, o, p
    case z, x, c, v, b, n, m

    /// Ergonomic-first default ordering used by `HintCodeGenerator`.
    static let defaultAlphabetOrder: [PhysicalKey] = [
        .a, .s, .d, .f, .g, .h, .j, .k, .l,
        .q, .w, .e, .r, .t, .y, .u, .i, .o, .p,
        .z, .x, .c, .v, .b, .n, .m,
    ]

    /// ANSI virtual keycode (`CGKeyCode`), hardcoded per the table above.
    var cgKeyCode: UInt64 {
        switch self {
        case .a: return 0x00
        case .s: return 0x01
        case .d: return 0x02
        case .f: return 0x03
        case .h: return 0x04
        case .g: return 0x05
        case .z: return 0x06
        case .x: return 0x07
        case .c: return 0x08
        case .v: return 0x09
        case .b: return 0x0B
        case .q: return 0x0C
        case .w: return 0x0D
        case .e: return 0x0E
        case .r: return 0x0F
        case .y: return 0x10
        case .t: return 0x11
        case .o: return 0x1F
        case .u: return 0x20
        case .i: return 0x22
        case .p: return 0x23
        case .l: return 0x25
        case .j: return 0x26
        case .k: return 0x28
        case .n: return 0x2D
        case .m: return 0x2E
        }
    }

    /// Reverse ANSI mapping; returns nil for non-hint keycodes.
    init?(cgKeyCode: UInt64) {
        guard let key = PhysicalKey.allCases.first(where: { $0.cgKeyCode == cgKeyCode }) else { return nil }
        self = key
    }

    /// Canonical Latin uppercase glyph.
    var displayGlyph: Character {
        Character(rawValue.uppercased())
    }
}
