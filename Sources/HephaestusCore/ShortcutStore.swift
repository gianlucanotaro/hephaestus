import AppKit
import Carbon.HIToolbox

// Where every hotkey lives in UserDefaults, and how it is read / written.
//
// Storage is backward compatible: modifier masks keep their existing keys (and Carbon-mask format), and each hotkey
// whose key used to be fixed gets one NEW key-code key whose registered default is the old fixed key. Hotkeys that
// used to share one modifiers key (direct snap, zone cycling) now each have their own; `ShortcutMigration` copies a
// user-chosen shared value into the new keys once, before defaults are registered.

enum ShortcutKind: Equatable {
    /// One (keyCode, modifiers) pair, clearable (keyCode -1 = off).
    case single
    /// Fixed keys, configurable modifiers (the recorder takes the modifiers of a pressed key from `keys`).
    case group(keys: [Int])
    /// One modifier + key, stored as `Prefs.rotationModifierKey` (name) and `Prefs.rotationKeyCodeKey`.
    case rotation
}

struct ShortcutSpec {
    let id: ShortcutID
    let title: String
    let kind: ShortcutKind
    /// nil for groups (their keys are fixed).
    let keyCodeKey: String?
    let modifiersKey: String
    let defaultShortcut: Shortcut

    var canClear: Bool { kind == .single }
    var mode: RecorderMode {
        switch kind {
        case .single: return .any
        case .group(let keys): return .keys(keys)
        case .rotation: return .rotation
        }
    }
}

extension Prefs {
    static let directFirstKeyKey = "keyboardNavDirectFirstKey"
    static let directMiddleKeyKey = "keyboardNavDirectMiddleKey"
    static let directMiddleModifiersKey = "keyboardNavDirectMiddleModifiers"
    static let directLastKeyKey = "keyboardNavDirectLastKey"
    static let directLastModifiersKey = "keyboardNavDirectLastModifiers"
    static let previewKeyKey = "previewHotkeyKeyCode"
    static let previewModifiersKey = "previewHotkeyModifiers"
    static let cycleNextKeyKey = "zoneCycleNextKey"
    static let cyclePreviousKeyKey = "zoneCyclePreviousKey"
    static let cyclePreviousModifiersKey = "zoneCyclePreviousModifiers"
    static let editorHotkeyKeyCodeKey = "editorHotkeyKeyCode"

    /// Registers the key-code / modifier keys that are new in the settings work. Existing keys keep their own
    /// registration (`registerKeyboardNavDefaults` etc.); registering a key twice with the same value is harmless.
    static func registerShortcutDefaults() {
        var d: [String: Any] = [:]
        for spec in ShortcutSpecs.all where spec.kind != .rotation {
            if let k = spec.keyCodeKey { d[k] = spec.defaultShortcut.keyCode }
            d[spec.modifiersKey] = spec.defaultShortcut.modifiers.carbon
        }
        UserDefaults.standard.register(defaults: d)
    }
}

enum ShortcutSpecs {
    private static let ctrlOpt = HotkeyModifiers.controlOption

