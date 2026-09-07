import CoreGraphics
import XCTest
@testable import Vimotion

@MainActor
final class SettingsStoreTests: XCTestCase {

    private let suiteName = "SettingsStoreTests-\(UUID().uuidString)"

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Defaults

    func testFreshStoreLoadsSchemaV1Defaults() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.activationKeyCode, 49) // ⌘⇧Space
        XCTAssertEqual(store.activationModifiers, [.maskCommand, .maskShift])
        XCTAssertEqual(store.hintAlphabet, PhysicalKey.defaultAlphabetOrder)
        XCTAssertEqual(store.activationChord.keyCode, 49)
        XCTAssertEqual(store.activationChord.requiredFlags, [.maskCommand, .maskShift])

        // Defaults are persisted, schema version stamped.
        XCTAssertEqual(defaults.integer(forKey: "settingsSchemaVersion"), 1)
        XCTAssertEqual(defaults.integer(forKey: "activationKeyCode"), 49)
        XCTAssertEqual(
            defaults.array(forKey: "hintAlphabetKeyCodes") as? [Int],
            PhysicalKey.defaultAlphabetOrder.map { Int($0.cgKeyCode) }
        )
    }

    // MARK: - Load-time repair

    func testCorruptAlphabetRepairsOnlyAlphabet() {
        let defaults = makeDefaults()
        defaults.set(0x25, forKey: "activationKeyCode")          // L
        defaults.set(Int(CGEventFlags.maskControl.rawValue), forKey: "activationModifierFlags")
        defaults.set([Int(PhysicalKey.a.cgKeyCode), Int(PhysicalKey.a.cgKeyCode)], // duplicate
                     forKey: "hintAlphabetKeyCodes")

        let store = SettingsStore(defaults: defaults)

        // Alphabet repaired to default…
        XCTAssertEqual(store.hintAlphabet, PhysicalKey.defaultAlphabetOrder)
        XCTAssertEqual(
            defaults.array(forKey: "hintAlphabetKeyCodes") as? [Int],
            PhysicalKey.defaultAlphabetOrder.map { Int($0.cgKeyCode) }
        )
        // …while activation survived untouched.
        XCTAssertEqual(store.activationKeyCode, 0x25)
        XCTAssertEqual(store.activationModifiers, .maskControl)
        XCTAssertEqual(defaults.integer(forKey: "activationKeyCode"), 0x25)
    }

    func testNegativeAlphabetEntryIsCorruptAndRepairsField() {
        let defaults = makeDefaults()
        defaults.set(0x25, forKey: "activationKeyCode")
        defaults.set(Int(CGEventFlags.maskControl.rawValue), forKey: "activationModifierFlags")
        // A negative entry is out of domain → the whole field is corrupt.
        defaults.set([-3, Int(PhysicalKey.d.cgKeyCode),
                      Int(PhysicalKey.f.cgKeyCode), Int(PhysicalKey.j.cgKeyCode)],
                     forKey: "hintAlphabetKeyCodes")

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.hintAlphabet, PhysicalKey.defaultAlphabetOrder)
        XCTAssertEqual(
            defaults.array(forKey: "hintAlphabetKeyCodes") as? [Int],
            PhysicalKey.defaultAlphabetOrder.map { Int($0.cgKeyCode) }
        )
        // Only the alphabet field is repaired.
        XCTAssertEqual(store.activationKeyCode, 0x25)
    }

    func testEmptyActivationModifiersRepairToDefault() {
        let defaults = makeDefaults()
        defaults.set([Int(PhysicalKey.a.cgKeyCode), Int(PhysicalKey.s.cgKeyCode),
                      Int(PhysicalKey.d.cgKeyCode), Int(PhysicalKey.f.cgKeyCode)],
                     forKey: "hintAlphabetKeyCodes")
        defaults.set(0x25, forKey: "activationKeyCode")
        defaults.set(0, forKey: "activationModifierFlags") // empty → invalid

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.activationModifiers, [.maskCommand, .maskShift])
        XCTAssertEqual(defaults.integer(forKey: "activationModifierFlags"),
                       Int((CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)))
        // Alphabet intact.
        XCTAssertEqual(store.hintAlphabet.count, 4)
    }

    func testDisallowedModifierBitsAreRejectedAtLoad() {
        let defaults = makeDefaults()
        let bogus: CGEventFlags = [.maskNonCoalesced, .maskSecondaryFn]
        defaults.set(Int(bogus.rawValue), forKey: "activationModifierFlags")

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.activationModifiers, [.maskCommand, .maskShift])
    }

    // MARK: - Setter validation

    func testSetHintAlphabetRejectsFewerThanFourDistinctKeys() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        let original = store.hintAlphabet

        store.setHintAlphabet([.a, .s, .d]) // <4 distinct

        // Nothing changed in memory or on disk.
        XCTAssertEqual(store.hintAlphabet, original)
        XCTAssertEqual(
            defaults.array(forKey: "hintAlphabetKeyCodes") as? [Int],
            original.map { Int($0.cgKeyCode) }
        )
    }

    func testSetHintAlphabetRejectsDuplicates() {
        let store = SettingsStore(defaults: makeDefaults())
        let original = store.hintAlphabet

        store.setHintAlphabet([.a, .a, .s, .d, .f])

        XCTAssertFalse(SettingsStore.validate(alphabet: [.a, .a, .s, .d, .f]))
        XCTAssertEqual(store.hintAlphabet, original)
    }

    func testSetHintAlphabetAcceptsValidSubset() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)

        store.setHintAlphabet([.f, .j, .d, .k])

        XCTAssertEqual(store.hintAlphabet, [.f, .j, .d, .k])
        XCTAssertEqual(
            defaults.array(forKey: "hintAlphabetKeyCodes") as? [Int],
            [Int(PhysicalKey.f.cgKeyCode), Int(PhysicalKey.j.cgKeyCode),
             Int(PhysicalKey.d.cgKeyCode), Int(PhysicalKey.k.cgKeyCode)]
        )
    }

    func testSetActivationRejectsEmptyModifiersAndRepairsField() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)

        store.setActivation(keyCode: 0x25, modifiers: []) // never empty

        XCTAssertEqual(store.activationModifiers, [.maskCommand, .maskShift])
        XCTAssertEqual(store.activationKeyCode, VimotionKeys.spaceKeyCode)
    }

    func testSetActivationMasksDisallowedBits() {
        let store = SettingsStore(defaults: makeDefaults())

        let flags: CGEventFlags = [.maskControl, .maskNonCoalesced]
        store.setActivation(keyCode: 0x25, modifiers: flags)

        XCTAssertEqual(store.activationModifiers, .maskControl)
        XCTAssertEqual(store.activationChord,
                       ActivationChord(keyCode: 0x25, requiredFlags: .maskControl))
    }

    // MARK: - Persistence roundtrip

    func testRoundtripThroughInjectedUserDefaults() {
        let defaults = makeDefaults()

        let writer = SettingsStore(defaults: defaults)
        writer.setActivation(keyCode: 0x26, modifiers: [.maskControl, .maskAlternate])
        writer.setHintAlphabet([.l, .k, .j, .h, .g])

        let reader = SettingsStore(defaults: defaults)

        XCTAssertEqual(reader.activationKeyCode, 0x26)
        XCTAssertEqual(reader.activationModifiers, [.maskControl, .maskAlternate])
        XCTAssertEqual(reader.hintAlphabet, [.l, .k, .j, .h, .g])
        XCTAssertEqual(reader.activationChord,
                       ActivationChord(keyCode: 0x26, requiredFlags: [.maskControl, .maskAlternate]))
    }
}
