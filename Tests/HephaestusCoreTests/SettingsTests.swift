import Carbon.HIToolbox
import Foundation
import Testing
@testable import HephaestusCore

private func suite() -> UserDefaults { UserDefaults(suiteName: "hephaestus-settings-\(UUID().uuidString)")! }

@Suite struct RecorderPolicyTests {
    private func eval(_ key: Int, _ mods: HotkeyModifiers, _ mode: RecorderMode = .any, clear: Bool = true) -> RecorderOutcome {
        RecorderPolicy.evaluate(keyCode: key, modifiers: mods, mode: mode, canClear: clear)
    }

    @Test func acceptsKeyWithModifier() {
        #expect(eval(kVK_ANSI_Z, .controlOption) == .accepted(Shortcut(keyCode: kVK_ANSI_Z, modifiers: .controlOption)))
    }
    @Test func rejectsBareKey() {
        guard case .rejected = eval(kVK_ANSI_Z, []) else { Issue.record("expected rejection"); return }
    }
    @Test func escapeCancelsAndDeleteClears() {
        #expect(eval(kVK_Escape, []) == .cancelled)
        #expect(eval(kVK_Delete, []) == .cleared)
        #expect(eval(kVK_ForwardDelete, []) == .cleared)
        guard case .rejected = eval(kVK_Delete, [], clear: false) else { Issue.record("expected rejection"); return }
    }
    @Test func modifiedDeleteIsAKey() {
        #expect(eval(kVK_Delete, .command) == .accepted(Shortcut(keyCode: kVK_Delete, modifiers: .command)))
    }
    @Test func keyRestrictedModes() {
        #expect(eval(kVK_LeftArrow, .controlOption, .keys(KeyNames.arrows)) != .cancelled)
        guard case .rejected = eval(kVK_ANSI_A, .controlOption, .keys(KeyNames.arrows)) else { Issue.record("expected rejection"); return }
    }
    @Test func rotationNeedsExactlyOneModifierAndNoArrow() {
        #expect(eval(kVK_ANSI_X, .option, .rotation) == .accepted(Shortcut(keyCode: kVK_ANSI_X, modifiers: .option)))
        guard case .rejected = eval(kVK_ANSI_X, .controlOption, .rotation) else { Issue.record("two modifiers"); return }
        guard case .rejected = eval(kVK_LeftArrow, .option, .rotation) else { Issue.record("arrow"); return }
    }
}

@Suite struct ShortcutModelTests {
    @Test func displayAndNames() {
        #expect(Shortcut(keyCode: kVK_ANSI_E, modifiers: .controlOptionCommand).display == "⌃⌥⌘E")
        #expect(Shortcut(keyCode: kVK_PageDown, modifiers: [.control, .shift]).display == "⌃⇧Page Down")
        #expect(KeyNames.name(for: 9999) == "Key 9999")
    }
    @Test func modifiersFromAppKitFlags() {
        #expect(HotkeyModifiers(flags: [.control, .option, .capsLock]) == .controlOption)
        #expect(HotkeyModifiers(flags: [.command, .shift]).symbols == "⇧⌘")
    }
    @Test func sanitizedModifiers() {
        #expect(HotkeyModifiers.sanitized(0, fallback: controlKey) == controlKey)
        #expect(HotkeyModifiers.sanitized(cmdKey | 0x10000, fallback: optionKey) == cmdKey)
    }
    @Test func conflicts() {
        let a = Shortcut(keyCode: 1, modifiers: .control)
        let b = Shortcut(keyCode: 2, modifiers: .control)
        let entries = [ShortcutEntry(id: .preview, combos: [a], active: true),
                       ShortcutEntry(id: .openEditor, combos: [a, b], active: true),
                       ShortcutEntry(id: .cycleNext, combos: [a], active: false),
                       ShortcutEntry(id: .cyclePrevious, combos: [b], active: true)]
        #expect(ShortcutConflicts.conflicts(of: .preview, in: entries) == [.openEditor])
        #expect(Set(ShortcutConflicts.conflicts(of: .openEditor, in: entries)) == [.preview, .cyclePrevious])
        #expect(ShortcutConflicts.conflicts(of: .cycleNext, in: entries).isEmpty)   // inactive entries never warn
    }
    @Test func registrationFailures() {
        var f = RegistrationFailures()
        let s = Shortcut(keyCode: 6, modifiers: .controlOption)
        f.record(s, succeeded: false)
        #expect(f.contains(anyOf: [s]))
        f.record(s, succeeded: true)
        #expect(!f.contains(anyOf: [s]))
    }
}

