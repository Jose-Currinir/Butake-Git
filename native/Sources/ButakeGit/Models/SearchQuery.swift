import Foundation

/// Search with filters: free text plus `@autor:`, `@archivo:` and `@ext:` tokens (English aliases accepted).
/// Values with spaces go in quotes: `@archivo:"Perfil con mapa"`. Filters of the same kind are OR'ed; kinds are AND'ed.
struct SearchQuery: Equatable {
    enum Kind: String, CaseIterable {
        case author = "autor", file = "archivo", ext = "ext"
        /// Accepted spellings, Spanish first (the canonical one).
        var aliases: [String] {
            switch self {
            case .author: ["autor", "author", "a"]
            case .file: ["archivo", "file", "f"]
            case .ext: ["ext", "extension", "extensión", "e"]
            }
        }
        var token: String { "@\(rawValue):" }
        static func parse(_ name: String) -> Kind? { allCases.first { $0.aliases.contains(name.lowercased()) } }
    }

    var authors: [String] = []
    var files: [String] = []
    var exts: [String] = []
    var text = ""

    var isEmpty: Bool { authors.isEmpty && files.isEmpty && exts.isEmpty && text.isEmpty }
    /// File and extension filters need Git (which commits touched which paths).
    var hasPathFilters: Bool { !files.isEmpty || !exts.isEmpty }

    init(_ raw: String) {
        var free: [String] = []
        for word in SearchQuery.words(raw) {
            if word.hasPrefix("@"), let colon = word.firstIndex(of: ":"), let kind = Kind.parse(String(word[word.index(after: word.startIndex)..<colon])) {
                let value = SearchQuery.unquote(String(word[word.index(after: colon)...]))
                guard !value.isEmpty else { continue }
                switch kind {
                case .author: authors.append(value)
                case .file: files.append(value)
                case .ext: exts.append(value.hasPrefix(".") ? String(value.dropFirst()).lowercased() : value.lowercased())
                }
            } else if word != "@" {
                free.append(word)
            }
        }
        text = free.joined(separator: " ")
    }

    /// Words split on spaces, keeping quoted parts together (`@archivo:"a b"` is one word).
    static func words(_ raw: String) -> [String] {
        var result: [String] = [], current = "", quoted = false
        for character in raw {
            if character == "\"" { quoted.toggle(); current.append(character) }
            else if character == " " && !quoted { if !current.isEmpty { result.append(current); current = "" } }
            else { current.append(character) }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
    static func unquote(_ value: String) -> String { value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
    static func quoted(_ value: String) -> String { value.contains(" ") ? "\"\(value)\"" : value }

    func matches(author: String) -> Bool { authors.isEmpty || authors.contains { author.localizedCaseInsensitiveContains($0) } }
    /// Path filters applied to a changed file (Changes view): text, @archivo and @ext.
    func matches(path: String) -> Bool {
        (text.isEmpty || path.localizedCaseInsensitiveContains(text))
            && (files.isEmpty || files.contains { path.localizedCaseInsensitiveContains($0) })
            && (exts.isEmpty || exts.contains((path as NSString).pathExtension.lowercased()))
    }
    /// Literal paths for `git log -- <paths>`. The engine runs Git with `--literal-pathspecs` (no glob magic, by
    /// design), so matching happens here against the tracked files: @archivo by name or path, @ext by extension.
    func matchingPaths(in tracked: [String]) -> [String] {
        tracked.filter { path in
            (files.isEmpty || files.contains { path == $0 || path.localizedCaseInsensitiveContains($0) })
                && (exts.isEmpty || exts.contains((path as NSString).pathExtension.lowercased()))
        }
    }
}
