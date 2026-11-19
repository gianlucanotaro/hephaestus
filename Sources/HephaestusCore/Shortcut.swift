import AppKit
import Carbon.HIToolbox

// Pure shortcut model shared by every hotkey: modifiers, (keyCode, modifiers) pairs, key names, the recorder's
// accept/reject policy and the duplicate checker. No UI and no registration here, so everything is unit-tested.

/// Carbon modifier mask (`controlKey` etc.) as an option set. THE modifier type: stored values are plain Carbon masks.
struct HotkeyModifiers: OptionSet, Equatable, Hashable {
    let rawValue: Int
    static let control = HotkeyModifiers(rawValue: controlKey)
    static let option = HotkeyModifiers(rawValue: optionKey)
    static let shift = HotkeyModifiers(rawValue: shiftKey)
    static let command = HotkeyModifiers(rawValue: cmdKey)
    static let controlOption: HotkeyModifiers = [.control, .option]
    static let controlOptionShift: HotkeyModifiers = [.control, .option, .shift]
    static let controlOptionCommand: HotkeyModifiers = [.control, .option, .command]
    static let all: HotkeyModifiers = [.control, .option, .shift, .command]

    init(rawValue: Int) { self.rawValue = rawValue }
    /// Unknown bits are dropped.
    init(carbon: Int) { self.rawValue = carbon & Self.all.rawValue }
    /// From AppKit event flags (device-independent bits only).
    init(flags: NSEvent.ModifierFlags) {
        var m: HotkeyModifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        self = m
    }
    var carbon: Int { rawValue }
    /// A global hotkey needs at least one modifier, otherwise it would hijack plain typing.
    var isValid: Bool { !isEmpty }
    var count: Int { [Self.control, .option, .shift, .command].filter(contains).count }
    var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
    /// Masks to the four supported flags; falls back when none is left (a bare key must never be global).
    static func sanitized(_ raw: Int, fallback: Int) -> Int {
        let m = raw & all.rawValue
        return m == 0 ? fallback : m
    }
}

/// A key plus modifiers. Hotkeys are always valid only with at least one modifier.
struct Shortcut: Equatable, Hashable {
    var keyCode: Int
    var modifiers: HotkeyModifiers

    var display: String { modifiers.symbols + KeyNames.name(for: keyCode) }
}

/// Human-readable key names for virtual key codes (ANSI layout).
enum KeyNames {
    static let table: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12",
        115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4", 119: "End", 120: "F2", 121: "Page Down",
        122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    static func name(for keyCode: Int) -> String { table[keyCode] ?? "Key \(keyCode)" }
    static let arrows = [kVK_LeftArrow, kVK_UpArrow, kVK_DownArrow, kVK_RightArrow].map { Int($0) }
    static let digits = LayoutHotkeyKeys.digitKeyCodes
}

// MARK: - Recorder policy

/// What the recorder accepts besides "at least one modifier".
enum RecorderMode: Equatable {
    /// Any key.
    case any
    /// Only these keys; the shortcut's modifiers are what is stored (the keys stay fixed, e.g. arrows).
    case keys([Int])
    /// Exactly one modifier plus a non-arrow key (rotation: hold the chord, then press ← / →).
    case rotation
}

enum RecorderOutcome: Equatable {
    case cancelled, cleared
    case rejected(String)
    case accepted(Shortcut)
}

enum RecorderPolicy {
    static func evaluate(keyCode: Int, modifiers: HotkeyModifiers, mode: RecorderMode, canClear: Bool) -> RecorderOutcome {
        if modifiers.isEmpty {
            switch keyCode {
            case Int(kVK_Escape): return .cancelled
            case Int(kVK_Delete), Int(kVK_ForwardDelete):
                return canClear ? .cleared : .rejected("This shortcut cannot be cleared.")
            default: return .rejected("Add at least one modifier (⌃ ⌥ ⇧ ⌘).")
            }
        }
        switch mode {
        case .any: break
        case .keys(let allowed):
            guard allowed.contains(keyCode) else {
                return .rejected("Use \(allowed.map(KeyNames.name(for:)).joined(separator: " ")) with your modifiers.")
            }
        case .rotation:
            guard modifiers.count == 1 else { return .rejected("Rotation uses exactly one modifier plus a key.") }
            guard !KeyNames.arrows.contains(keyCode) else { return .rejected("Arrow keys are used to rotate; pick another key.") }
        }
        return .accepted(Shortcut(keyCode: keyCode, modifiers: modifiers))
    }
}

// MARK: - Duplicate detection

enum ShortcutID: String, CaseIterable {
    case directFirst, directMiddle, directLast, navMove, navExpand
    case preview, cycleNext, cyclePrevious, layoutNumbers, openEditor, rotation
    case pinWindow
}

/// The key combinations an id occupies (several for groups such as the four arrows) and whether it is in effect.
struct ShortcutEntry: Equatable {
    var id: ShortcutID
    var combos: [Shortcut]
    var active: Bool
}

enum ShortcutConflicts {
    /// Other ACTIVE entries sharing at least one combination with `id` (empty when `id` itself is inactive).
    static func conflicts(of id: ShortcutID, in entries: [ShortcutEntry]) -> [ShortcutID] {
        guard let mine = entries.first(where: { $0.id == id }), mine.active else { return [] }
        let own = Set(mine.combos)
        return entries.filter { $0.id != id && $0.active && !own.isDisjoint(with: $0.combos) }.map(\.id)
    }
}

/// Combos the system refused to register. Pure bookkeeping; `HotKeys` feeds it.
struct RegistrationFailures: Equatable {
    private(set) var failed: Set<Shortcut> = []
    mutating func record(_ shortcut: Shortcut, succeeded: Bool) {
        if succeeded { failed.remove(shortcut) } else { failed.insert(shortcut) }
    }
    func contains(anyOf shortcuts: [Shortcut]) -> Bool { shortcuts.contains(where: failed.contains) }
}
