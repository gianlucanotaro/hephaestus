import Carbon.HIToolbox
import SwiftUI

/// Settings section for keyboard zone navigation. Hotkeys re-register automatically on change
/// (`KeyboardNavController` observes UserDefaults). A full shortcut recorder is planned in #18.
struct KeyboardNavSettingsView: View {
    @AppStorage(Prefs.navModeKey) private var mode = KeyboardNavMode.direct.rawValue
    @AppStorage(Prefs.navCrossScreensKey) private var crossScreens = false
    @AppStorage(Prefs.navDirectModifiersKey) private var directMods = KeyboardNavConfig.defaultDirect
    @AppStorage(Prefs.navMoveModifiersKey) private var moveMods = KeyboardNavConfig.defaultMove
    @AppStorage(Prefs.navExpandModifiersKey) private var expandMods = KeyboardNavConfig.defaultExpand

    private var current: KeyboardNavMode { KeyboardNavMode(rawValue: mode) ?? .direct }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyboard").font(.headline)
            Picker("Keyboard mode", selection: $mode) {
                ForEach(KeyboardNavMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            switch current {
            case .direct:
                ModifierRow(title: "Snap (←↑→)", value: $directMods)
            case .zoneIndex:
                ModifierRow(title: "Previous / next zone (←→)", value: $moveMods)
            case .relative:
                ModifierRow(title: "Move to nearest zone (←↑↓→)", value: $moveMods)
                ModifierRow(title: "Expand to adjacent zone (←↑↓→)", value: $expandMods)
                if moveMods == expandMods {
                    Text("Move and expand use the same modifiers, so expand will not work. Pick different ones.")
                        .font(.footnote).foregroundStyle(.red)
                }
            }
            if current != .direct {
                Toggle("Move across all screens", isOn: $crossScreens)
                Text("Off: stay on the current screen (zone-index mode wraps around). On: continue onto the adjacent screen in that direction.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("""
                macOS Sequoia has its own window tiling shortcuts (Fn/Globe+Control+arrows, and in some versions \
                Control+Option+arrows) that can take these keys before Hephaestus sees them. If a hotkey does nothing, \
                pick other modifiers here (e.g. ⌃⌥⌘) or turn the system ones off in System Settings → Keyboard → \
                Keyboard Shortcuts → Windows (or Desktop & Dock → Windows → Tile by dragging / Keyboard shortcuts).
                """)
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// Four modifier checkboxes bound to a Carbon modifier bitmask. At least one stays on.
private struct ModifierRow: View {
    let title: String
    @Binding var value: Int

    private static let options: [(String, Int)] = [("⌃", controlKey), ("⌥", optionKey), ("⇧", shiftKey), ("⌘", cmdKey)]

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            ForEach(Self.options, id: \.1) { symbol, flag in
                Toggle(symbol, isOn: Binding(
                    get: { value & flag != 0 },
                    set: { on in
                        let next = on ? value | flag : value & ~flag
                        if next & HotKeyModifiers.all != 0 { value = next }
                    }))
                    .toggleStyle(.checkbox)
            }
        }
    }
}
