import XCTest
@testable import Vimotion

final class PhysicalKeyTests: XCTestCase {

    func testAllCasesCount() {
        XCTAssertEqual(PhysicalKey.allCases.count, 26)
    }

    func testCaseOrder() {
        let expected: [PhysicalKey] = [
            .a, .s, .d, .f, .g, .h, .j, .k, .l,
            .q, .w, .e, .r, .t, .y, .u, .i, .o, .p,
            .z, .x, .c, .v, .b, .n, .m,
        ]
        XCTAssertEqual(PhysicalKey.allCases, expected)
    }

    func testDefaultAlphabetOrder() {
        let glyphs = PhysicalKey.defaultAlphabetOrder.map(\.displayGlyph)
        XCTAssertEqual(String(glyphs), "ASDFGHJKLQWERTYUIOPZXCVBNM")
        XCTAssertEqual(Set(PhysicalKey.defaultAlphabetOrder), Set(PhysicalKey.allCases))
    }

    /// Hardcoded ANSI table must be a bijection over the 26 keys and match the
    /// documented kVK_ANSI_* constants (Carbon.HIToolbox reference values).
    func testKeyCodeTableMatchesANSIConstants() {
        let expected: [PhysicalKey: UInt64] = [
            .a: 0x00, .s: 0x01, .d: 0x02, .f: 0x03, .h: 0x04, .g: 0x05,
            .z: 0x06, .x: 0x07, .c: 0x08, .v: 0x09, .b: 0x0B,
            .q: 0x0C, .w: 0x0D, .e: 0x0E, .r: 0x0F, .y: 0x10, .t: 0x11,
            .o: 0x1F, .u: 0x20, .i: 0x22, .p: 0x23,
            .l: 0x25, .j: 0x26, .k: 0x28,
            .n: 0x2D, .m: 0x2E,
        ]
        for (key, code) in expected {
            XCTAssertEqual(key.cgKeyCode, code, "key \(key.rawValue)")
        }
        // Bijective: distinct codes for all keys.
        let codes = PhysicalKey.allCases.map(\.cgKeyCode)
        XCTAssertEqual(Set(codes).count, 26)
    }

    func testReverseMappingRoundTrip() {
        for key in PhysicalKey.allCases {
            XCTAssertEqual(PhysicalKey(cgKeyCode: key.cgKeyCode), key)
        }
    }

    func testNonHintKeyCodesReturnNil() {
        XCTAssertNil(PhysicalKey(cgKeyCode: VimotionKeys.escapeKeyCode))       // Escape 0x35
        XCTAssertNil(PhysicalKey(cgKeyCode: VimotionKeys.backspaceKeyCode))    // Backspace 0x33
        XCTAssertNil(PhysicalKey(cgKeyCode: VimotionKeys.spaceKeyCode))        // Space 0x31
        XCTAssertNil(PhysicalKey(cgKeyCode: 0x7B))                             // left arrow
    }

    func testDisplayGlyphIsUppercaseLatin() {
        for key in PhysicalKey.allCases {
            let glyph = key.displayGlyph
            XCTAssertTrue(glyph.isLetter)
            XCTAssertEqual(String(glyph), String(glyph).uppercased())
            XCTAssertEqual(String(glyph), key.rawValue.uppercased())
        }
        XCTAssertEqual(PhysicalKey.a.displayGlyph, "A")
        XCTAssertEqual(PhysicalKey.m.displayGlyph, "M")
    }

    func testCodableRoundTrip() throws {
        for key in PhysicalKey.allCases {
            let data = try JSONEncoder().encode(key)
            let decoded = try JSONDecoder().decode(PhysicalKey.self, from: data)
            XCTAssertEqual(decoded, key)
        }
    }
}
