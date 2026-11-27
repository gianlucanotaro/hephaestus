import SwiftUI

/// The settings window: one tab per area. Each tab is a grouped `Form` (native cards, labels and controls aligned in
/// columns) made of `Section`s, one per feature; section views start with their own heading. Every setting appears in
/// exactly one tab (see `SettingsCatalog`).
struct SettingsView: View {
    var onChange: () -> Void

    var body: some View {
        TabView {
            tab(GeneralSettingsView()).tabItem { Label("General", systemImage: "gearshape") }
            tab(ActivationTab()).tabItem { Label("Activation", systemImage: "cursorarrow.motionlines") }
            tab(LayoutsTab(onChange: onChange)).tabItem { Label("Layouts", systemImage: "rectangle.split.3x1") }
            tab(WindowsTab()).tabItem { Label("Windows", systemImage: "macwindow") }
            tab(AppearanceTab()).tabItem { Label("Appearance", systemImage: "paintpalette") }
            tab(ShortcutsTab()).tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 560, height: 600)
    }

    private func tab<V: View>(_ content: V) -> some View {
        Form { content }.formStyle(.grouped)
    }
}

struct ActivationTab: View {
    @AppStorage(Prefs.dragActivationKey) private var dragActivation = Prefs.defaultDragActivation
    @AppStorage(Prefs.multiZoneModifierKey) private var multiZoneModifier = Prefs.defaultMultiZoneModifier
    @AppStorage(Prefs.showAllScreensKey) private var showAllScreens = Prefs.defaultShowAllScreens

    var body: some View {
        Section {
            Text("Dragging").settingsHeading()
            Picker("Drag to snap", selection: $dragActivation) {
                ForEach(DragActivation.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Span multiple zones", selection: $multiZoneModifier) {
                ForEach(MultiZoneModifier.allCases, id: \.rawValue) { Text("Hold \($0.title)").tag($0.rawValue) }
            }
            Text("Or drop near the edge between two zones. The middle mouse button also toggles spanning (not in mouse-button activation mode).")
                .settingsHint()
            EdgeThresholdSetting()
            Toggle("Show zones on all screens while dragging", isOn: $showAllScreens)
            Text("Off: only the screen under the cursor.").settingsHint()
        }
        Section { WheelCycleSetting() }
    }
}

struct LayoutsTab: View {
    @AppStorage(Prefs.aspectWKey) private var aspectW = Prefs.defaultAspectW
    @AppStorage(Prefs.aspectHKey) private var aspectH = Prefs.defaultAspectH
    @AppStorage(Prefs.gapKey) private var gap = Prefs.defaultGap
    var onChange: () -> Void

    var body: some View {
        Section { ScreenLayoutsSettingsView() }
        Section {
            Text("Zones").settingsHeading()
            LabeledContent("Center aspect (Ultrawide 3-way)") {
                HStack(spacing: 6) {
                    TextField("W", value: $aspectW, format: .number).frame(width: 48).multilineTextAlignment(.trailing)
                    Text(":")
                    TextField("H", value: $aspectH, format: .number).frame(width: 48)
                }
                .labelsHidden()
            }
            HStack {
                Text("Default gap")
                Slider(value: $gap, in: 0...40, step: 1)
                Text("\(Int(gap)) px").monospacedDigit().frame(width: 50, alignment: .trailing)
            }
            LayoutGapSettingsView()
            SpanScreensSetting()
        }
        .onChange(of: aspectW) { _ in onChange() }
        .onChange(of: aspectH) { _ in onChange() }
        .onChange(of: gap) { _ in onChange() }
        Section { LayoutHotkeysSettingsView() }
        Section { LayoutEditorButtons() }
    }
}

struct WindowsTab: View {
    var body: some View {
        Section { EligibilitySettingsView() }
        Section { WindowStateSettings() }
        Section { NewWindowPlacementSettings() }
        Section { ZoneCycleSettings() }
        Section { StackHoverSettings() }
        Section { RotationSettingsView() }
    }
}

struct AppearanceTab: View {
    @AppStorage(Prefs.useSystemColorsKey) private var useSystemColors = Prefs.defaultUseSystemColors
    @AppStorage(Prefs.highlightColorKey) private var highlightColor = Prefs.defaultHighlightColor
    @AppStorage(Prefs.inactiveColorKey) private var inactiveColor = Prefs.defaultInactiveColor
    @AppStorage(Prefs.borderColorKey) private var borderColor = Prefs.defaultBorderColor
    @AppStorage(Prefs.numberColorKey) private var numberColor = Prefs.defaultNumberColor
    @AppStorage(Prefs.opacityKey) private var opacity = Prefs.defaultOpacity
    @AppStorage(Prefs.showNumbersKey) private var showNumbers = Prefs.defaultShowNumbers
    @AppStorage(Prefs.flashZonesKey) private var flash = true

    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hex: hex.wrappedValue) ?? .gray) },
                set: { hex.wrappedValue = NSColor($0).hexString })
    }

    var body: some View {
        Section {
            Text("Zone overlay").settingsHeading()
            Toggle("Use system colors (follows light/dark mode)", isOn: $useSystemColors)
            if !useSystemColors {
                ColorPicker("Highlight", selection: colorBinding($highlightColor))
                ColorPicker("Inactive zone", selection: colorBinding($inactiveColor))
                ColorPicker("Border", selection: colorBinding($borderColor))
                ColorPicker("Number", selection: colorBinding($numberColor))
            }
            HStack {
                Text("Opacity")
                Slider(value: $opacity, in: 0.1...1)
                Text("\(Int(opacity * 100))%").monospacedDigit().frame(width: 50, alignment: .trailing)
            }
            Toggle("Show zone numbers", isOn: $showNumbers)
            Toggle("Flash zones when switching layout with a hotkey", isOn: $flash)
        }
        Section { LayoutIndicatorSettingsView() }
    }
}

struct ShortcutsTab: View {
    var body: some View {
        Section { KeyboardNavSettingsView() }
        Section {
            Text("Other shortcuts").settingsHeading()
            ShortcutRow(id: .preview)
            ShortcutRow(id: .cycleNext)
            ShortcutRow(id: .cyclePrevious)
            ShortcutRow(id: .layoutNumbers)
            ShortcutRow(id: .openEditor)
            ShortcutRow(id: .rotation)
            Text("Click a shortcut, then press the new combination. Esc cancels; Delete clears (where allowed). Every shortcut needs at least one modifier. Cycling and rotation shortcuts only work while those features are enabled (Windows tab).")
                .settingsHint()
        }
    }
}
