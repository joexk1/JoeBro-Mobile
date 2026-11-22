import SwiftUI

/// Shared row/list chrome for the Night Shift, Memory and Tasks screens.
extension View {
    /// A flat card row: raised fill, hairline, no separators.
    func jbListRow(selected: Bool = false) -> some View {
        self.listRowBackground(
            RoundedRectangle(cornerRadius: JB.rCard, style: .continuous).fill(JB.raised)
                .overlay(RoundedRectangle(cornerRadius: JB.rCard, style: .continuous).strokeBorder(selected ? JB.accent.opacity(0.6) : JB.line, lineWidth: 1))
                .padding(.vertical, 3)
        )
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
    }
    /// Plain list on the wallpaper.
    func jbPlainList() -> some View {
        self.listStyle(.plain).scrollContentBackground(.hidden).jbWallpaper()
    }
    /// Grouped form rows in the same raised fill.
    func jbFormRow() -> some View { self.listRowBackground(JB.raised) }
}

/// Section header row for plain lists.
struct JBListHeader: View {
    let title: String
    var count: Int? = nil
    var body: some View {
        JBSectionHeader(title, count: count).padding(.top, 6).textCase(nil)
    }
}

/// One line of ASCII art and text, as a list row.
struct JBEmptyRow: View {
    let art: JBEmptyState.Art
    let text: String
    var body: some View {
        JBEmptyState(art: art, text: text).frame(minHeight: 220)
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
}

struct JBPlusButton: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "plus").foregroundStyle(JB.accent) }.accessibilityLabel(label)
    }
}

/// Mono chip-style segmented choice (replaces system segmented pickers).
struct JBSegments<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options.indices, id: \.self) { i in
                    let on = options[i].0 == selection
                    Button { withAnimation(JB.snap) { selection = options[i].0 } } label: {
                        Text(options[i].1).font(.jbMono(12, on ? .medium : .regular))
                            .foregroundStyle(on ? JB.ink : JB.ink3)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: JB.rControl, style: .continuous).fill(on ? JB.pressed : .clear))
                            .overlay(RoundedRectangle(cornerRadius: JB.rControl, style: .continuous).strokeBorder(on ? JB.line : .clear, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 2)
        }
    }
}
