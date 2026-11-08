import SwiftUI
import PhotosUI
import WebKit

/// Backdrops ported from the macOS app's WallpaperBackground, which is the
/// the look the app ships with. Deliberately saturated — glass goes flat over
/// near-black, so even the dark variants keep visible colour depth.
enum BackgroundPreset: String, CaseIterable, Identifiable {
    case purple, ocean, forest, sunset, graphite, monochrome

    var id: String { rawValue }
    var label: String { self == .monochrome ? "Black & White" : rawValue.capitalized }

    var colors: [Color] {
        switch self {
        case .monochrome:
            [Color(uiColor: .systemBackground)]
        case .purple:
            [Color(red: 0.18, green: 0.10, blue: 0.34),
             Color(red: 0.30, green: 0.13, blue: 0.44),
             Color(red: 0.11, green: 0.13, blue: 0.36)]
        case .ocean:
            [Color(red: 0.05, green: 0.16, blue: 0.34),
             Color(red: 0.07, green: 0.26, blue: 0.44),
             Color(red: 0.04, green: 0.12, blue: 0.28)]
        case .forest:
            [Color(red: 0.06, green: 0.20, blue: 0.14),
             Color(red: 0.09, green: 0.28, blue: 0.18),
             Color(red: 0.05, green: 0.16, blue: 0.13)]
        case .sunset:
            [Color(red: 0.30, green: 0.12, blue: 0.16),
             Color(red: 0.40, green: 0.18, blue: 0.12),
             Color(red: 0.24, green: 0.10, blue: 0.22)]
        case .graphite:
            [Color(red: 0.12, green: 0.13, blue: 0.15),
             Color(red: 0.17, green: 0.18, blue: 0.21),
             Color(red: 0.10, green: 0.11, blue: 0.13)]
        }
    }
}

/// The original, full-colour scenes from bas3line/ascii.
enum BackgroundAnimation: String, CaseIterable, Identifiable {
    case off
    case alpineDawn = "alpine-dawn"
    case amerFort = "amer-fort"
    case auroraFjord = "aurora-fjord"
    case blackPrism = "black-prism"
    case cloudSea = "cloud-sea"
    case commandCity = "command-city"
    case deepReef = "deep-reef"
    case desertNight = "desert-night"
    case earthrise = "earthrise"
    case edgeOrbit = "edge-orbit"
    case gangaurGhat = "gangaur-ghat"
    case greenStorm = "green-storm"
    case jalMahal = "jal-mahal"
    case jungleFalls = "jungle-falls"
    case kiteFestival = "kite-festival"
    case kyotoDusk = "kyoto-dusk"
    case lakePichola = "lake-pichola"
    case lanternLake = "lantern-lake"
    case lavaWall = "lava-wall"
    case marineDrive = "marine-drive"
    case mistyForest = "misty-forest"
    case nightCoast = "night-coast"
    case nightHighway = "night-highway"
    case oceanSunset = "ocean-sunset"
    case planetScale = "planet-scale"
    case prismCity = "prism-city"
    case saltFlat = "salt-flat"
    case saturnRise = "saturn-rise"
    case snowTrain = "snow-train"
    case stormPlains = "storm-plains"
    case tajDawn = "taj-dawn"
    case tokyoRain = "tokyo-rain"
    case varanasiGhats = "varanasi-ghats"
    case volcanoNight = "volcano-night"

    var id: String { rawValue }
    var label: String { rawValue.split(separator: "-").map { $0.capitalized }.joined(separator: " ") }
}

@MainActor
@Observable final class JoeBroTheme {
    var wallpaper: UIImage?
    var joeBroColor: Color = .white
    /// A `BackgroundPreset` raw value, or "photo" when a photo is chosen.
    var wallpaperName: String = UserDefaults.standard.string(forKey: "wallpaperName") ?? BackgroundPreset.purple.rawValue

    init() {
        joeBroColor = Self.savedJoeBroColor()
        loadWallpaper()
        // The tab bar and nav bars are opaque by default on iOS, which hid
        // the wallpaper behind them entirely.
        Self.makeChromeTransparent()
    }

    var accent: Color { Color(red: 0.78, green: 0.82, blue: 1) }

    func setJoeBroColor(_ color: Color) {
        joeBroColor = color
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        let hex = String(format: "#%02X%02X%02X",
                         byte(red), byte(green), byte(blue))
        UserDefaults.standard.set(hex, forKey: "joeBroColor")
    }

    private static func savedJoeBroColor() -> Color {
        guard let hex = UserDefaults.standard.string(forKey: "joeBroColor"),
              hex.count == 7, hex.first == "#",
              let value = UInt32(hex.dropFirst(), radix: 16) else { return .white }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    var preset: BackgroundPreset? { BackgroundPreset(rawValue: wallpaperName) }

    func setWallpaper(data: Data) {
        guard let image = UIImage(data: data) else { return }
        let url = Self.wallpaperURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        wallpaper = image
        wallpaperName = "photo"
        UserDefaults.standard.set(wallpaperName, forKey: "wallpaperName")
    }

    func select(_ name: String) {
        wallpaperName = name
        UserDefaults.standard.set(name, forKey: "wallpaperName")
        if name == "photo" { loadWallpaper() } else { wallpaper = nil }
    }

    private func loadWallpaper() { wallpaper = UIImage(contentsOfFile: Self.wallpaperURL.path) }

    private static var wallpaperURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JoeBro/wallpaper", isDirectory: false)
    }