@Suite struct ShortcutStoreTests {
    @Test func defaultsMatchTheOldHardCodedHotkeys() {
        let d = suite()
        #expect(ShortcutStore.read(.preview, defaults: d) == Shortcut(keyCode: kVK_ANSI_Z, modifiers: .controlOption))
        #expect(ShortcutStore.read(.cycleNext, defaults: d) == Shortcut(keyCode: kVK_PageDown, modifiers: .controlOption))
        #expect(ShortcutStore.read(.cyclePrevious, defaults: d) == Shortcut(keyCode: kVK_PageUp, modifiers: .controlOption))
        #expect(ShortcutStore.read(.openEditor, defaults: d) == Shortcut(keyCode: kVK_ANSI_E, modifiers: .controlOptionCommand))
        #expect(ShortcutStore.read(.rotation, defaults: d) == Shortcut(keyCode: kVK_ANSI_X, modifiers: .option))
        #expect(ShortcutStore.read(.directLast, defaults: d) == Shortcut(keyCode: kVK_RightArrow, modifiers: .controlOption))
        #expect(ShortcutStore.read(.navExpand, defaults: d)?.modifiers == .controlOptionShift)
    }
    @Test func writeReadRoundTripAndClear() {
        let d = suite()
        let s = Shortcut(keyCode: kVK_ANSI_K, modifiers: [.command, .shift])
        ShortcutStore.write(s, for: .preview, defaults: d)
        #expect(ShortcutStore.read(.preview, defaults: d) == s)
        ShortcutStore.write(nil, for: .preview, defaults: d)
        #expect(ShortcutStore.read(.preview, defaults: d) == nil)
        #expect(ShortcutStore.combos(.preview, defaults: d).isEmpty)
    }
    @Test func groupStoresModifiersOnly() {
        let d = suite()
        ShortcutStore.write(Shortcut(keyCode: kVK_DownArrow, modifiers: .command), for: .navMove, defaults: d)
        #expect(d.integer(forKey: Prefs.navMoveModifiersKey) == cmdKey)
        #expect(ShortcutStore.combos(.navMove, defaults: d).count == 4)
        #expect(ShortcutStore.combos(.layoutNumbers, defaults: d).count == 10)
    }
    @Test func rotationUsesNameAndKeyCode() {
        let d = suite()
        ShortcutStore.write(Shortcut(keyCode: kVK_ANSI_R, modifiers: .control), for: .rotation, defaults: d)
        #expect(d.string(forKey: Prefs.rotationModifierKey) == "control")
        #expect(d.integer(forKey: Prefs.rotationKeyCodeKey) == kVK_ANSI_R)
        #expect(ShortcutStore.read(.rotation, defaults: d) == Shortcut(keyCode: kVK_ANSI_R, modifiers: .control))
    }
    @Test func oldStoredValuesStillRead() {
        let d = suite()
        d.set(cmdKey | shiftKey, forKey: Prefs.navDirectModifiersKey)
        d.set(controlKey, forKey: Prefs.zoneCycleModifiersKey)
        d.set("K", forKey: Prefs.editorHotkeyLetterKey)
        let plan = ShortcutMigration.plan(userValues: [Prefs.navDirectModifiersKey: cmdKey | shiftKey, Prefs.zoneCycleModifiersKey: controlKey,
                                                      Prefs.editorHotkeyLetterKey: "K"])
        for (k, v) in plan { d.set(v, forKey: k) }
        #expect(ShortcutStore.read(.directFirst, defaults: d)?.modifiers == [.command, .shift])
        #expect(ShortcutStore.read(.directMiddle, defaults: d)?.modifiers == [.command, .shift])
        #expect(ShortcutStore.read(.directLast, defaults: d)?.modifiers == [.command, .shift])
        #expect(ShortcutStore.read(.cyclePrevious, defaults: d)?.modifiers == .control)
        #expect(ShortcutStore.read(.cycleNext, defaults: d)?.modifiers == .control)
        #expect(ShortcutStore.read(.openEditor, defaults: d)?.keyCode == kVK_ANSI_K)
        // Idempotent: a later user change to the new key is not overwritten.
        let again = ShortcutMigration.plan(userValues: [Prefs.navDirectModifiersKey: cmdKey, Prefs.directMiddleModifiersKey: optionKey,
                                                       Prefs.directLastModifiersKey: optionKey])
        #expect(again.isEmpty)
        #expect(ShortcutMigration.plan(userValues: [:]).isEmpty)
    }
    @Test func entriesRespectModeAndEnablement() {
        let d = suite()
        d.set(KeyboardNavMode.relative.rawValue, forKey: Prefs.navModeKey)
        let e = Dictionary(uniqueKeysWithValues: ShortcutStore.entries(defaults: d).map { ($0.id, $0.active) })
        #expect(e[.directFirst] == false)
        #expect(e[.navMove] == true && e[.navExpand] == true)
        #expect(e[.rotation] == false)
    }
    @Test func directBindingsFollowRecordedShortcuts() {
        var config = KeyboardNavConfig(mode: .direct, directModifiers: controlKey | optionKey, moveModifiers: controlKey,
                                       expandModifiers: shiftKey)
        #expect(config.bindings.map(\.keyCode) == [kVK_LeftArrow, kVK_UpArrow, kVK_RightArrow].map { Int($0) })
        config.direct = [Shortcut(keyCode: kVK_ANSI_1, modifiers: .command), nil, Shortcut(keyCode: kVK_ANSI_3, modifiers: .command)]
        #expect(config.bindings.map(\.keyCode) == [kVK_ANSI_1, kVK_ANSI_3].map { Int($0) })
    }
}

