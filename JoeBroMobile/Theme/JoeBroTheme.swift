import SwiftUI
import PhotosUI

/// Backdrops ported from the macOS app's WallpaperBackground, which is the
/// the look the app ships with. Deliberately saturated — glass goes flat over
/// near-black, so even the dark variants keep visible colour depth.
enum BackgroundPreset: String, CaseIterable, Identifiable {
    case purple, ocean, forest, sunset, graphite

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var colors: [Color] {
        switch self {
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
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if theme.wallpaperName == "photo", let wallpaper = theme.wallpaper {
                    Image(uiImage: wallpaper).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                        .overlay(Color.black.opacity(0.32))
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

struct GlassPanel: ViewModifier {
    var radius: CGFloat = 24
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(.white.opacity(0.16), lineWidth: 1))
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
    static let accentTint = Color(red: 0.72, green: 0.78, blue: 1)
}

extension ShapeStyle where Self == Color {
    /// Lets `.accentTint` be used wherever a ShapeStyle is expected
    /// (`.background`, `.fill`, `.foregroundStyle`), not just as `Color`.
    static var accentTint: Color { Color.accentTint }
}
