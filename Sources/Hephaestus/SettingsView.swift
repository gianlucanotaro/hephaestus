import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.displayIDKey) private var displayID = 0
    @AppStorage(Prefs.aspectWKey) private var aspectW = 16.0
    @AppStorage(Prefs.aspectHKey) private var aspectH = 9.0
    @AppStorage(Prefs.gapKey) private var gap = 8.0
    var onChange: () -> Void

    var body: some View {
        Form {
            Picker("Display", selection: $displayID) {
                Text("Auto (widest)").tag(0)
                ForEach(NSScreen.screens, id: \.displayID) { s in
                    Text("\(s.localizedName) — \(Int(s.frame.width))×\(Int(s.frame.height))").tag(Int(s.displayID))
                }
            }
            HStack {
                Text("Center aspect")
                TextField("W", value: $aspectW, format: .number).frame(width: 50)
                Text(":")
                TextField("H", value: $aspectH, format: .number).frame(width: 50)
            }
            HStack {
                Text("Gap")
                Slider(value: $gap, in: 0...40, step: 1)
                Text("\(Int(gap)) px").monospacedDigit().frame(width: 50, alignment: .trailing)
            }
            Text("Side zones share the remaining width equally.\nHotkeys: ⌃⌥← left · ⌃⌥↑ center · ⌃⌥→ right · ⌃⌥Z preview")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: displayID) { _ in onChange() }
        .onChange(of: aspectW) { _ in onChange() }
        .onChange(of: aspectH) { _ in onChange() }
        .onChange(of: gap) { _ in onChange() }
    }
}
