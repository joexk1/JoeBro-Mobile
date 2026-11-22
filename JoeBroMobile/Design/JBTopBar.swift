import SwiftUI

/// JoeBro's own top bar for every tab: title in Geist, an optional + on the
/// left, settings on the right — the same size and place on every screen.
struct JBTopBar: View {
    let title: String
    var onAdd: (() -> Void)? = nil
    var addLabel = "New"
    var onSettings: () -> Void

    var body: some View {
        ZStack {
            Text(title).font(.jb(17, .semibold)).tracking(-0.2).foregroundStyle(JB.ink)
            HStack {
                if let onAdd {
                    JBRoundButton(symbol: "plus", label: addLabel, action: onAdd)
                } else {
                    Color.clear.frame(width: 40, height: 40)
                }
                Spacer()
                JBRoundButton(symbol: "gearshape", label: "Settings", action: onSettings)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }
}

/// A round 40pt control on a panel fill with a hairline — JoeBro's toolbar button.
struct JBRoundButton: View {
    let symbol: String
    var label = ""
    var onBanner = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.jb(17, .regular))
                .foregroundStyle(onBanner ? Color.white : JB.ink)
                .frame(width: 40, height: 40)
                .background(Circle().fill(onBanner ? Color.black.opacity(0.45) : JB.panelFill))
                .overlay(Circle().strokeBorder(onBanner ? Color.white.opacity(0.16) : JB.line, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(JBPressStyle())
        .accessibilityLabel(label)
    }
}

/// JoeBro's search field (replaces the system search bar on tab roots).
struct JBSearchField: View {
    @Binding var text: String
    var prompt = "Search"
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.jb(15)).foregroundStyle(JB.ink3)
            TextField(prompt, text: $text)
                .font(.jb(16))
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(JB.ink3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(JB.panelFill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? JB.accent.opacity(0.6) : JB.line, lineWidth: 1))
        .padding(.horizontal, 16)
    }
}

extension View {
    /// Replace the system navigation bar on a tab root with JBTopBar (+ optional search).
    func jbTopBar(_ title: String, search: Binding<String>? = nil, searchPrompt: String = "Search",
                  onAdd: (() -> Void)? = nil, addLabel: String = "New", onSettings: @escaping () -> Void) -> some View {
        self
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 8) {
                    JBTopBar(title: title, onAdd: onAdd, addLabel: addLabel, onSettings: onSettings)
                    if let search { JBSearchField(text: search, prompt: searchPrompt) }
                }
                .padding(.bottom, 8)
            }
    }
}


/// JoeBro's tab bar: a flat panel with a hairline, Geist labels, accent on the selected tab.
struct JBTabBar: View {
    struct Item { var title: String; var glyph: JBGlyph? = nil; var symbol: String? = nil }
    /// Height above the home indicator; tab screens reserve this much at the bottom.
    static let height: CGFloat = 56
    @Binding var selection: Int
    let items: [Item]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let on = selection == i
                Button {
                    guard selection != i else { return }
                    withAnimation(JB.snap) { selection = i }
                } label: {
                    VStack(spacing: 4) {
                        Group {
                            if let g = item.glyph { JBIcon(g, size: 21) }
                            else if let s = item.symbol { Image(systemName: s).font(.jb(19)) }
                        }
                        .frame(height: 24)
                        Text(item.title).font(.jb(10.5, on ? .semibold : .medium))
                    }
                    .foregroundStyle(on ? JB.accent : JB.ink3)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8).padding(.top, 6)
        .background(JB.panelFill.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(JB.line).frame(height: 1) }
        .sensoryFeedback(.selection, trigger: selection)
    }
}
