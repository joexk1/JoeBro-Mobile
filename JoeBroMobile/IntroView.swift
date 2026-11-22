import SwiftUI

/// The dot-matrix wordmark switches on over black, then the app fades in
/// underneath. About a second; Reduce Motion skips it.
struct IntroView: View {
    let theme: JoeBroTheme
    let finished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var revealed = false

    var body: some View {
        ZStack {
            WallpaperBackground(theme: theme)
                .opacity(revealed ? 1 : 0)
            Color.black
                .opacity(revealed ? 0 : 1)
            JBWordmark(dot: 4, gap: 2, tint: .white)
                .opacity(revealed ? 0 : 1)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task { await run() }
    }

    @MainActor
    private func run() async {
        if reduceMotion {
            finished()
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(800))
            withAnimation(.easeInOut(duration: 0.32)) { revealed = true }
            try await Task.sleep(for: .milliseconds(340))
            finished()
        } catch {
            // Dismissing the overlay cancels its task; don't call back again.
        }
    }
}
