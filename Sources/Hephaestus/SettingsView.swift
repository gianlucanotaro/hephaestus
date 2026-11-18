import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.aspectWKey) private var aspectW = 16.0
    @AppStorage(Prefs.aspectHKey) private var aspectH = 9.0
    @AppStorage(Prefs.gapKey) private var gap = 8.0
    @AppStorage(Prefs.dragActivationKey) private var dragActivation = DragActivation.shift.rawValue
    var onChange: () -> Void

    var body: some View {
        Form {
            Text("Applied to every connected screen.").font(.footnote).foregroundStyle(.secondary)
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
            Picker("Drag to snap", selection: $dragActivation) {
                ForEach(DragActivation.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            Text("Side zones share the remaining width equally.\nHotkeys: ⌃⌥← left · ⌃⌥↑ center · ⌃⌥→ right · ⌃⌥Z preview")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: aspectW) { _ in onChange() }
        .onChange(of: aspectH) { _ in onChange() }
        .onChange(of: gap) { _ in onChange() }
    }
}