    static let all: [ShortcutSpec] = [
        ShortcutSpec(id: .directFirst, title: "Snap to first zone", kind: .single, keyCodeKey: Prefs.directFirstKeyKey,
                     modifiersKey: Prefs.navDirectModifiersKey, defaultShortcut: Shortcut(keyCode: kVK_LeftArrow, modifiers: ctrlOpt)),
        ShortcutSpec(id: .directMiddle, title: "Snap to middle zone", kind: .single, keyCodeKey: Prefs.directMiddleKeyKey,
                     modifiersKey: Prefs.directMiddleModifiersKey, defaultShortcut: Shortcut(keyCode: kVK_UpArrow, modifiers: ctrlOpt)),
        ShortcutSpec(id: .directLast, title: "Snap to last zone", kind: .single, keyCodeKey: Prefs.directLastKeyKey,
                     modifiersKey: Prefs.directLastModifiersKey, defaultShortcut: Shortcut(keyCode: kVK_RightArrow, modifiers: ctrlOpt)),
        ShortcutSpec(id: .navMove, title: "Move to zone (arrow keys)", kind: .group(keys: KeyNames.arrows), keyCodeKey: nil,
                     modifiersKey: Prefs.navMoveModifiersKey, defaultShortcut: Shortcut(keyCode: kVK_LeftArrow, modifiers: ctrlOpt)),
        ShortcutSpec(id: .navExpand, title: "Expand to adjacent zone (arrow keys)", kind: .group(keys: KeyNames.arrows), keyCodeKey: nil,
                     modifiersKey: Prefs.navExpandModifiersKey, defaultShortcut: Shortcut(keyCode: kVK_LeftArrow, modifiers: .controlOptionShift)),
        ShortcutSpec(id: .preview, title: "Show zones", kind: .single, keyCodeKey: Prefs.previewKeyKey,
                     modifiersKey: Prefs.previewModifiersKey, defaultShortcut: Shortcut(keyCode: kVK_ANSI_Z, modifiers: ctrlOpt)),
        ShortcutSpec(id: .cycleNext, title: "Next window in zone", kind: .single, keyCodeKey: Prefs.cycleNextKeyKey,
                     modifiersKey: Prefs.zoneCycleModifiersKey, defaultShortcut: Shortcut(keyCode: kVK_PageDown, modifiers: ctrlOpt)),
        ShortcutSpec(id: .cyclePrevious, title: "Previous window in zone", kind: .single, keyCodeKey: Prefs.cyclePreviousKeyKey,
                     modifiersKey: Prefs.cyclePreviousModifiersKey, defaultShortcut: Shortcut(keyCode: kVK_PageUp, modifiers: ctrlOpt)),
        ShortcutSpec(id: .layoutNumbers, title: "Apply layout by number (0-9)", kind: .group(keys: KeyNames.digits), keyCodeKey: nil,
                     modifiersKey: Prefs.layoutHotkeyModifiersKey, defaultShortcut: Shortcut(keyCode: kVK_ANSI_0, modifiers: .controlOptionCommand)),
        ShortcutSpec(id: .openEditor, title: "Open layout editor", kind: .single, keyCodeKey: Prefs.editorHotkeyKeyCodeKey,
                     modifiersKey: Prefs.editorHotkeyModifiersKey, defaultShortcut: Shortcut(keyCode: kVK_ANSI_E, modifiers: .controlOptionCommand)),
        ShortcutSpec(id: .rotation, title: "Rotate windows across monitors", kind: .rotation, keyCodeKey: Prefs.rotationKeyCodeKey,
                     modifiersKey: Prefs.rotationModifierKey, defaultShortcut: Shortcut(keyCode: kVK_ANSI_X, modifiers: .option)),
    ]

    static func spec(_ id: ShortcutID) -> ShortcutSpec { all.first { $0.id == id }! }
}

enum ShortcutStore {
    /// The configured shortcut; nil when cleared / disabled. Groups return their first key with the stored modifiers.
    static func read(_ id: ShortcutID, defaults: UserDefaults = .standard) -> Shortcut? {
        let spec = ShortcutSpecs.spec(id)
        switch spec.kind {
        case .rotation:
            let name = defaults.string(forKey: spec.modifiersKey) ?? ""
            let mod = RotationModifier(rawValue: name) ?? .option
            return Shortcut(keyCode: defaults.object(forKey: Prefs.rotationKeyCodeKey) as? Int ?? spec.defaultShortcut.keyCode,
                            modifiers: mod.hotkeyModifiers)
        case .single:
            let key = defaults.object(forKey: spec.keyCodeKey!) as? Int ?? spec.defaultShortcut.keyCode
            let mods = HotkeyModifiers(carbon: defaults.object(forKey: spec.modifiersKey) as? Int ?? spec.defaultShortcut.modifiers.carbon)
            guard key >= 0, mods.isValid else { return nil }
            return Shortcut(keyCode: key, modifiers: mods)
        case .group(let keys):
            let mods = HotkeyModifiers(carbon: defaults.object(forKey: spec.modifiersKey) as? Int ?? spec.defaultShortcut.modifiers.carbon)
            guard mods.isValid else { return nil }
            return Shortcut(keyCode: keys[0], modifiers: mods)
        }
    }

