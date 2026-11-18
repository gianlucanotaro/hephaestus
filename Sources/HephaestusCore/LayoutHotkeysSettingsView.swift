import SwiftUI

/// "Layout Hotkeys" section of the settings window.
struct LayoutHotkeysSettingsView: View {
    @AppStorage(Prefs.layoutHotkeyModifiersKey) private var layoutMods = HotkeyModifiers.controlOptionCommand.carbon
    @AppStorage(Prefs.flashZonesKey) private var flash = true
    @AppStorage(Prefs.editorHotkeyModifiersKey) private var editorMods = HotkeyModifiers.controlOptionCommand.carbon
    @AppStorage(Prefs.editorHotkeyLetterKey) private var editorLetter = "E"
    @State private var map = LayoutHotkeys.shared.map
    @State private var layouts = LayoutStore.shared.all

    private func modifierToggles(_ value: Binding<Int>) -> some View {
        HStack {
            ForEach([(HotkeyModifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")], id: \.1) { mod, symbol in
                Toggle(symbol, isOn: Binding(
                    get: { HotkeyModifiers(carbon: value.wrappedValue).contains(mod) },
                    set: { on in
                        var m = HotkeyModifiers(carbon: value.wrappedValue)
                        if on { m.insert(mod) } else { m.remove(mod) }
                        value.wrappedValue = m.carbon
                    }))
            }
        }
    }

    private func numberBinding(_ layout: Layout) -> Binding<Int> {
        Binding(get: { map.first { $0.value == layout.id }?.key ?? -1 },
                set: { n in
                    if n < 0 {
                        LayoutHotkeys.shared.removeNumber(ofLayoutID: layout.id)
                    } else {
                        LayoutHotkeys.shared.assign(number: n, layoutID: layout.id)
                    }
                    map = LayoutHotkeys.shared.map
                })
    }

    var body: some View {
        Group {
            Text("Layout hotkeys").font(.headline)
            HStack { Text("Modifiers + number"); modifierToggles($layoutMods) }
            if !HotkeyModifiers(carbon: layoutMods).isValid {
                Text("Pick at least one modifier, otherwise the hotkeys are disabled.").font(.footnote).foregroundStyle(.red)
            }
            ForEach(layouts) { layout in
                Picker(layout.name, selection: numberBinding(layout)) {
                    Text("None").tag(-1)
                    ForEach(Array(LayoutHotkeys.validNumbers), id: \.self) { Text("\($0)").tag($0) }
                }
            }
            Toggle("Flash zones when switching layout", isOn: $flash)
            HStack {
                Text("Open layout editor")
                modifierToggles($editorMods)
                Picker("", selection: $editorLetter) { ForEach(LayoutHotkeyKeys.letters, id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().frame(width: 60)
            }
            Text("Applies to the screen under the cursor, also while dragging a window.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: LayoutStore.didChange)) { _ in layouts = LayoutStore.shared.all }
        .onReceive(NotificationCenter.default.publisher(for: LayoutHotkeys.didChange)) { _ in map = LayoutHotkeys.shared.map }
    }
}
