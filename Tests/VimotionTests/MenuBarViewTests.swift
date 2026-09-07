import SwiftUI
import XCTest

@testable import Vimotion

/// Pins the menu-bar chord hint mapping (MenuBarView.menuShortcut): the
/// "Enable Hints" row must render the live activation chord as a native
/// keyboard-shortcut hint, and degrade to no hint for base keys without a
/// menu KeyEquivalent.
@MainActor
final class MenuBarViewTests: XCTestCase {

    // MARK: - Key equivalents

    func testSpaceChordMapsToSpaceKeyEquivalent() {
        let shortcut = MenuBarView.menuShortcut(for: ActivationChord(
            keyCode: VimotionKeys.spaceKeyCode,
            requiredFlags: [.maskCommand, .maskShift]
        ))

        XCTAssertEqual(shortcut?.key, .space)
    }

    func testLetterChordMapsToUppercaseGlyph() {
        let shortcut = MenuBarView.menuShortcut(for: ActivationChord(
            keyCode: PhysicalKey.l.cgKeyCode,
            requiredFlags: .maskControl
        ))

        XCTAssertEqual(shortcut?.key, KeyEquivalent(extendedGraphemeClusterLiteral: "L"))
    }

    func testEscapeChordMapsToEscapeKeyEquivalent() {
        let shortcut = MenuBarView.menuShortcut(for: ActivationChord(
            keyCode: VimotionKeys.escapeKeyCode,
            requiredFlags: .maskAlternate
        ))

        XCTAssertEqual(shortcut?.key, .escape)
    }

    func testNonRepresentableBaseKeyYieldsNoHint() {
        // F1 (0x7A) is a preserved-by-editor base key with no menu glyph.
        XCTAssertNil(MenuBarView.menuShortcut(for: ActivationChord(
            keyCode: 0x7A,
            requiredFlags: .maskCommand
        )))
    }

    // MARK: - Modifier mapping

    func testAllFourAllowedModifiersMapToEventModifiers() {
        let shortcut = MenuBarView.menuShortcut(for: ActivationChord(
            keyCode: VimotionKeys.spaceKeyCode,
            requiredFlags: [.maskCommand, .maskShift, .maskControl, .maskAlternate]
        ))

        XCTAssertEqual(
            shortcut?.modifiers,
            [.command, .shift, .control, .option]
        )
    }

    func testNonChordFlagBitsAreIgnored() {
        // Caps lock / numeric-pad bits never participate in chords.
        let shortcut = MenuBarView.menuShortcut(for: ActivationChord(
            keyCode: VimotionKeys.spaceKeyCode,
            requiredFlags: [.maskCommand, .maskAlphaShift, .maskNumericPad]
        ))

        XCTAssertEqual(shortcut?.modifiers, .command)
    }
}
