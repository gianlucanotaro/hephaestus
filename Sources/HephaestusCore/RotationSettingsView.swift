import SwiftUI

/// Rotation mode: the enable toggle (Windows tab). The trigger shortcut is recorded in the Shortcuts tab.
struct RotationSettingsView: View {
    @AppStorage(Prefs.rotationEnabledKey) private var enabled = false

    var body: some View {
        Group {
            Text("Rotation").font(.headline)
            Toggle("Rotate windows across monitors", isOn: $enabled)
            Text("Hold the trigger shortcut and press ← or → to move every window one screen over (wraps around), keeping its zone number. A preview is shown while held. Needs Accessibility; relaunch after granting it. Disabled while layouts span all screens.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
