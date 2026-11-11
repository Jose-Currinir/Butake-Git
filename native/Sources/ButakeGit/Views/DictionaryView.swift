import SwiftUI

struct DictionaryView: View {
    @Bindable var store: WorkspaceStore
    @State private var query = ""
    @State private var mode = "commands"
    @State private var category = ""
    @State private var selection: String? = "rebase"
    @State private var manual = ""
    @State private var loadingHelp = false
    var filtered: [GitCommandEntry] { store.catalog.catalog.commands.filter { entry in (category.isEmpty || entry.category == category) && (query.isEmpty || entry.name.localizedCaseInsensitiveContains(query) || store.catalog.description(entry).localizedCaseInsensitiveContains(query)) } }
    var concepts: [GlossaryEntry] { store.catalog.glossary.filter { query.isEmpty || "\($0.term) \($0.definition)".localizedCaseInsensitiveContains(query) } }
    var entry: GitCommandEntry? { store.catalog.catalog.commands.first { $0.name == selection } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(L("dictionary"), selection: $mode) { Text(L("commands")).tag("commands"); Text(L("concepts")).tag("concepts") }.accessibilityIdentifier("dictionary.dictionary").pickerStyle(.segmented).frame(width: 240)
                Spacer()
                if mode == "commands" { Menu { Button(L("commands")) { category = "" }.accessibilityIdentifier("dictionary.category.all"); ForEach(["everyday", "administration", "inspection", "interop", "plumbing-write", "plumbing-read", "transport", "helpers"], id: \.self) { group in Button(L(group)) { category = group }.accessibilityIdentifier("dictionary.category.\(group)") } } label: { Label(category.isEmpty ? L("category") : L(category), systemImage: "line.3.horizontal.decrease") }.accessibilityIdentifier("dictionary.commands").menuStyle(.borderlessButton).fixedSize() }
            }.padding(16).background(Brand.bar)
            Divider()
            if mode == "commands" {
                HSplitView {
                    List(filtered, selection: $selection) { command in HStack { Text(command.name).font(.ui(size: 12, weight: .medium, design: .monospaced)); Spacer(); if command.visual != nil { Image(systemName: "rectangle.3.group").font(.uiCaption2).foregroundStyle(.secondary) } }.padding(.vertical, 4).tag(command.name) }.frame(minWidth: 180, idealWidth: 220, maxWidth: 310)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if let entry {
                                HStack(alignment: .firstTextBaseline) { Text("git \(entry.name)").font(.ui(size: 27, weight: .semibold, design: .monospaced)); Spacer(); if entry.experimental { Text(L("experimental")).font(.uiCaption2).foregroundStyle(Brand.warning) } }
                                Text(store.catalog.description(entry)).font(.uiTitle3).foregroundStyle(.secondary).textSelection(.enabled)
                                HStack(spacing: 8) { Text(L(entry.category)).font(.uiCaption); Text("·").foregroundStyle(.tertiary); Label(availability(entry), systemImage: installed(entry) ? "checkmark.circle.fill" : "info.circle").font(.uiCaption).foregroundStyle(installed(entry) ? Brand.accent : .secondary) }
                                Divider()
                                Text(L("catalogNote")).font(.uiCaption).foregroundStyle(.secondary)
                                HStack { Button(L("inspectConsole")) { store.inspect(entry.name) }.accessibilityIdentifier("dictionary.inspectConsole").buttonStyle(.borderedProminent).disabled(!installed(entry)); if let documentation = URL(string: entry.documentation) { Link(L("officialDocs"), destination: documentation) } }
                                Button(L("localHelp")) { loadHelp(entry) }.accessibilityIdentifier("dictionary.localHelp").disabled(loadingHelp)
                                if loadingHelp { Spinner(size: 14) }
                                if !manual.isEmpty { Text(manual).font(.ui(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9)) }
                            } else { EmptyState(L("noResults"), systemImage: "book.closed") }
                        }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minWidth: 320)
                }
            } else {
                List(concepts) { concept in VStack(alignment: .leading, spacing: 7) { Text(concept.term).font(.uiHeadline).foregroundStyle(Brand.accent); Text(concept.definition).font(.ui(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }.padding(.vertical, 9) }.listStyle(.inset).themedScroll()
            }
            HStack { Text("\(mode == "commands" ? filtered.count : concepts.count) / \(mode == "commands" ? store.catalog.catalog.commands.count : store.catalog.glossary.count)"); Spacer(); Text(store.capabilities?.version ?? store.catalog.catalog.gitVersion) }.font(.uiCaption2).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
        }.searchable(text: $query, prompt: L("searchDictionary")).onChange(of: selection) { _, _ in manual = "" }
    }
    private func installed(_ entry: GitCommandEntry) -> Bool { store.capabilities?.commands.first { $0.name == entry.name }?.available ?? false }
    private func availability(_ entry: GitCommandEntry) -> String { guard let info = store.capabilities?.commands.first(where: { $0.name == entry.name }) else { return L("checking") }; return L(info.library ? "library" : info.available ? "available" : "unavailable") }
    private func loadHelp(_ entry: GitCommandEntry) { loadingHelp = true; Task {
            defer { loadingHelp = false }
            // The help of a command that is no longer selected is dropped.
            let text: String
            do { text = try await store.engine.call(["method": "help", "command": entry.name]) } catch { text = error.localizedDescription }
            if selection == entry.name { manual = text }
        }
    }
}
