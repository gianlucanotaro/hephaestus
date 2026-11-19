import SwiftUI

/// Windows tab section: enable toggle, limits, and the currently pinned windows with an Unpin button each.
/// The shortcut itself is recorded in the Shortcuts tab.
struct PinnedWindowsSettings: View {
    @AppStorage(Prefs.pinnedWindowsEnabledKey) private var enabled = true
    @AppStorage(Prefs.pinForceKey) private var force = true
    @State private var pinned: [PinnedWindow] = PinnedWindows.shared.windows

    var body: some View {
        Group {
            Text("Pinned windows").font(.headline)
            Toggle("Enable pinned windows", isOn: $enabled)
            Text("Pin a window from the menu bar menu or with the shortcut in the Shortcuts tab. macOS cannot make another app's window always-on-top, so Hephaestus re-raises pinned windows when something covers them, without taking focus. It can flicker briefly, cannot sit above fullscreen apps, the menu bar or system panels, and some apps ignore the raise. Pins are forgotten when Hephaestus quits.")
                .settingsHint()
            if enabled {
                Toggle("Force pinned windows to the front (briefly switches focus)", isOn: $force)
                Text("macOS ignores a plain raise of a window from another app. With this on, Hephaestus briefly makes the pinned window's app frontmost, then returns focus to the app you were using. Expect a short flicker, and a key pressed in that instant may go to the wrong app. Off: only the gentle raise is used, which often does nothing across apps.")
                    .settingsHint()
                if pinned.isEmpty {
                    Text("No windows pinned.").settingsHint()
                }
                ForEach(pinned, id: \.token) { pin in
                    HStack {
                        Text(PinMenuLogic.listTitle(appName: pin.appName, windowTitle: pin.title, limit: 60)).lineLimit(1)
                        Spacer()
                        Button("Unpin") { PinnedWindows.shared.unpin(token: pin.token) }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PinnedWindows.didChange)) { _ in
            pinned = PinnedWindows.shared.windows
        }
    }
}
