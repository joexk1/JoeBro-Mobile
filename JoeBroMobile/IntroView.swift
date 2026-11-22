import SwiftUI

/// Launch: the JoeBro dot sphere (JBIntro, shared with the Mac) on black. Partway
/// through, `finished` mounts the app underneath while the sphere is still opaque;
/// the app then fades the intro out once the first screen (and its scene) has drawn.
struct IntroView: View {
    let theme: JoeBroTheme
    let finished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        JBIntro(onFinish: {})
            .accessibilityHidden(true)
            .task {
                if !reduceMotion { try? await Task.sleep(for: .seconds(2.35)) }
                finished()
            }
    }
}
