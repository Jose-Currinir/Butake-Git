import SwiftUI

struct FileBrowserView: View {
    @Bindable var store: WorkspaceStore
    @State private var files: [String] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error = ""
    @State private var selectedPath: String?
    @State private var target: FileEditorTarget?
    private var visible: [String] { files.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Label(L("files"), systemImage: "folder").font(.headline); Text("\(visible.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary); Spacer(); TextField(L("findFile"), text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 300); Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help(L("refresh")) }.padding(16).background(.bar)
            Divider()
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if !error.isEmpty { ContentUnavailableView(L("operationFailed"), systemImage: "exclamationmark.triangle", description: Text(error)).frame(maxHeight: .infinity) }
            else {
                let changed = Dictionary((store.repository?.files ?? []).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
                List(visible, id: \.self, selection: $selectedPath) { path in
                        let folder = (path as NSString).deletingLastPathComponent
                        HStack(spacing: 12) {
                            FileTypeIcon(path: path, size: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12.5, weight: .medium))
                                if !folder.isEmpty { Text(folder).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                            }
                            Spacer()
                            if let file = changed[path] { ChangeKindBadge(kind: file.kind) }
                            Image(systemName: "pencil").foregroundStyle(.tertiary).help(L("editFile"))
                        }.padding(.vertical, 4).contentShape(Rectangle())
                    .tag(path).help(path)
                }.listStyle(.inset).onChange(of: selectedPath) { _, path in if let path { target = FileEditorTarget(path: path) } }.overlay { if visible.isEmpty { ContentUnavailableView(L("noResults"), systemImage: "magnifyingglass") } }
            }
            Text(L("fileBrowserScope")).font(.caption2).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
        }.task(id: "\(store.repository?.root ?? "")|\(store.status)") { await load() }
        .sheet(item: $target, onDismiss: { selectedPath = nil }) { target in FileEditorView(store: store, path: target.path) }
    }
    private func load() async {
        guard let root = store.repository?.root else { return }; loading = true; defer { loading = false }; error = ""
        do { files = try await store.engine.call(["method": "files", "path": root]) } catch { self.error = error.localizedDescription }
    }
}
struct FileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let store: WorkspaceStore; let path: String
    var initialTab = 0
    @State private var original: WorkingFile?
    @State private var text = ""
    @State private var error = ""
    @State private var saving = false
    @State private var tab = 0
    @State private var preview = ""
    @State private var previewLoading = false
    @State private var discard = false
    private var dirty: Bool { original != nil && text != original?.content }
    private var isMarkdown: Bool { ["md", "markdown", "mdx"].contains((path as NSString).pathExtension.lowercased()) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                FileTypeIcon(path: path, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text((path as NSString).lastPathComponent).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if dirty { Text(L("unsavedChanges")).font(.system(size: 10, weight: .medium)).foregroundStyle(.orange).padding(.horizontal, 6).padding(.vertical, 1).background(.orange.opacity(0.12), in: Capsule()).transition(.opacity) }
                    }
                    let folder = (path as NSString).deletingLastPathComponent
                    if !folder.isEmpty { Label(folder, systemImage: "folder").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
                Spacer()
                Picker(L("editorDisplay"), selection: $tab) {
                    Text(L("editFile")).tag(0); Text(L("originalFile")).tag(1); Text(L("previewChanges")).tag(2)
                    if isMarkdown { Text(L("markdownPreview")).tag(3) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }.padding(.horizontal, 16).padding(.vertical, 12).background(.bar).animation(.snappy, value: dirty)
            Divider()
            if let original {
                if tab == 0 { CodeEditorView(text: $text, path: path, editable: !saving && store.canWrite).accessibilityLabel(L("fileContent")).accessibilityIdentifier("editor.content") }
                else if tab == 1 { CodeEditorView(text: .constant(original.content), path: path, editable: false) }
                else if tab == 3 { MarkdownPreview(source: text) }
                else if previewLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if !dirty { ContentUnavailableView(L("noEditorChanges"), systemImage: "equal.circle").frame(maxHeight: .infinity) }
                else { DiffView(text: preview, path: path) }
            } else if error.isEmpty { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ContentUnavailableView(L("operationFailed"), systemImage: "exclamationmark.triangle", description: Text(error)).frame(maxHeight: .infinity) }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if !error.isEmpty && original != nil { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                HStack { Text(L(store.onProtectedMain ? "editorProtected" : "saveWorkingOnly")).font(.caption2).foregroundStyle(.secondary); Spacer(); Button(L("reloadFile")) { if dirty { discard = true } else { Task { await load() } } }.disabled(saving || original == nil); Button(L("close")) { if dirty { discard = true } else { dismiss() } }.keyboardShortcut(.cancelAction); Button(L("saveFile")) { Task { await save() } }.buttonStyle(.borderedProminent).keyboardShortcut("s").disabled(!dirty || !store.canWrite || saving) }
            }.padding(16).background(.bar)
        }.frame(minWidth: 800, idealWidth: 980, minHeight: 580, idealHeight: 700)
        .interactiveDismissDisabled(dirty || saving)
        .confirmationDialog(L("discardEditorChanges"), isPresented: $discard, titleVisibility: .visible) { Button(L("reloadFile"), role: .destructive) { Task { await load() } }; Button(L("closeWithoutSaving"), role: .destructive) { dismiss() }; Button(L("cancel"), role: .cancel) {} }
        .task { tab = initialTab; await load() }
        .task(id: tab) {
            guard tab == 2, let original, let root = store.repository?.root, dirty else { return }
            previewLoading = true
            do { let value: String = try await store.engine.call(["method": "previewFile", "path": root, "expected": original.content, "content": text]); guard !Task.isCancelled else { return }; preview = value; previewLoading = false } catch { guard !Task.isCancelled else { return }; self.error = error.localizedDescription; previewLoading = false }
        }
    }
    private func load() async {
        guard let root = store.repository?.root else { return }; error = ""
        do { let value: WorkingFile = try await store.engine.call(["method": "readFile", "path": root, "file": path]); original = value; text = value.content; preview = "" }
        catch { self.error = error.localizedDescription }
    }
    private func save() async {
        guard let root = store.repository?.root, let original, store.canWrite else { return }; saving = true; store.busy = true
        defer { saving = false; store.busy = false }
        do { let _: String = try await store.engine.call(["method": "saveFile", "path": root, "file": path, "content": text, "expected": original.content, "head": original.head, "branch": original.branch, "confirmed": true]); self.original = WorkingFile(content: text, head: original.head, branch: original.branch); error = ""; await store.refresh(); store.status = L("fileSaved") }
        catch { self.error = error.localizedDescription }
    }
}

