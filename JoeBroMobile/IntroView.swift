import SwiftUI

/// The launch artwork stays centered on black. Its letter fades away, leaving
/// the white tile, which grows from the same outline until the app is revealed.
struct IntroView: View {
    let theme: JoeBroTheme
    let finished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var letterCovered = false
    @State private var expanded = false
    @State private var wallpaperRevealed = false

    // The visible tile occupies 370 of the 512 pixels in JoeBroLogo. Keeping
    // this ratio makes the drawn white tile line up with the launch artwork.
    private let artworkSide: CGFloat = 220
    private var tileSide: CGFloat { artworkSide * 370 / 512 }

    var body: some View {
        GeometryReader { geometry in
            let diagonal = hypot(geometry.size.width, geometry.size.height)
            let fillScale = max(1, diagonal * 1.55 / tileSide)

            ZStack {
                Color.black.ignoresSafeArea()

                Image("JoeBroLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: artworkSide, height: artworkSide)

                tile(scale: expanded ? fillScale : 1)
                    .opacity(letterCovered ? 1 : 0)

                // Render the wallpaper at screen size before masking it, so a
                // selected photo stays fixed as the tile grows over it.
                WallpaperBackground(theme: theme)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .mask {
                        tile(scale: expanded ? fillScale : 1)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    .opacity(wallpaperRevealed ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task { await run() }
    }

    private func tile(scale: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: tileSide * 0.215,
                         style: .continuous)
            .fill(.white)
            .frame(width: tileSide, height: tileSide)
            .scaleEffect(scale)
    }

    @MainActor
    private func run() async {
        if reduceMotion {
            finished()
            return
        }

        do {
            // Begin in the same pose as the system launch screen; the first
            // motion is the letter dissolving rather than a second logo pop.
            try await Task.sleep(for: .milliseconds(280))
            withAnimation(.easeInOut(duration: 0.48)) { letterCovered = true }
            try await Task.sleep(for: .milliseconds(600))
            withAnimation(.timingCurve(0.55, 0.02, 0.15, 1, duration: 0.78)) {
                expanded = true
            }
            try await Task.sleep(for: .milliseconds(400))
            withAnimation(.easeInOut(duration: 0.36)) { wallpaperRevealed = true }
            try await Task.sleep(for: .milliseconds(420))
            finished()
        } catch {
            // Dismissing the overlay cancels its task; don't call back again.
        }
    }
}
