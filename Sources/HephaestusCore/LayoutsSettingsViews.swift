import AppKit
import SwiftUI

// Layouts-tab sections that did not exist as menu-only features before: per-screen pickers, orientation defaults,
// per-layout gap and the editor buttons. They drive the same stores the menu bar uses.

/// Per-screen layout pickers and the landscape / portrait defaults for newly connected displays.
struct ScreenLayoutsSettingsView: View {
    @State private var tick = 0
    private var store: ScreenLayoutStore { .shared }

    private func screenBinding(_ screen: NSScreen) -> Binding<String> {
        Binding(get: { _ = tick; return ZoneLayout.layout(for: screen).id },
                set: { ZoneLayout.setLayout(id: $0, for: screen); tick += 1 })
    }

    private func defaultBinding(_ o: ScreenOrientation) -> Binding<String> {
        Binding(get: { _ = tick; return store.defaultLayout(for: o).id },
                set: { store.setDefaultLayout(id: $0, for: o); tick += 1 })
    }

    private func layoutOptions(_ layouts: [Layout]) -> some View {
        ForEach(layouts) { Text($0.name).tag($0.id) }
    }

    var body: some View {
        let layouts = LayoutStore.shared.all
        VStack(alignment: .leading, spacing: 8) {
            Text("Layout per screen").settingsHeading()
            ForEach(ZoneLayout.surfaceScreens(), id: \.displayID) { screen in
                Picker(Prefs.spanAllScreens ? "All screens" : screen.localizedName, selection: screenBinding(screen)) {
                    layoutOptions(layouts)
                }
            }
            Text("New screens get the default for their orientation.").settingsHint()
            Picker("Default for landscape screens", selection: defaultBinding(.landscape)) {
                layoutOptions(layouts)
            }
            Picker("Default for portrait screens", selection: defaultBinding(.portrait)) {
                layoutOptions(layouts)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ScreenLayoutStore.didChange)) { _ in tick += 1 }
        .onReceive(NotificationCenter.default.publisher(for: LayoutStore.didChange)) { _ in tick += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in tick += 1 }
    }
}

/// Gap override per layout ("Default" follows the global gap).
struct LayoutGapSettingsView: View {
    @State private var tick = 0
    /// Picker value meaning "follow the global gap".
    private static let followGlobal = -1

    private func current(_ layout: Layout) -> Int {
        _ = tick
        guard let g = layout.gap ?? Prefs.builtInGapOverrides[layout.id] else { return Self.followGlobal }
        return Int(g)
    }

    private func binding(_ layout: Layout) -> Binding<Int> {
        Binding(get: { current(layout) },
                set: { LayoutGapMenu.setGap($0 == Self.followGlobal ? nil : Double($0), forLayoutID: layout.id); tick += 1 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Gap per layout").settingsHeading()
            ForEach(LayoutStore.shared.all) { layout in
                let value = current(layout)
                Picker(layout.name, selection: binding(layout)) {
                    Text("Default (\(Int(Prefs.gap)) pt)").tag(Self.followGlobal)
                    ForEach(LayoutGapMenu.presets.map(Int.init), id: \.self) { Text("\($0) pt").tag($0) }
                    if value != Self.followGlobal, !LayoutGapMenu.presets.contains(Double(value)) {
                        Text("\(value) pt").tag(value)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: LayoutStore.didChange)) { _ in tick += 1 }
    }
}

/// Buttons that open the layout editors on the screen the settings window is on.
struct LayoutEditorButtons: View {
    private func screen() -> NSScreen? { NSApp.keyWindow?.screen ?? ZoneLayout.screenUnderCursor() ?? NSScreen.main }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Layout editors").settingsHeading()
            HStack {
                Button("New grid layout…") { if let s = screen() { GridEditor.open(on: s) } }
                Button("New canvas layout…") { if let s = screen() { CanvasEditor.open(on: s) } }
                Button("Edit current layout…") {
                    guard let s = screen() else { return }
                    let layout = ZoneLayout.layout(for: s)
                    if !LayoutEditors.open(on: s, editing: layout) { GridEditor.open(on: s) }
                }
            }
            Text("Import / export layouts from the menu bar's Layout submenu.").settingsHint()
        }
    }
}