@Suite struct LaunchAtLoginTests {
    final class FakeService: LoginItemService {
        var status: LoginItemStatus = .notRegistered
        var failWith: Error?
        var openedSettings = 0
        func register() throws { if let failWith { throw failWith }; status = .enabled }
        func unregister() throws { if let failWith { throw failWith }; status = .notRegistered }
        func openSystemSettings() { openedSettings += 1 }
    }
    struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    @Test func stateMapping() {
        #expect(LaunchAtLoginState.make(status: .enabled, isAppBundle: true).isOn)
        #expect(!LaunchAtLoginState.make(status: .notRegistered, isAppBundle: true).isOn)
        let approval = LaunchAtLoginState.make(status: .requiresApproval, isAppBundle: true)
        #expect(approval.showsOpenSettings && approval.hint != nil && approval.canToggle)
        let notFound = LaunchAtLoginState.make(status: .notFound, isAppBundle: true)
        #expect(!notFound.canToggle && notFound.hint != nil)
        let noBundle = LaunchAtLoginState.make(status: .enabled, isAppBundle: false)
        #expect(!noBundle.canToggle && !noBundle.isOn && noBundle.hint != nil)
    }
    @Test func registerAndUnregister() {
        let service = FakeService()
        let model = LaunchAtLoginModel(service: service, isAppBundle: true)
        model.setEnabled(true)
        #expect(model.state.isOn && model.error == nil)
        model.setEnabled(false)
        #expect(!model.state.isOn)
    }
    @Test func errorsAreSurfacedAndStateReread() {
        let service = FakeService()
        service.failWith = Boom()
        let model = LaunchAtLoginModel(service: service, isAppBundle: true)
        model.setEnabled(true)
        #expect(model.error == "boom")
        #expect(!model.state.isOn)
        service.failWith = nil
        model.setEnabled(true)
        #expect(model.error == nil && model.state.isOn)
    }
    @Test func approvalOpensSettings() {
        let service = FakeService()
        let model = LaunchAtLoginModel(service: service, isAppBundle: true)
        model.openLoginItemsSettings()
        #expect(service.openedSettings == 1)
    }
    @Test func accessibilityText() {
        #expect(AccessibilityStatusText.message(trusted: false).contains("relaunch"))
        #expect(AccessibilityStatusText.message(trusted: true).contains("granted"))
    }
}

@Suite struct SettingsCatalogTests {
    /// Every registered default is either exposed in a settings tab or explicitly internal.
    @Test func everyRegisteredKeyIsCovered() {
        Prefs.register()
        // The registration domain also carries system keys (AppleLocale, NSLanguages, ...); only ours matter.
        let registered = Set(UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain).keys)
            .filter { !$0.hasPrefix("Apple") && !$0.hasPrefix("NS") }
        let known = Set(SettingsCatalog.exposed.keys).union(SettingsCatalog.internalKeys)
        #expect(registered.subtracting(known).isEmpty, "Registered but not in SettingsCatalog: \(registered.subtracting(known).sorted())")
        #expect(registered.count > 40)
    }
    @Test func exposedAndInternalAreDisjoint() {
        #expect(Set(SettingsCatalog.exposed.keys).isDisjoint(with: SettingsCatalog.internalKeys))
    }
    @Test func everyShortcutKeyIsOnTheShortcutsTab() {
        for spec in ShortcutSpecs.all {
            #expect(SettingsCatalog.exposed[spec.modifiersKey] != nil, "\(spec.id)")
            if let k = spec.keyCodeKey { #expect(SettingsCatalog.exposed[k] != nil, "\(spec.id)") }
        }
    }
    @Test func everyTabHasSettingsExceptGeneral() {
        let used = Set(SettingsCatalog.exposed.values)
        for tab in SettingsTab.allCases where tab != .general { #expect(used.contains(tab), "\(tab)") }
    }
    /// Unregistered keys that still hold user data are covered too.
    @Test func persistedKeysAreListed() {
        for k in [Prefs.screenLayoutsKey, Prefs.layoutHotkeyMapKey, Prefs.layoutGapOverridesKey,
                  Prefs.defaultLayoutLandscapeKey, Prefs.defaultLayoutPortraitKey] {
            #expect(SettingsCatalog.exposed[k] == .layouts)
        }
    }
}
