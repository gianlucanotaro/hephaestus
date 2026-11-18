import SwiftUI

/// The three window-state toggles; inserted into `SettingsView` with one line.
struct WindowStateSettings: View {
    @AppStorage(Prefs.restoreSizeOnUnsnapKey) private var restoreSize = true
    @AppStorage(Prefs.reapplyOnDisplayChangeKey) private var onDisplay = true
    @AppStorage(Prefs.reapplyOnLayoutChangeKey) private var onLayout = true

    var body: some View {
        Group {
            Divider()
            Toggle("Restore original size when dragged out of a zone", isOn: $restoreSize)
            Toggle("Re-apply zones when displays change", isOn: $onDisplay)
            Toggle("Move snapped windows when the layout changes", isOn: $onLayout)
        }
    }
}
