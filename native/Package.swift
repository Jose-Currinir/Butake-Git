// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ButakeGit",
    defaultLocalization: "es",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ButakeGit", targets: ["ButakeGit"])],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.11.0"),
        // Themes and text size shared with Butake Stack.
        .package(url: "https://github.com/Jose-Currinir/Butake-Design.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(name: "ButakeGit", dependencies: ["SwiftTerm", .product(name: "ButakeDesign", package: "Butake-Design")], resources: [.process("Resources"), .copy("FileIcons")]),
        .testTarget(name: "ButakeGitTests", dependencies: ["ButakeGit"]),
    ],
    swiftLanguageModes: [.v5]
)
