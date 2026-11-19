import AppKit
import Carbon.HIToolbox

// Quick layout switch hotkeys (issue #8). Number (0-9) -> layout id assignments.
//
// Storage deviates from "optional field on Layout": ONE `[number: layoutID]` map in UserDefaults covers built-in
// and custom layouts alike, which makes "one number, one layout" trivially atomic and keeps `layouts.json`
// (and layout import/export) untouched. Entries pointing at deleted layouts are ignored on lookup.

extension Prefs {
    static let layoutHotkeyMapKey = "layoutHotkeyNumbers"
    static let layoutHotkeyModifiersKey = "layoutHotkeyModifiers"
    static let flashZonesKey = "flashZonesOnSwitch"
    static let editorHotkeyModifiersKey = "editorHotkeyModifiers"
    static let editorHotkeyLetterKey = "editorHotkeyLetter"

    static func registerLayoutHotkeyDefaults() {
        UserDefaults.standard.register(defaults: [
            layoutHotkeyModifiersKey: HotkeyModifiers.controlOptionCommand.carbon,
            flashZonesKey: true,
            editorHotkeyModifiersKey: HotkeyModifiers.controlOptionCommand.carbon,
            editorHotkeyLetterKey: "E",
        ])
    }

    static var flashZonesOnSwitch: Bool { UserDefaults.standard.bool(forKey: flashZonesKey) }
    static var layoutHotkeyModifiers: HotkeyModifiers {
        HotkeyModifiers(carbon: UserDefaults.standard.integer(forKey: layoutHotkeyModifiersKey))
    }
}

/// Virtual key codes for the hotkeys of this feature.
enum LayoutHotkeyKeys {
    /// ANSI digit key codes, indexed by the digit.
    static let digitKeyCodes: [Int] = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                                       kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9].map { Int($0) }
    private static let letterKeyCodes: [Character: Int] = [
        "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D, "E": kVK_ANSI_E, "F": kVK_ANSI_F,
        "G": kVK_ANSI_G, "H": kVK_ANSI_H, "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
        "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P, "Q": kVK_ANSI_Q, "R": kVK_ANSI_R,
        "S": kVK_ANSI_S, "T": kVK_ANSI_T, "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
        "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z,
    ].mapValues { Int($0) }
    static let letters: [String] = letterKeyCodes.keys.map(String.init).sorted()

    static func keyCode(forLetter letter: String) -> Int? {
        guard letter.count == 1, let c = letter.uppercased().first else { return nil }
        return letterKeyCodes[c]
    }
}

/// Number (0-9) -> layout assignments. The map functions are pure; the instance wraps them with persistence.
struct LayoutHotkeys {
    static let didChange = Notification.Name("HephaestusLayoutHotkeysDidChange")
    static let validNumbers = 0...9
    static let shared = LayoutHotkeys()

    private let layouts: LayoutStore
    private let defaults: UserDefaults

    init(layouts: LayoutStore = .shared, defaults: UserDefaults = .standard) {
        self.layouts = layouts
        self.defaults = defaults
    }

    // MARK: Pure map operations

    /// Gives `layoutID` the number `number`: whoever held the number loses it, and the layout's previous number is freed.
    static func assigning(number: Int, layoutID: String, in map: [Int: String]) -> [Int: String] {
        guard validNumbers.contains(number) else { return map }
        var m = map.filter { $0.value != layoutID }
        m[number] = layoutID
        return m
    }

    static func removing(number: Int, from map: [Int: String]) -> [Int: String] {
        var m = map
        m.removeValue(forKey: number)
        return m
    }

    // MARK: Persistence

    /// Raw map (numbers 0-9 only); ids may refer to layouts that no longer exist.
    var map: [Int: String] {
        get {
            guard let data = defaults.data(forKey: Prefs.layoutHotkeyMapKey),
                  let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
            var m: [Int: String] = [:]
            for (k, v) in raw { if let n = Int(k), Self.validNumbers.contains(n) { m[n] = v } }
            return m
        }
        nonmutating set {
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), $0.value) })
            defaults.set(try? JSONEncoder().encode(raw), forKey: Prefs.layoutHotkeyMapKey)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    // MARK: Public API (also used by #9 wheel cycling and the CLI #17)

    /// The existing layout with this number, if any.
    func layout(forNumber number: Int) -> Layout? {
        map[number].flatMap { layouts.layout(id: $0) }
    }

    /// The number of `layoutID`, if it has one.
    func number(forLayoutID id: String) -> Int? {
        map.first { $0.value == id }?.key
    }

    func assign(number: Int, layoutID: String) {
        guard Self.validNumbers.contains(number), layouts.layout(id: layoutID) != nil else { return }
        map = Self.assigning(number: number, layoutID: layoutID, in: map)
    }

    func remove(number: Int) { map = Self.removing(number: number, from: map) }

    func removeNumber(ofLayoutID id: String) {
        if let n = number(forLayoutID: id) { remove(number: n) }
    }

    /// Numbers that currently resolve to an existing layout, ascending.
    var numbers: [Int] { map.keys.filter { layout(forNumber: $0) != nil }.sorted() }

    /// Layouts that have a number, in ascending number order (0 first).
    var orderedLayouts: [Layout] { numbers.compactMap { layout(forNumber: $0) } }
}
