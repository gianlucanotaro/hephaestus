import SwiftUI

/// Settings for new-window placement (#15). Keys live here to keep shared files untouched.
extension Prefs {
    static let newWindowLastZoneKey = "newWindowToLastZone"
    static let newWindowActiveScreenKey = "newWindowToActiveScreen"

    static func registerNewWindowDefaults() {
        UserDefaults.standard.register(defaults: [newWindowLastZoneKey: true, newWindowActiveScreenKey: false])
    }
    static var newWindowToLastZone: Bool { UserDefaults.standard.bool(forKey: newWindowLastZoneKey) }
    static var newWindowToActiveScreen: Bool { UserDefaults.standard.bool(forKey: newWindowActiveScreenKey) }
}

struct NewWindowPlacementSettings: View {
    @AppStorage(Prefs.newWindowLastZoneKey) private var lastZone = true
    @AppStorage(Prefs.newWindowActiveScreenKey) private var activeScreen = false

    var body: some View {
        Group {
            Divider()
            Toggle("Move new windows to the app's last zone", isOn: $lastZone)
            Toggle("Otherwise move new windows to the active screen", isOn: $activeScreen)
            Text("Dialogs, sheets and popups are never moved. The active screen is the one under the cursor.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
