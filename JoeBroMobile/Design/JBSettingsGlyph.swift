import SwiftUI

/// The settings button's glyph: one size and weight on every tab's top bar.
struct JBSettingsGlyph: View {
    var onBanner = false
    var body: some View {
        Image(systemName: "gearshape")
            .font(.jb(18, .regular))
            .foregroundStyle(onBanner ? Color.white : JB.ink)
            .frame(width: 44, height: 44)
    }
}
