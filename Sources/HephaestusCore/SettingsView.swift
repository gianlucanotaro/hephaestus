import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.aspectWKey) private var aspectW = 16.0
    @AppStorage(Prefs.aspectHKey) private var aspectH = 9.0
    @AppStorage(Prefs.gapKey) private var gap = 8.0
    @AppStorage(Prefs.dragActivationKey) private var dragActivation = DragActivation.shift.rawValue
    @AppStorage(Prefs.multiZoneModifierKey) private var multiZoneModifier = MultiZoneModifier.control.rawValue
    @AppStorage(Prefs.showAllScreensKey) private var showAllScreens = false
    @AppStorage(Prefs.useSystemColorsKey) private var useSystemColors = true
    @AppStorage(Prefs.highlightColorKey) private var highlightColor = "#0A84FF"
    @AppStorage(Prefs.inactiveColorKey) private var inactiveColor = "#8E8E93"
    @AppStorage(Prefs.borderColorKey) private var borderColor = "#0A84FF"
    @AppStorage(Prefs.numberColorKey) private var numberColor = "#FFFFFF"
    @AppStorage(Prefs.opacityKey) private var opacity = 0.5
    @AppStorage(Prefs.showNumbersKey) private var showNumbers = true
    var onChange: () -> Void

    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hex: hex.wrappedValue) ?? .gray) },
                set: { hex.wrappedValue = NSColor($0).hexString })
    }

    var body: some View {
        ScrollView {
            content.padding(20)
        }
        .frame(width: 460, height: 640)
        .onChange(of: aspectW) { _ in onChange() }
        .onChange(of: aspectH) { _ in onChange() }
        .onChange(of: gap) { _ in onChange() }
    }

    /// One stack of sections. Dividers live HERE only; section views start with their own heading.
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Zones").font(.headline)
            Text("Aspect ratio applies to Ultrawide 3-way on every screen; layouts are chosen per screen from the menu bar.").font(.footnote).foregroundStyle(.secondary)
            HStack {
                Text("Center aspect (Ultrawide 3-way)")
                TextField("W", value: $aspectW, format: .number).frame(width: 50)
                Text(":")
                TextField("H", value: $aspectH, format: .number).frame(width: 50)
            }
            HStack {
                Text("Gap")
                Slider(value: $gap, in: 0...40, step: 1)
                Text("\(Int(gap)) px").monospacedDigit().frame(width: 50, alignment: .trailing)
            }
            Picker("Drag to snap", selection: $dragActivation) {
                ForEach(DragActivation.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Span multiple zones", selection: $multiZoneModifier) {
                ForEach(MultiZoneModifier.allCases, id: \.rawValue) { Text("Hold \($0.title)").tag($0.rawValue) }
            }
            Text("Or drop near the edge between two zones. The middle mouse button also toggles spanning (not in mouse-button activation mode).")
                .font(.footnote).foregroundStyle(.secondary)
            Toggle("Show zones on all screens while dragging", isOn: $showAllScreens)
            Text("Off: only the screen under the cursor.").font(.footnote).foregroundStyle(.secondary)
            SpacingSettingsView()
            Divider()
            Text("Appearance").font(.headline)
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
            Divider()
            KeyboardNavSettingsView()
            Divider()
            EligibilitySettingsView()
            Divider()
            WindowStateSettings()
            Divider()
            NewWindowPlacementSettings()
            Divider()
            ZoneCycleSettings()
            Divider()
            RotationSettingsView()
            Divider()
            LayoutHotkeysSettingsView()
            Divider()
            LayoutIndicatorSettingsView()
            Divider()
            Text("Choose the layout from the menu bar; the editors are under its Layout submenu. The full hotkey list is in the README.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
