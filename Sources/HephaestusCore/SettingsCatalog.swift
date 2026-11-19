import Foundation

/// Tabs of the settings window, in display order.
enum SettingsTab: String, CaseIterable {
    case general = "General", activation = "Activation", layouts = "Layouts", windows = "Windows"
    case appearance = "Appearance", shortcuts = "Shortcuts"
}

/// Maps every UserDefaults key the app registers to the settings tab that exposes it, or lists it as internal
/// (persistence blobs, legacy keys). `SettingsCatalogTests` fails when a registered key is in neither list, so a new
/// setting cannot silently miss the UI. When you add a setting: put its control in the matching tab view AND list it here.
enum SettingsCatalog {
    static let exposed: [String: SettingsTab] = {
        var m: [String: SettingsTab] = [:]
        func add(_ tab: SettingsTab, _ keys: [String]) { keys.forEach { m[$0] = tab } }
        add(.activation, [Prefs.dragActivationKey, Prefs.multiZoneModifierKey, Prefs.wheelCycleKey,
                          Prefs.showAllScreensKey, Prefs.edgeThresholdKey])
        add(.layouts, [Prefs.aspectWKey, Prefs.aspectHKey, Prefs.gapKey, Prefs.layoutGapOverridesKey,
                       Prefs.spanScreensKey, Prefs.layoutHotkeyMapKey, Prefs.screenLayoutsKey,
                       Prefs.defaultLayoutLandscapeKey, Prefs.defaultLayoutPortraitKey])
        add(.windows, [Prefs.allowDialogsKey, Prefs.allowFloatingKey, Prefs.allowChildWindowsKey, Prefs.excludedAppsKey,
                       Prefs.overlapResolutionKey, Prefs.restoreSizeOnUnsnapKey, Prefs.reapplyOnDisplayChangeKey,
                       Prefs.reapplyOnLayoutChangeKey, Prefs.newWindowLastZoneKey, Prefs.newWindowActiveScreenKey,
                       Prefs.zoneCycleEnabledKey, Prefs.rotationEnabledKey, Prefs.pinnedWindowsEnabledKey])
        add(.appearance, [Prefs.useSystemColorsKey, Prefs.highlightColorKey, Prefs.inactiveColorKey, Prefs.borderColorKey,
                          Prefs.numberColorKey, Prefs.opacityKey, Prefs.showNumbersKey, Prefs.flashZonesKey,
                          Prefs.indicatorEnabledKey, Prefs.indicatorPositionKey, Prefs.indicatorTextColorKey,
                          Prefs.indicatorBackgroundColorKey, Prefs.indicatorTextSizeKey, Prefs.indicatorPaddingKey,
                          Prefs.indicatorDurationKey])
        add(.shortcuts, [Prefs.navModeKey, Prefs.navCrossScreensKey])
        // Every key behind a recorder.
        for spec in ShortcutSpecs.all {
            add(.shortcuts, [spec.modifiersKey] + (spec.keyCodeKey.map { [$0] } ?? []))
        }
        return m
    }()

    /// Registered or stored, deliberately without a control.
    static let internalKeys: Set<String> = [
        Prefs.activeLayoutKey,          // global fallback layout; per-screen pickers + orientation defaults replace it
        Prefs.editorHotkeyLetterKey,    // legacy letter, migrated into editorHotkeyKeyCode by ShortcutMigration
        "windowTrackerState",           // persistence blob (WindowTracker)
    ]
}
