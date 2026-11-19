import SwiftUI

extension View {
    /// Small explanatory text under a setting: footnote size, wraps to the full row width instead of truncating.
    /// Pass a color for warnings (`.orange`, `.red`).
    func settingsHint(_ color: Color = .secondary) -> some View {
        font(.footnote)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
