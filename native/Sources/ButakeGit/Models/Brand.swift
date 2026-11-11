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
    /// Header and toolbar strips: the system bar material, or the theme's window background when it has one.
    static var bar: AnyShapeStyle { customBackgrounds ? AnyShapeStyle(background) : AnyShapeStyle(.bar) }
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

extension View {
    /// Lists, forms and tables show the theme's surface instead of the system background.
    func themedScroll() -> some View { scrollContentBackground(Brand.customBackgrounds ? .hidden : .automatic) }
    /// Sheets, popovers and secondary windows take the theme's background and accent like the main window.
    func themedSheet() -> some View { background { if Brand.customBackgrounds { Brand.background.ignoresSafeArea() } }.tint(Brand.accent).scaledText() }
    /// Text without an explicit font (sidebar rows, plain labels) follows the size chosen with ⌘+ / ⌘−.
    @MainActor func scaledText() -> some View { font(TextScale.shared.factor == 1 ? nil : Font.ui(size: 13)) }
}

/// Empty or error placeholder: icon, title, optional description and actions, centered in the available space.
/// Used instead of SwiftUI's `ContentUnavailableView`, which inside sheets sent the view graph into an endless
/// cycle on this macOS (saving in the editor with «Ver cambios» open, or any accessibility query while
/// «Organizar commits» was open) and froze the app.
struct EmptyState<Title: View, Description: View, Actions: View>: View {
    private let title: Title; private let description: Description; private let actions: Actions
    init(@ViewBuilder label: () -> Title, @ViewBuilder description: () -> Description, @ViewBuilder actions: () -> Actions) {
        title = label(); self.description = description(); self.actions = actions()
    }
    var body: some View {
        VStack(spacing: 10) {
            title.labelStyle(EmptyStateLabelStyle())
            description.font(.ui(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            actions
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
extension EmptyState where Actions == EmptyView {
    init(@ViewBuilder label: () -> Title, @ViewBuilder description: () -> Description) { self.init(label: label, description: description, actions: { EmptyView() }) }
}
extension EmptyState where Title == Label<Text, Image>, Description == Text?, Actions == EmptyView {
    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.init(label: { Label(title, systemImage: systemImage) }, description: { description }, actions: { EmptyView() })
    }
}
private struct EmptyStateLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 10) {
            configuration.icon.font(.ui(size: 34, weight: .light)).foregroundStyle(.tertiary)
            configuration.title.font(.ui(size: 16, weight: .semibold)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}
