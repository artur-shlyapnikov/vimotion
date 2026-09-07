import Foundation
import CoreGraphics

/// Schema v1 UserDefaults keys (frozen). Never rename; future migrations add
/// new versions keyed by `settingsSchemaVersion`, they do not touch these.
private enum SettingsKey {
    static let schemaVersion = "settingsSchemaVersion"
    static let activationKeyCode = "activationKeyCode"
    static let activationModifierFlags = "activationModifierFlags"
    static let hintAlphabetKeyCodes = "hintAlphabetKeyCodes"
}

/// Owns persisted user settings (plan §3.26).
///
/// Load-time repair: a corrupt or invalid field resets ONLY that field to its
/// default, leaving every other stored value untouched. Setters validate the
/// same way: invalid input repairs that field to default and persists it.
@MainActor
final class SettingsStore: ObservableObject {

    static let defaultActivationKeyCode: UInt64 = VimotionKeys.spaceKeyCode // 0x31

    @Published private(set) var activationKeyCode: UInt64
    @Published private(set) var activationModifiers: CGEventFlags   // subset of cmd|shift|ctrl|opt, never empty
    @Published private(set) var hintAlphabet: [PhysicalKey]         // ≥4 distinct, no duplicates

    private let defaults: UserDefaults

    /// Modifier bits that may participate in the activation chord.
    static let allowedModifiers: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let keyCode = Self.loadValidatedKeyCode(defaults: defaults) ?? Self.defaultActivationKeyCode
        let modifiers = Self.loadValidatedModifiers(defaults: defaults) ?? Self.defaultModifiers
        let alphabet = Self.loadValidatedAlphabet(defaults: defaults) ?? PhysicalKey.defaultAlphabetOrder

        self.activationKeyCode = keyCode
        self.activationModifiers = modifiers
        self.hintAlphabet = alphabet

        // Persist repaired/default values so the store is always self-healing.
        persistSchemaVersionIfNeeded()
        persistActivation(keyCode: keyCode, modifiers: modifiers)
        persistAlphabet(alphabet)
    }

    // MARK: - Defaults

    static var defaultModifiers: CGEventFlags { [.maskCommand, .maskShift] }

    // MARK: - Mutation

    func setActivation(keyCode: UInt64, modifiers: CGEventFlags) {
        let masked = modifiers.intersection(Self.allowedModifiers)
        guard Self.isValid(keyCode: keyCode), !masked.isEmpty else {
            applyDefaultActivation()
            return
        }
        activationKeyCode = keyCode
        activationModifiers = masked
        persistActivation(keyCode: keyCode, modifiers: masked)
    }

    func setHintAlphabet(_ keys: [PhysicalKey]) {
        guard Self.validate(alphabet: keys) else {
            hintAlphabet = PhysicalKey.defaultAlphabetOrder
            persistAlphabet(PhysicalKey.defaultAlphabetOrder)
            return
        }
        hintAlphabet = keys
        persistAlphabet(keys)
    }

    // MARK: - Validation

    /// ≥4 distinct keys, no duplicates. Keys are `PhysicalKey`, so no modifier
    /// keys can ever appear; the activation base key may coincide with a hint
    /// key because activation requires modifiers.
    static func validate(alphabet: [PhysicalKey]) -> Bool {
        Set(alphabet).count == alphabet.count && alphabet.count >= 4
    }

    static func isValid(modifiers: CGEventFlags) -> Bool {
        let masked = modifiers.intersection(allowedModifiers)
        return masked == modifiers && !masked.isEmpty
    }

    static func isValid(keyCode: UInt64) -> Bool {
        keyCode <= UInt64(Int.max)
    }

    /// Current activation as consumed by the event-tap gate.
    var activationChord: ActivationChord {
        ActivationChord(keyCode: activationKeyCode, requiredFlags: activationModifiers)
    }

    func setActivation(_ chord: ActivationChord) {
        setActivation(keyCode: chord.keyCode, modifiers: chord.requiredFlags)
    }

    // MARK: - Loading + repair

    private static func loadValidatedKeyCode(defaults: UserDefaults) -> UInt64? {
        guard let raw = defaults.object(forKey: SettingsKey.activationKeyCode) as? Int,
              raw >= 0,
              let keyCode = UInt64(exactly: raw),
              isValid(keyCode: keyCode)
        else { return nil }
        return keyCode
    }

    private static func loadValidatedModifiers(defaults: UserDefaults) -> CGEventFlags? {
        guard let raw = defaults.object(forKey: SettingsKey.activationModifierFlags) as? Int
        else { return nil }
        let flags = CGEventFlags(rawValue: UInt64(bitPattern: Int64(raw)))
        guard Self.isValid(modifiers: flags) else { return nil }
        return flags
    }

    private static func loadValidatedAlphabet(defaults: UserDefaults) -> [PhysicalKey]? {
        guard let codes = defaults.array(forKey: SettingsKey.hintAlphabetKeyCodes) as? [Int],
              !codes.isEmpty
        else { return nil }
        var keys: [PhysicalKey] = []
        keys.reserveCapacity(codes.count)
        for code in codes {
            guard code >= 0, let key = PhysicalKey(cgKeyCode: UInt64(code)) else {
                return nil // out-of-domain keycode (negative or unknown) → corrupt field
            }
            keys.append(key)
        }
        guard validate(alphabet: keys) else { return nil }
        return keys
    }

    private func persistSchemaVersionIfNeeded() {
        if (defaults.object(forKey: SettingsKey.schemaVersion) as? Int) != Self.schemaVersionValue {
            defaults.set(Self.schemaVersionValue, forKey: SettingsKey.schemaVersion)
        }
    }

    static let schemaVersionValue = 1

    private func applyDefaultActivation() {
        activationKeyCode = Self.defaultActivationKeyCode
        activationModifiers = Self.defaultModifiers
        persistActivation(keyCode: Self.defaultActivationKeyCode, modifiers: Self.defaultModifiers)
    }

    private func persistActivation(keyCode: UInt64, modifiers: CGEventFlags) {
        defaults.set(Int(keyCode), forKey: SettingsKey.activationKeyCode)
        // UInt64 rawValue stored as Int; the allowed modifier masks keep this
        // lossless on all supported 64-bit hosts.
        defaults.set(Int(bitPattern: UInt(truncatingIfNeeded: modifiers.rawValue)),
                     forKey: SettingsKey.activationModifierFlags)
    }

    private func persistAlphabet(_ keys: [PhysicalKey]) {
        defaults.set(keys.map { Int($0.cgKeyCode) }, forKey: SettingsKey.hintAlphabetKeyCodes)
    }
}
