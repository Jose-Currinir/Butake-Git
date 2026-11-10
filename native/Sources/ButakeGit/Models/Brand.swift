import SwiftUI
import AppKit

func L(_ key: String) -> String { Bundle.module.localizedString(forKey: key, value: key, table: "Localizable") }
enum Brand {
    static let green = Color(red: 25/255, green: 215/255, blue: 159/255)
    static let forest = Color(red: 15/255, green: 41/255, blue: 34/255)
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 25/255, green: 215/255, blue: 159/255, alpha: 1) : NSColor(red: 11/255, green: 129/255, blue: 71/255, alpha: 1)
    })
    static let graph: [Color] = [.init(red: 25/255, green: 215/255, blue: 159/255), .init(red: 47/255, green: 127/255, blue: 216/255), .init(red: 34/255, green: 197/255, blue: 94/255), .orange, .teal]
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