    private static func makeChromeTransparent() {
        let tab = UITabBarAppearance()
        tab.configureWithTransparentBackground()
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav

        // Lists and Forms otherwise paint systemGroupedBackground over it.
        UITableView.appearance().backgroundColor = .clear
        UICollectionView.appearance().backgroundColor = .clear
    }
}

struct WallpaperBackground: View {
    let theme: JoeBroTheme
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if theme.wallpaperName == "photo", let wallpaper = theme.wallpaper {
                    Image(uiImage: wallpaper).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                        .overlay(Color.black.opacity(0.32))
                } else if theme.preset == .monochrome {
                    colorScheme == .dark ? Color.black : Color.white
                } else {
                    LinearGradient(colors: (theme.preset ?? .purple).colors,
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }
}

/// The intro stays in front until WebKit has drawn the selected scene.
@MainActor
@Observable final class AsciiSceneReadiness {
    static let shared = AsciiSceneReadiness()
    var ready = false
}

/// Decorative only: the header owns layout; the scene never contributes height.
struct AsciiTopBarAnimation: View {
    @AppStorage("backgroundAnimation") private var animationRaw = BackgroundAnimation.off.rawValue
    @Environment(JoeBroTheme.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var visible = true

    private var mode: BackgroundAnimation { BackgroundAnimation(rawValue: animationRaw) ?? .off }
    // Keep the scene palette on a dark ground in both app appearances.
    private var paper: Bool { false }

    var body: some View {
        if mode != .off && theme.wallpaperName != "photo" {
            ZStack {
                paper ? Color.white : Color.black
                AsciiSceneWebView(name: mode.rawValue, paper: paper,
                                  paused: reduceMotion || scenePhase != .active || !visible)
            }
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct AsciiSceneWebView: UIViewRepresentable {
    let name: String
    let paper: Bool
    let paused: Bool

    @MainActor private static let retainedCoordinator = Coordinator()
    @MainActor private static var retainedView: WKWebView?

    func makeCoordinator() -> Coordinator { Self.retainedCoordinator }

    func makeUIView(context: Context) -> WKWebView {
        if let view = Self.retainedView {
            context.coordinator.update(name: name, paper: paper, paused: paused, in: view)
            return view
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.contentInset = .zero
        view.scrollView.scrollIndicatorInsets = .zero
        view.isUserInteractionEnabled = false
        view.navigationDelegate = context.coordinator
        Self.retainedView = view
        context.coordinator.update(name: name, paper: paper, paused: paused, in: view)
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "AsciiScenes") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.update(name: name, paper: paper, paused: paused, in: view)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.pause(in: view)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var lastName = ""
        private var lastPaper = false
        private var ready = false

        func pause(in view: WKWebView) {
            update(name: lastName, paper: lastPaper, paused: true, in: view)
        }
        private var desired = ""
        private var applied = ""

        func update(name: String, paper: Bool, paused: Bool, in view: WKWebView) {
            // name comes only from BackgroundAnimation; JSON encoding keeps the bridge literal safe.
            lastName = name
            lastPaper = paper
            let encoded = String(data: try! JSONEncoder().encode(name), encoding: .utf8)!
            desired = "window.setScene(\(encoded), \(paused), \(paper))"
            apply(to: view)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            apply(to: webView)
        }

        private func apply(to view: WKWebView) {
            guard ready, desired != applied else { return }
            applied = desired
            view.evaluateJavaScript(desired) { _, error in
                if error == nil {
                    AsciiSceneReadiness.shared.ready = true
                }
            }
        }
    }
}

struct GlassPanel: ViewModifier {
    var radius: CGFloat = 24
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.joeInk.opacity(0.16), lineWidth: 1))
    }
}

extension View {
    func jbGlass(_ radius: CGFloat = 24) -> some View { modifier(GlassPanel(radius: radius)) }
}

/// Each TabView page is hosted in its own controller whose view paints an
/// opaque systemBackground, which covers a wallpaper sitting behind the
/// TabView. So every tab root draws the wallpaper itself.
private struct JBWallpaper: ViewModifier {
    @Environment(JoeBroTheme.self) private var theme
    func body(content: Content) -> some View {
        ZStack {
            WallpaperBackground(theme: theme)
            content
        }
    }
}

extension View {
    func jbWallpaper() -> some View { modifier(JBWallpaper()) }
}

extension Color {
    /// The app's single accent. Controls must not inherit pure white or
    /// toggles and destructive buttons render as white-on-white blobs.
    static var joeInk: Color { Color.primary }
    static var joeInverseInk: Color {
        Color(UIColor { traits in traits.userInterfaceStyle == .dark ? .black : .white })
    }
    static var accentTint: Color {
        Color(UIColor { traits in
            if UserDefaults.standard.string(forKey: "wallpaperName") == BackgroundPreset.monochrome.rawValue {
                return traits.userInterfaceStyle == .dark ? .white : .black
            }
            return traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.72, green: 0.78, blue: 1, alpha: 1)
                : UIColor(red: 0.22, green: 0.30, blue: 0.65, alpha: 1)
        })
    }
}

extension ShapeStyle where Self == Color {
    /// Lets `.accentTint` be used wherever a ShapeStyle is expected
    /// (`.background`, `.fill`, `.foregroundStyle`), not just as `Color`.
    static var accentTint: Color { Color.accentTint }
    static var joeInk: Color { Color.joeInk }
}
