import SwiftUI

/// Settings for new-window placement (#15). Keys live here to keep shared files untouched.
extension Prefs {
    static let newWindowLastZoneKey = "newWindowToLastZone"
    static let newWindowActiveScreenKey = "newWindowToActiveScreen"

    static let defaultNewWindowToLastZone = true
    static let defaultNewWindowToActiveScreen = false

    static func registerNewWindowDefaults() {
        UserDefaults.standard.register(defaults: [
            newWindowLastZoneKey: defaultNewWindowToLastZone, newWindowActiveScreenKey: defaultNewWindowToActiveScreen,
        ])
    }
    static var newWindowToLastZone: Bool { UserDefaults.standard.bool(forKey: newWindowLastZoneKey) }
    static var newWindowToActiveScreen: Bool { UserDefaults.standard.bool(forKey: newWindowActiveScreenKey) }
}

struct NewWindowPlacementSettings: View {
    @AppStorage(Prefs.newWindowLastZoneKey) private var lastZone = Prefs.defaultNewWindowToLastZone
    @AppStorage(Prefs.newWindowActiveScreenKey) private var activeScreen = Prefs.defaultNewWindowToActiveScreen

    var body: some View {
        Group {
            Text("New windows").settingsHeading()
            Toggle("Move new windows to the app's last zone", isOn: $lastZone)
            Toggle("Otherwise move new windows to the active screen", isOn: $activeScreen)
            Text("Dialogs, sheets and popups are never moved. The active screen is the one under the cursor.")
                .settingsHint()
        }
    }
}
