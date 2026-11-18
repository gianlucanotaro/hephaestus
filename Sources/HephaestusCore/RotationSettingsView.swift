import SwiftUI

/// Settings section for rotation mode.
struct RotationSettingsView: View {
    @AppStorage(Prefs.rotationEnabledKey) private var enabled = false
    @AppStorage(Prefs.rotationModifierKey) private var modifier = RotationModifier.option.rawValue
    @AppStorage(Prefs.rotationKeyCodeKey) private var keyCode = 7

    var body: some View {
        Divider()
        Toggle("Rotate windows across monitors", isOn: $enabled)
        if enabled {
            HStack {
                Picker("Hold", selection: $modifier) {
                    ForEach(RotationModifier.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Picker("+", selection: $keyCode) {
                    ForEach(RotationKey.letters, id: \.code) { Text($0.title).tag($0.code) }
                }
            }
        }
        Text("Hold the shortcut and press ← or → to move every window one screen over (wraps around), keeping its zone number. A preview is shown while held.")
            .font(.footnote).foregroundStyle(.secondary)
    }
}
