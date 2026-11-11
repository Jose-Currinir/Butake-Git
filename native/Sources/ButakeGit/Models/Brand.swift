import SwiftUI
import AppKit

func L(_ key: String) -> String { Bundle.module.localizedString(forKey: key, value: key, table: "Localizable") }
enum Brand {
    static let green = Color(red: 25/255, green: 215/255, blue: 159/255)
    static let forest = Color(red: 15/255, green: 41/255, blue: 34/255)
    // Every color below comes from the active theme (ThemeStore): views that read them re-render when it changes.
    static var theme: Theme { ThemeStore.shared.theme }
    static var accent: Color { theme.accent.color }
    static var graph: [Color] { theme.graph.map(\.color) }
    /// Semantic colors: removed / errors, warnings and conflicts, modified / remote / info, moved.
    static var addition: Color { theme.addition.color }
    static var danger: Color { theme.deletion.color }
    static var warning: Color { theme.warning.color }
    static var info: Color { theme.modified.color }
    static var special: Color { theme.renamed.color }
    /// Content and window backgrounds; system colors unless the theme defines its own (Drácula).
    static var surface: Color { theme.surface?.color ?? Color(nsColor: .textBackgroundColor) }
    static var background: Color { theme.background?.color ?? Color(nsColor: .windowBackgroundColor) }
    static var surfaceNS: NSColor { theme.surface?.ns ?? .textBackgroundColor }
    static var textNS: NSColor { theme.text?.ns ?? .textColor }
    /// Whether the theme paints its own backgrounds (lists then hide the system background).
    static var customBackgrounds: Bool { theme.surface != nil }
    static var logo: NSImage? { Bundle.module.url(forResource: "ButakeLogo", withExtension: "png").flatMap(NSImage.init(contentsOf:)) }
}
struct BrandMark: View {
    var size: CGFloat = 32
    var body: some View {
        Group {
            if let logo = Brand.logo { Image(nsImage: logo).resizable().scaledToFit().padding(size * 0.14) }
        }
        .frame(width: size, height: size)
        .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: size * 0.24))
        .accessibilityLabel("Butake")
    }
}
