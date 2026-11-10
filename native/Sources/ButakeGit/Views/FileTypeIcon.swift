import AppKit
import SwiftUI

/// Visual identity of a file type: a short label (or SF Symbol) on the color each ecosystem is known for.
/// Drawn in-app (no third-party logo assets), so it stays crisp at any size and in both appearances.
struct FileType: Hashable {
    var label: String
    var color: Color
    var symbol: String? = nil
    var darkText = false
    var name: String

    static func of(_ path: String) -> FileType {
        let file = (path as NSString).lastPathComponent.lowercased()
        if let match = byName[file] { return match }
        if file.hasSuffix(".blade.php") { return FileType(label: "BL", color: hex(0xF05340), name: "Blade") }
        if file.hasSuffix(".d.ts") { return FileType(label: "DTS", color: hex(0x3178C6), name: "TypeScript") }
        if file.hasPrefix(".env") { return FileType(label: "ENV", color: hex(0xECD53F), darkText: true, name: "Variables de entorno") }
        if file.hasPrefix("dockerfile") || file.hasSuffix(".dockerfile") { return FileType(label: "", color: hex(0x2496ED), symbol: "shippingbox.fill", name: "Docker") }
        if file.hasPrefix(".git") { return FileType(label: "GIT", color: hex(0xF05032), name: "Git") }
        let ext = (file as NSString).pathExtension
        return byExtension[ext] ?? FileType(label: ext.isEmpty ? "" : String(ext.prefix(3)).uppercased(), color: .gray, symbol: ext.isEmpty ? "doc.fill" : nil, name: ext.isEmpty ? L("file") : ext.uppercased())
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
    private static let byName: [String: FileType] = [
        "package.json": FileType(label: "NPM", color: hex(0xCB3837), name: "npm"),
        "package-lock.json": FileType(label: "NPM", color: hex(0xCB3837), name: "npm"),
        "composer.json": FileType(label: "CMP", color: hex(0x885630), name: "Composer"),
        "composer.lock": FileType(label: "CMP", color: hex(0x885630), name: "Composer"),
        "cargo.toml": FileType(label: "RS", color: hex(0xB7410E), name: "Cargo"),
        "cargo.lock": FileType(label: "RS", color: hex(0xB7410E), name: "Cargo"),
        "package.swift": FileType(label: "SW", color: hex(0xF05138), name: "Swift Package"),
        "makefile": FileType(label: "", color: hex(0x6D8086), symbol: "hammer.fill", name: "Makefile"),
        "artisan": FileType(label: "LV", color: hex(0xFF2D20), name: "Laravel"),
        "readme.md": FileType(label: "", color: hex(0x519ABA), symbol: "book.fill", name: "README"),
        "license": FileType(label: "", color: hex(0xC9A227), symbol: "checkmark.seal.fill", name: "Licencia"),
        "license.md": FileType(label: "", color: hex(0xC9A227), symbol: "checkmark.seal.fill", name: "Licencia"),
    ]
    private static let byExtension: [String: FileType] = {
        var map: [String: FileType] = [:]
        func add(_ exts: [String], _ type: FileType) { for ext in exts { map[ext] = type } }
        add(["php"], FileType(label: "PHP", color: hex(0x777BB4), name: "PHP"))
        add(["py", "pyw", "pyi"], FileType(label: "PY", color: hex(0x3776AB), name: "Python"))
        add(["ipynb"], FileType(label: "NB", color: hex(0xF37626), name: "Jupyter"))
        add(["js", "mjs", "cjs"], FileType(label: "JS", color: hex(0xF7DF1E), darkText: true, name: "JavaScript"))
        add(["ts", "mts", "cts"], FileType(label: "TS", color: hex(0x3178C6), name: "TypeScript"))
        add(["jsx"], FileType(label: "JSX", color: hex(0x61DAFB), darkText: true, name: "React JSX"))
        add(["tsx"], FileType(label: "TSX", color: hex(0x3178C6), name: "React TSX"))
        add(["vue"], FileType(label: "VUE", color: hex(0x42B883), name: "Vue"))
        add(["svelte"], FileType(label: "SV", color: hex(0xFF3E00), name: "Svelte"))
        add(["astro"], FileType(label: "AST", color: hex(0xFF5D01), name: "Astro"))
        add(["css"], FileType(label: "CSS", color: hex(0x1572B6), name: "CSS"))
        add(["scss", "sass"], FileType(label: "SASS", color: hex(0xCC6699), name: "Sass"))
        add(["less"], FileType(label: "LESS", color: hex(0x1D365D), name: "Less"))
        add(["html", "htm"], FileType(label: "HTML", color: hex(0xE34F26), name: "HTML"))
        add(["md", "markdown"], FileType(label: "MD", color: hex(0x4A5560), name: "Markdown"))
        add(["mdx"], FileType(label: "MDX", color: hex(0x1B1F24), name: "MDX"))
        add(["json", "jsonc"], FileType(label: "{ }", color: hex(0xCBA70A), name: "JSON"))
        add(["yml", "yaml"], FileType(label: "YML", color: hex(0xCB171E), name: "YAML"))
        add(["toml"], FileType(label: "TOML", color: hex(0x9C4221), name: "TOML"))
        add(["xml", "plist"], FileType(label: "XML", color: hex(0xF1662A), name: "XML"))
        add(["swift"], FileType(label: "SW", color: hex(0xF05138), name: "Swift"))
        add(["rs"], FileType(label: "RS", color: hex(0xB7410E), name: "Rust"))
        add(["go"], FileType(label: "GO", color: hex(0x00ADD8), name: "Go"))
        add(["java"], FileType(label: "JAVA", color: hex(0xEA2D2E), name: "Java"))
        add(["kt", "kts"], FileType(label: "KT", color: hex(0x7F52FF), name: "Kotlin"))
        add(["dart"], FileType(label: "DART", color: hex(0x0175C2), name: "Dart"))
        add(["rb", "erb"], FileType(label: "RB", color: hex(0xCC342D), name: "Ruby"))
        add(["c", "h"], FileType(label: "C", color: hex(0x5C6BC0), name: "C"))
        add(["cpp", "cc", "hpp", "cxx"], FileType(label: "C++", color: hex(0x00599C), name: "C++"))
        add(["cs"], FileType(label: "C#", color: hex(0x68217A), name: "C#"))
        add(["m", "mm"], FileType(label: "OBJC", color: hex(0x438EFF), name: "Objective-C"))
        add(["sh", "bash", "zsh", "fish"], FileType(label: "SH", color: hex(0x4EAA25), name: "Shell"))
        add(["ps1"], FileType(label: "PS", color: hex(0x012456), name: "PowerShell"))
        add(["sql"], FileType(label: "SQL", color: hex(0xE38C00), name: "SQL"))
        add(["prisma"], FileType(label: "PRS", color: hex(0x2D3748), name: "Prisma"))
        add(["graphql", "gql"], FileType(label: "GQL", color: hex(0xE10098), name: "GraphQL"))
        add(["tf", "tfvars"], FileType(label: "TF", color: hex(0x7B42BC), name: "Terraform"))
        add(["lua"], FileType(label: "LUA", color: hex(0x000080), name: "Lua"))
        add(["r"], FileType(label: "R", color: hex(0x276DC3), name: "R"))
        add(["csv", "tsv"], FileType(label: "CSV", color: hex(0x217346), name: "CSV"))
        add(["xlsx", "xls"], FileType(label: "XLS", color: hex(0x217346), name: "Excel"))
        add(["docx", "doc"], FileType(label: "DOC", color: hex(0x2B579A), name: "Word"))
        add(["pdf"], FileType(label: "PDF", color: hex(0xD93025), name: "PDF"))
        add(["txt", "text"], FileType(label: "TXT", color: hex(0x8A939C), name: "Texto"))
        add(["log"], FileType(label: "LOG", color: hex(0x8A939C), name: "Registro"))
        add(["lock"], FileType(label: "", color: hex(0x8A939C), symbol: "lock.fill", name: "Lock"))
        add(["ini", "cfg", "conf", "config", "properties", "editorconfig"], FileType(label: "", color: hex(0x6D8086), symbol: "gearshape.fill", name: "Configuración"))
        add(["svg"], FileType(label: "SVG", color: hex(0xFFB13B), darkText: true, name: "SVG"))
        add(["png", "jpg", "jpeg", "gif", "webp", "heic", "ico", "bmp", "avif"], FileType(label: "", color: hex(0xA259FF), symbol: "photo.fill", name: "Imagen"))
        add(["mp4", "mov", "webm", "avi"], FileType(label: "", color: hex(0xE91E63), symbol: "film.fill", name: "Video"))
        add(["mp3", "wav", "m4a", "ogg"], FileType(label: "", color: hex(0xE91E63), symbol: "waveform", name: "Audio"))
        add(["ttf", "otf", "woff", "woff2"], FileType(label: "Aa", color: hex(0x5C6BC0), name: "Fuente"))
        add(["zip", "gz", "tar", "rar", "7z"], FileType(label: "", color: hex(0x8D6E63), symbol: "archivebox.fill", name: "Archivo comprimido"))
        add(["bin", "exe", "dylib", "so", "o", "a"], FileType(label: "", color: hex(0x6D8086), symbol: "cpu.fill", name: "Binario"))
        return map
    }()
}

/// Material Icon Theme (MIT) file icons bundled in FileIcons/; see LICENSE-material-icon-theme.txt.
@MainActor final class MaterialFileIcons {
    static let shared = MaterialFileIcons()
    private struct Mapping: Decodable {
        var file: String; var names: [String: String]; var extensions: [String: String]
        var lightNames: [String: String]; var lightExtensions: [String: String]
    }
    private let mapping: Mapping?
    private let folder: URL?
    private var images: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private init() {
        // Folder resources are not found by url(forResource:); resolve them from the bundle's resource root.
        folder = [Bundle.module.resourceURL, Bundle.module.bundleURL].compactMap { $0?.appendingPathComponent("FileIcons") }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("map.json").path) }
        mapping = folder.flatMap { try? Data(contentsOf: $0.appendingPathComponent("map.json")) }.flatMap { try? JSONDecoder().decode(Mapping.self, from: $0) }
    }
    /// Icon name for a path: exact file name first, then the longest dotted suffix ("blade.php" before "php").
    func iconName(for path: String, light: Bool) -> String? {
        guard let mapping else { return nil }
        let name = (path as NSString).lastPathComponent.lowercased()
        if light, let icon = mapping.lightNames[name] { return icon }
        if let icon = mapping.names[name] { return icon }
        var parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.first == "" { parts.removeFirst() } // ".env.example" → ["env", "example"]
        for start in (name.hasPrefix(".") ? 0 : 1)..<parts.count {
            let suffix = parts[start...].joined(separator: ".")
            if light, let icon = mapping.lightExtensions[suffix] { return icon }
            if let icon = mapping.extensions[suffix] { return icon }
        }
        return mapping.file
    }
    func image(for path: String, light: Bool) -> NSImage? {
        guard let name = iconName(for: path, light: light), let folder, !missing.contains(name) else { return nil }
        if let cached = images[name] { return cached }
        guard let image = NSImage(contentsOf: folder.appendingPathComponent(name + ".svg")) else { missing.insert(name); return nil }
        images[name] = image
        return image
    }
}

struct FileTypeIcon: View {
    let path: String
    var size: CGFloat = 16
    var body: some View {
        let type = FileType.of(path)
        if let image = MaterialFileIcons.shared.image(for: path, light: scheme == .light) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .help(type.name).accessibilityLabel(type.name)
        } else {
            badge(type)
        }
    }
    @Environment(\.colorScheme) private var scheme
    private func badge(_ type: FileType) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(type.color.gradient)
                .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            if let symbol = type.symbol {
                Image(systemName: symbol).font(.system(size: size * 0.52, weight: .semibold)).foregroundStyle(.white)
            } else {
                Text(type.label)
                    .font(.system(size: size * (type.label.count > 3 ? 0.36 : type.label.count == 3 ? 0.40 : 0.48), weight: .heavy, design: .rounded))
                    .tracking(-0.3).lineLimit(1).minimumScaleFactor(0.5)
                    .foregroundStyle(type.darkText ? Color.black.opacity(0.82) : .white)
                    .padding(.horizontal, size * 0.06)
            }
        }
        .frame(width: size, height: size)
        .help(type.name).accessibilityLabel(type.name)
    }
}
