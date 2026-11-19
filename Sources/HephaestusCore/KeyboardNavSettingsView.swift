import Carbon.HIToolbox
import SwiftUI

/// Keyboard navigation section (Shortcuts tab): mode, cross-screen movement and the recorders for the shortcuts the
/// current mode uses. Hotkeys re-register automatically on change (`KeyboardNavController` observes UserDefaults).
struct KeyboardNavSettingsView: View {
    @AppStorage(Prefs.navModeKey) private var mode = KeyboardNavMode.direct.rawValue
    @AppStorage(Prefs.navCrossScreensKey) private var crossScreens = false

    private var current: KeyboardNavMode { KeyboardNavMode(rawValue: mode) ?? .direct }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyboard navigation").font(.headline)
            Picker("Keyboard mode", selection: $mode) {
                ForEach(KeyboardNavMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            switch current {
            case .direct:
                ShortcutRow(id: .directFirst)
                ShortcutRow(id: .directMiddle)
                ShortcutRow(id: .directLast)
            case .zoneIndex:
                ShortcutRow(id: .navMove)
                Text("Only ← and → are used: previous / next zone.").font(.footnote).foregroundStyle(.secondary)
            case .relative:
                ShortcutRow(id: .navMove)
                ShortcutRow(id: .navExpand)
            }
            if current != .direct {
                Toggle("Move across all screens", isOn: $crossScreens)
                Text("Off: stay on the current screen (zone-index mode wraps around). On: continue onto the adjacent screen in that direction.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("""
                macOS Sequoia has its own window tiling shortcuts (Fn/Globe+Control+arrows, and in some versions \
                Control+Option+arrows) that can take these keys before Hephaestus sees them. If a hotkey does nothing, \
                record other modifiers (e.g. ⌃⌥⌘) or turn the system ones off in System Settings → Keyboard → \
                Keyboard Shortcuts → Windows (or Desktop & Dock → Windows → Tile by dragging / Keyboard shortcuts).
                """)
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
