import SwiftUI

/// Dropdown under the search field: typing `@` lists the filters; after `@autor:`, `@archivo:` or `@ext:` it lists
/// authors (with commit counts), tracked files or extensions (with file counts). Picking one completes the query.
struct SearchSuggestions: View {
    let store: WorkspaceStore
    var body: some View {
        let raw = store.search
        let words = SearchQuery.words(raw)
        let last = raw.hasSuffix(" ") ? "" : (words.last ?? "")
        let head = last.isEmpty ? raw : String(raw.dropLast(last.count))
        if last.hasPrefix("@") {
            if let colon = last.firstIndex(of: ":"), let kind = SearchQuery.Kind.parse(String(last[last.index(after: last.startIndex)..<colon])) {
                let partial = SearchQuery.unquote(String(last[last.index(after: colon)...]))
                ForEach(values(kind, partial: partial), id: \.value) { item in
                    Label { HStack { Text(item.value).lineLimit(1).truncationMode(.middle); Spacer(); if let count = item.count { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() } } } icon: { Image(systemName: icon(kind)) }
                        .searchCompletion(head + kind.token + SearchQuery.quoted(item.value) + " ")
                }
            } else {
                let typed = String(last.dropFirst()).lowercased()
                ForEach(SearchQuery.Kind.allCases.filter { kind in available(kind) && (typed.isEmpty || kind.aliases.contains { $0.hasPrefix(typed) }) }, id: \.self) { kind in
                    Label { HStack { Text(kind.token).font(.system(.body, design: .monospaced)); Text(L("searchKind.\(kind.rawValue)")).foregroundStyle(.secondary) } } icon: { Image(systemName: icon(kind)) }
                        .searchCompletion(head + kind.token)
                }
            }
        }
    }
    /// @autor only filters history; files and extensions work in History and Changes.
    private func available(_ kind: SearchQuery.Kind) -> Bool { kind != .author || store.route == .history }
    private func icon(_ kind: SearchQuery.Kind) -> String {
        switch kind { case .author: "person"; case .file: "doc"; case .ext: "number" }
    }
    private func values(_ kind: SearchQuery.Kind, partial: String) -> [(value: String, count: Int?)] {
        let needle = partial.lowercased()
        switch kind {
        case .author:
            return store.authorCounts.filter { needle.isEmpty || $0.name.lowercased().contains(needle) }.prefix(12).map { ($0.name, $0.count) }
        case .file:
            // In Changes, the changed files; in History, every tracked file. Name matches first, then path matches.
            let paths = store.route == .history ? store.trackedFiles : store.files.map(\.path)
            guard !needle.isEmpty else { return paths.prefix(12).map { ($0, nil) } }
            let byName = paths.filter { ($0 as NSString).lastPathComponent.lowercased().contains(needle) }
            let byPath = paths.filter { $0.lowercased().contains(needle) && !($0 as NSString).lastPathComponent.lowercased().contains(needle) }
            return (byName + byPath).prefix(12).map { ($0, nil) }
        case .ext:
            let paths = store.route == .history ? store.trackedFiles : store.files.map(\.path)
            var counts: [String: Int] = [:]
            for path in paths { let ext = (path as NSString).pathExtension.lowercased(); if !ext.isEmpty { counts[ext, default: 0] += 1 } }
            let clean = needle.hasPrefix(".") ? String(needle.dropFirst()) : needle
            return counts.filter { clean.isEmpty || $0.key.hasPrefix(clean) }.sorted { $0.value > $1.value }.prefix(12).map { ("." + $0.key, $0.value) }
        }
    }
}