    static func write(_ shortcut: Shortcut?, for id: ShortcutID, defaults: UserDefaults = .standard) {
        let spec = ShortcutSpecs.spec(id)
        switch spec.kind {
        case .rotation:
            guard let s = shortcut, let mod = RotationModifier(hotkeyModifiers: s.modifiers) else { return }
            defaults.set(mod.rawValue, forKey: spec.modifiersKey)
            defaults.set(s.keyCode, forKey: Prefs.rotationKeyCodeKey)
        case .single:
            if let s = shortcut {
                defaults.set(s.keyCode, forKey: spec.keyCodeKey!)
                defaults.set(s.modifiers.carbon, forKey: spec.modifiersKey)
            } else {
                defaults.set(-1, forKey: spec.keyCodeKey!)
            }
        case .group:
            defaults.set(shortcut?.modifiers.carbon ?? 0, forKey: spec.modifiersKey)
        }
    }

    /// All combinations an id occupies.
    static func combos(_ id: ShortcutID, defaults: UserDefaults = .standard) -> [Shortcut] {
        guard let s = read(id, defaults: defaults) else { return [] }
        if case .group(let keys) = ShortcutSpecs.spec(id).kind { return keys.map { Shortcut(keyCode: $0, modifiers: s.modifiers) } }
        return [s]
    }

    /// Entries for the duplicate checker. Only hotkeys that are currently registered count as active.
    static func entries(defaults: UserDefaults = .standard) -> [ShortcutEntry] {
        let mode = KeyboardNavMode(rawValue: defaults.string(forKey: Prefs.navModeKey) ?? "") ?? .direct
        let cycling = defaults.object(forKey: Prefs.zoneCycleEnabledKey) as? Bool ?? true
        let rotation = defaults.bool(forKey: Prefs.rotationEnabledKey)
        return ShortcutID.allCases.map { id in
            var active = true
            switch id {
            case .directFirst, .directMiddle, .directLast: active = mode == .direct
            case .navMove: active = mode != .direct
            case .navExpand: active = mode == .relative
            case .cycleNext, .cyclePrevious: active = cycling
            case .rotation: active = rotation
            default: break
            }
            return ShortcutEntry(id: id, combos: combos(id, defaults: defaults), active: active)
        }
    }
}

extension RotationModifier {
    var hotkeyModifiers: HotkeyModifiers {
        switch self {
        case .option: return .option
        case .control: return .control
        case .command: return .command
        case .shift: return .shift
        }
    }
    init?(hotkeyModifiers m: HotkeyModifiers) {
        guard let match = Self.allCases.first(where: { $0.hotkeyModifiers == m }) else { return nil }
        self = match
    }
}

/// One-time copy of values stored under the OLD shared keys into the new per-hotkey keys. `run` must happen before
/// defaults are registered (so only values the user actually set are seen). Idempotent.
enum ShortcutMigration {
    static let watchedKeys = [Prefs.navDirectModifiersKey, Prefs.zoneCycleModifiersKey, Prefs.editorHotkeyLetterKey,
                              Prefs.directMiddleModifiersKey, Prefs.directLastModifiersKey,
                              Prefs.cyclePreviousModifiersKey, Prefs.editorHotkeyKeyCodeKey]

    /// Pure: the values to write, given the values the user has stored (absent key = never set).
    static func plan(userValues v: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        func copy(_ from: String, to keys: [String]) {
            guard let value = v[from] else { return }
            for k in keys where v[k] == nil { out[k] = value }
        }
        copy(Prefs.navDirectModifiersKey, to: [Prefs.directMiddleModifiersKey, Prefs.directLastModifiersKey])
        copy(Prefs.zoneCycleModifiersKey, to: [Prefs.cyclePreviousModifiersKey])
        if v[Prefs.editorHotkeyKeyCodeKey] == nil, let letter = v[Prefs.editorHotkeyLetterKey] as? String,
           let code = LayoutHotkeyKeys.keyCode(forLetter: letter) {
            out[Prefs.editorHotkeyKeyCodeKey] = code
        }
        return out
    }

    static func run(defaults: UserDefaults = .standard) {
        var user: [String: Any] = [:]
        for k in watchedKeys { if let v = defaults.object(forKey: k) { user[k] = v } }
        for (k, v) in plan(userValues: user) { defaults.set(v, forKey: k) }
    }
}
