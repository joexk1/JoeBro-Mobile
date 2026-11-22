import SwiftUI

extension View {
    /// Form rows: flat panel fill with a hairline separator.
    func jbRow() -> some View {
        listRowBackground(JB.panelFill).listRowSeparatorTint(JB.line)
    }
}

/// `Section("Title")` with a mono eyebrow header and flat rows.
struct JBSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        Section {
            content.jbRow()
        } header: {
            JBSectionHeader(title)
        }
    }
}

extension View {
    /// Form chrome: transparent over the backdrop, ink text, accent tint, JB switches.
    func jbForm() -> some View {
        scrollContentBackground(.hidden)
            .foregroundStyle(JB.ink)
            .tint(JB.accent)
            .toggleStyle(JBSwitchStyle())
            .jbWallpaper()
    }
}