/// Readable preview of Markdown files: headings, lists, quotes, rules and code blocks.
struct MarkdownPreview: View {
    let source: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in view(for: block) }
            }.padding(.horizontal, 36).padding(.vertical, 28).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Color(nsColor: .textBackgroundColor))
    }
    private enum Block { case heading(Int, String), paragraph(String), bullet(String, Int, String), quote(String), rule, code(String) }
    private var blocks: [Block] {
        var result: [Block] = []; var code: [String]? = nil; var paragraph: [String] = []
        func flush() { if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] } }
        for raw in source.components(separatedBy: "\n") {
            if raw.hasPrefix("```") { if let lines = code { result.append(.code(lines.joined(separator: "\n"))); code = nil } else { flush(); code = [] }; continue }
            if code != nil { code?.append(raw); continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indent = (raw.prefix { $0 == " " }.count) / 2
            if line.isEmpty { flush(); continue }
            if let hashes = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"), line[hashes] == " " { flush(); result.append(.heading(line.distance(from: line.startIndex, to: hashes), String(line[hashes...]).trimmingCharacters(in: .whitespaces))); continue }
            if line == "---" || line == "***" { flush(); result.append(.rule); continue }
            if line.hasPrefix("> ") { flush(); result.append(.quote(String(line.dropFirst(2)))); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { flush(); result.append(.bullet("•", indent, String(line.dropFirst(2)))); continue }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty, line[line.index(after: dot)...].hasPrefix(" ") { flush(); result.append(.bullet(String(line[...dot]), indent, String(line[line.index(dot, offsetBy: 2)...]))); continue }
            paragraph.append(line)
        }
        flush(); if let lines = code { result.append(.code(lines.joined(separator: "\n"))) }
        return result
    }
    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }
    @ViewBuilder private func view(for block: Block) -> some View {
        switch block {
        case let .heading(level, text):
            inline(text).font(.system(size: [26, 20, 16.5, 14.5, 13.5, 13][min(level, 6) - 1], weight: level <= 2 ? .bold : .semibold)).padding(.top, level <= 2 ? 10 : 4)
            if level <= 2 { Divider() }
        case let .paragraph(text): inline(text).font(.system(size: 13.5)).lineSpacing(3).textSelection(.enabled)
        case let .bullet(marker, indent, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) { Text(marker).font(.system(size: 13.5, weight: .medium)).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing); inline(text).font(.system(size: 13.5)).lineSpacing(3).textSelection(.enabled) }.padding(.leading, CGFloat(indent) * 18)
        case let .quote(text): inline(text).font(.system(size: 13.5)).foregroundStyle(.secondary).padding(.leading, 12).overlay(alignment: .leading) { Rectangle().fill(Brand.accent.opacity(0.5)).frame(width: 3) }
        case .rule: Divider().padding(.vertical, 6)
        case let .code(text): Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
