import SwiftUI

/// Per-layout hotkey numbers (Layouts tab). The modifiers and the editor shortcut are recorded in the Shortcuts tab,
/// the "flash zones" toggle lives under Appearance.
struct LayoutHotkeysSettingsView: View {
    /// Picker value meaning "this layout has no hotkey number".
    private static let noNumber = -1

    @State private var map = LayoutHotkeys.shared.map
    @State private var layouts = LayoutStore.shared.all

    private func numberBinding(_ layout: Layout) -> Binding<Int> {
        Binding(get: { map.first { $0.value == layout.id }?.key ?? Self.noNumber },
                set: { n in
                    if n == Self.noNumber {
                        LayoutHotkeys.shared.removeNumber(ofLayoutID: layout.id)
                    } else {
                        LayoutHotkeys.shared.assign(number: n, layoutID: layout.id)
                    }
                    map = LayoutHotkeys.shared.map
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Layout hotkey numbers").settingsHeading()
            ForEach(layouts) { layout in
                Picker(layout.name, selection: numberBinding(layout)) {
                    Text("None").tag(Self.noNumber)
                    ForEach(Array(LayoutHotkeys.validNumbers), id: \.self) { Text("\($0)").tag($0) }
                }
            }
            Text("Modifiers + number applies the layout to the screen under the cursor, also while dragging a window. Set the modifiers under Shortcuts.")
                .settingsHint()
        }
        .onReceive(NotificationCenter.default.publisher(for: LayoutStore.didChange)) { _ in layouts = LayoutStore.shared.all }
        .onReceive(NotificationCenter.default.publisher(for: LayoutHotkeys.didChange)) { _ in map = LayoutHotkeys.shared.map }
    }
}
