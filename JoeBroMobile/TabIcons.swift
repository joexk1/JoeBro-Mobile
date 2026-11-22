import SwiftUI

/// UITabBar wants bitmaps, so the JBIcon glyphs are rendered once as template images.
@MainActor
enum JBTabIcon {
    private static var cache: [JBGlyph: UIImage] = [:]

    static func image(_ glyph: JBGlyph) -> Image {
        if let hit = cache[glyph] { return Image(uiImage: hit) }
        let renderer = ImageRenderer(content: JBIcon(glyph, size: 25, lineWidth: 1.4).foregroundStyle(Color.black))
        renderer.scale = UIScreen.main.scale
        let image = (renderer.uiImage ?? UIImage()).withRenderingMode(.alwaysTemplate)
        cache[glyph] = image
        return Image(uiImage: image)
    }
}
