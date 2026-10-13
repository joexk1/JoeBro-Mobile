import SwiftUI

/// Global-space Y of the bottom of the transcript content.
private struct ContentBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Global-space Y of the bottom of the *visible* area (above the composer).
private struct ViewportBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The message transcript. It owns the composer inset so that the two
/// measurements used by the jump-to-bottom button are taken in the same
/// (global) space and therefore stay correct whatever the composer's height.
struct ChatTranscriptView<Composer: View>: View {
    let store: ChatStore
    var onOpenDocument: (ChatDocumentRef) -> Void
    @ViewBuilder var composer: () -> Composer

    private static var bottomID: String { "chat-bottom" }

    @Environment(\.scenePhase) private var scenePhase
    @State private var contentBottom: CGFloat = 0
    @State private var viewportBottom: CGFloat = 0
    @State private var followingLatest = true

    /// Both probes use global coordinates. The last message is considered
    /// visible once its bottom is within a short swipe of the viewport edge.
    private var scrolledUp: Bool {
        contentBottom > 0 && viewportBottom > 0 && contentBottom - viewportBottom > 60
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                scroll(proxy)
                    .overlay(alignment: .bottom) { viewportProbe }
                    .overlay(alignment: .bottom) { jumpButton(proxy) }
                composer()
            }
                .onChange(of: store.lines.count) { _, _ in
                    // A submitted message should be visible immediately. The
                    // lazy stack may lay its new rows out after this callback,
                    // so repeat the jump once layout has settled.
                    // A history refresh must preserve someone reading older turns.
                    guard followingLatest || store.lines.last?.streaming == true else { return }
                    followingLatest = true
                    jump(proxy, animated: true)
                    jumpAfterLayout(proxy)
                }
                .onChange(of: store.lines.last?.id) { _, _ in
                    // History reload replaces cached rows with fresh UUIDs, often
                    // with the same count, so the count trigger never fires.
                    guard followingLatest else { return }
                    jump(proxy, animated: false)
                    jumpAfterLayout(proxy)
                }
                .onChange(of: store.lines.last?.text.count ?? 0) { _, _ in
                    guard followingLatest else { return }
                    jump(proxy, animated: false)
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active, followingLatest else { return }
                    jumpAfterLayout(proxy)
                }
                .task(id: store.selectedSessionID) {
                    contentBottom = 0
                    viewportBottom = 0
                    followingLatest = true
                    // Opening a chat must land on the newest message, not the top.
                    jump(proxy, animated: false)
                    jumpAfterLayout(proxy)
                }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if store.lines.isEmpty { ChatEmptyState(isMainJoeBro: store.isMainJoeBro) }
                ForEach(store.lines) { line in
                    ChatMessageRow(line: line, onOpenDocument: onOpenDocument).id(line.id)
                }
                bottomAnchor
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { drag in
            // Dragging down reads older messages. A new streaming token must
            // not pull the transcript back while the user is doing that.
            if drag.translation.height > 8 { followingLatest = false }
        })
        .onPreferenceChange(ContentBottomKey.self) { bottom in
            contentBottom = bottom
            // Lazy markdown rows can replace estimated heights after scrollTo.
            // Correct both an undershoot and an overshoot using the laid-out
            // anchor, only while the user is following the newest message.
            guard followingLatest, bottom > 0, viewportBottom > 0,
                  abs(bottom - viewportBottom) > 24 else { return }
            jump(proxy, animated: false)
        }
        .onPreferenceChange(ViewportBottomKey.self) { bottom in
            viewportBottom = bottom
            guard followingLatest, contentBottom > 0, bottom > 0,
                  abs(contentBottom - bottom) > 24 else { return }
            jump(proxy, animated: false)
        }
        .onChange(of: scrolledUp) { _, isUp in
            if !isUp { followingLatest = true }
        }
    }

    private var bottomAnchor: some View {
        Color.clear
            .frame(height: 1)
            .id(Self.bottomID)
            .background(GeometryReader { geo in
                Color.clear.preference(key: ContentBottomKey.self, value: geo.frame(in: .global).maxY)
            })
    }

    private var viewportProbe: some View {
        GeometryReader { geo in
            Color.clear.preference(key: ViewportBottomKey.self, value: geo.frame(in: .global).maxY)
        }
        .frame(height: 1)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func jumpButton(_ proxy: ScrollViewProxy) -> some View {
        if scrolledUp {
            Button {
                contentBottom = viewportBottom
                followingLatest = true
                jump(proxy, animated: true)
            } label: {
                Image(systemName: "arrow.down")
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.25)))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Jump to latest message")
            .padding(.bottom, 18)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    private func jump(_ proxy: ScrollViewProxy, animated: Bool) {
        let sessionID = store.selectedSessionID
        let scrollToBottom = { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        DispatchQueue.main.async {
            guard followingLatest, store.selectedSessionID == sessionID else { return }
            if animated { withAnimation(.easeOut(duration: 0.25)) { scrollToBottom() } }
            else { scrollToBottom() }
        }
    }

    private func jumpAfterLayout(_ proxy: ScrollViewProxy) {
        let sessionID = store.selectedSessionID
        Task { @MainActor in
            // Lazy rows (markdown) keep growing for a while; re-pin a few times.
            for ms in [120, 250, 500, 900] {
                try? await Task.sleep(for: .milliseconds(ms))
                guard !Task.isCancelled, followingLatest, store.selectedSessionID == sessionID else { return }
                jump(proxy, animated: false)
            }
        }
    }
}

struct ChatEmptyState: View {
    var isMainJoeBro = false
    var body: some View {
        VStack(spacing: 16) {
            if !isMainJoeBro {
                Image("JoeBroLogo").resizable().scaledToFit().frame(width: 72, height: 72)
                Text("What can I help with?").font(.title2.bold()).foregroundStyle(.white)
                Text("Ask a question or put JoeBro to work.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Text("Say hello, or give me something to take care of.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}
