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
    /// Changes only when the set of files can have changed (repository, HEAD or the changed files), not on every
    /// status message: reloading on each status swapped the List for a spinner while its editor sheet was open.
    private var listKey: String {
        var hasher = Hasher()
        for file in store.files { hasher.combine(file.path); hasher.combine(file.index); hasher.combine(file.worktree) }
        return "\(store.repository?.root ?? "")|\(store.repository?.commits.first?.hash ?? "")|\(store.files.count)|\(hasher.finalize())"
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Label(L("files"), systemImage: "folder").font(.uiHeadline); Text("\(visible.count)").font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary); Spacer(); TextField(L("findFile"), text: $search).accessibilityIdentifier("files.findFile").textFieldStyle(.roundedBorder).frame(maxWidth: 300); Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityIdentifier("files.refresh").accessibilityLabel(L("refresh")).help(L("refresh")) }.padding(16).background(Brand.bar)
            Divider()
            if loading && files.isEmpty { Spinner(size: 18).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if !error.isEmpty { EmptyState(L("operationFailed"), systemImage: "exclamationmark.triangle", description: Text(error)).frame(maxHeight: .infinity) }
            else {
                let changed = Dictionary(store.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
                List(visible, id: \.self, selection: $selectedPath) { path in
                        let folder = (path as NSString).deletingLastPathComponent
                        HStack(spacing: 12) {
                            FileTypeIcon(path: path, size: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: path).lastPathComponent).font(.ui(size: 12.5, weight: .medium))
                                if !folder.isEmpty { Text(folder).font(.ui(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                            }
                            Spacer()
                            if let file = changed[path] { ChangeKindBadge(kind: file.kind) }
                            Image(systemName: "pencil").foregroundStyle(.tertiary).help(L("editFile"))
                        }.padding(.vertical, 4).contentShape(Rectangle())
                    .tag(path).help(path)
                    .accessibilityElement(children: .ignore).accessibilityLabel(path).accessibilityAddTraits(.isButton)
                    .accessibilityValue(changed[path]?.kind.title ?? "")
                    .accessibilityIdentifier("files.file.\(path)")
                    .accessibilityAction { target = FileEditorTarget(path: path) }
                    .accessibilityAction(named: L("editFile")) { target = FileEditorTarget(path: path) }
                }.listStyle(.inset).themedScroll().onChange(of: selectedPath) { _, path in if let path { Task { @MainActor in if selectedPath == path { target = FileEditorTarget(path: path) } } } }.overlay { if visible.isEmpty { EmptyState(L("noResults"), systemImage: "magnifyingglass") } }
            }
            Text(L("fileBrowserScope")).font(.uiCaption2).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Brand.bar)
        }.task(id: listKey) { await load() }
        .sheet(item: $target, onDismiss: { selectedPath = nil }) { target in FileEditorView(store: store, path: target.path).themedSheet() }
    }
    private func load() async {
        guard let root = store.repository?.root else { return }; loading = true; defer { loading = false }; error = ""
        do { let value: [String] = try await store.engine.call(["method": "files", "path": root]); guard !Task.isCancelled, store.repository?.root == root else { return }; if value != files { files = value } }
        catch { guard !Task.isCancelled else { return }; self.error = error.localizedDescription }
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
    /// Unsaved changes, kept as a flag: comparing the whole document several times per render was the cost of
    /// every keystroke in large files. Recomputed when the text or the saved content changes.
    @State private var dirty = false
    /// Bumped with every edit so the «Ver cambios» preview is rebuilt for the current text.
    @State private var revision = 0
    private var isMarkdown: Bool { ["md", "markdown", "mdx"].contains((path as NSString).pathExtension.lowercased()) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                FileTypeIcon(path: path, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text((path as NSString).lastPathComponent).font(.ui(size: 14, weight: .semibold)).lineLimit(1)
                        if dirty { Text(L("unsavedChanges")).font(.ui(size: 10, weight: .medium)).foregroundStyle(Brand.warning).padding(.horizontal, 6).padding(.vertical, 1).background(Brand.warning.opacity(0.12), in: Capsule()).transition(.opacity) }
                    }
                    let folder = (path as NSString).deletingLastPathComponent
                    if !folder.isEmpty { Label(folder, systemImage: "folder").font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
                Spacer()
                Picker(L("editorDisplay"), selection: $tab) {
                    Text(L("editFile")).tag(0); Text(L("originalFile")).tag(1); Text(L("previewChanges")).tag(2)
                    if isMarkdown { Text(L("markdownPreview")).tag(3) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize().accessibilityIdentifier("files.editorDisplay")
            }.padding(.horizontal, 16).padding(.vertical, 12).background(Brand.bar).animation(.snappy, value: dirty)
            Divider()
            if let original {
                // The editor stays mounted under the other tabs: switching tabs keeps its undo history, caret and scroll.
                ZStack {
                    CodeEditorView(text: $text, path: path, editable: tab == 0 && !saving && store.canWrite)
                        .opacity(tab == 0 ? 1 : 0).allowsHitTesting(tab == 0).accessibilityHidden(tab != 0)
                        .accessibilityLabel(L("fileContent")).accessibilityIdentifier("editor.content")
                    if tab == 1 { CodeEditorView(text: .constant(original.content), path: path, editable: false) }
                    else if tab == 3 { MarkdownPreview(source: text) }
                    else if tab == 2 {
                        if previewLoading { Spinner(size: 18).frame(maxWidth: .infinity, maxHeight: .infinity).background(Brand.surface) }
                        // Plain stack, not ContentUnavailableView: swapping the diff for one inside this sheet (saving while
                        // «Ver cambios» is open) sent SwiftUI into an endless layout cycle and froze the app.
                        else if !dirty { EditorNotice(icon: "equal.circle", title: L("noEditorChanges")) }
                        else { DiffView(text: preview, path: path) }
                    }
                }
            } else if error.isEmpty { Spinner(size: 18).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { EditorNotice(icon: "exclamationmark.triangle", title: L("operationFailed"), detail: error) }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if !error.isEmpty && original != nil { Text(error).font(.uiCaption).foregroundStyle(Brand.danger).textSelection(.enabled) }
                HStack { Text(L(store.onProtectedMain ? "editorProtected" : "saveWorkingOnly")).font(.uiCaption2).foregroundStyle(.secondary); Spacer(); Button(L("reloadFile")) { if dirty { discard = true } else { Task { await load() } } }.accessibilityIdentifier("files.reloadFile").disabled(saving || original == nil); Button(L("close")) { if dirty { discard = true } else { dismiss() } }.accessibilityIdentifier("files.close").keyboardShortcut(.cancelAction).disabled(saving); Button(L("saveFile")) { Task { await save() } }.accessibilityIdentifier("files.saveFile").buttonStyle(.borderedProminent).keyboardShortcut("s").disabled(!dirty || !store.canWrite || saving) }
            }.padding(16).background(Brand.bar)
        }.frame(minWidth: 800, idealWidth: 980, minHeight: 580, idealHeight: 700)
        .interactiveDismissDisabled(dirty || saving)
        .confirmationDialog(L("discardEditorChanges"), isPresented: $discard, titleVisibility: .visible) { Button(L("reloadFile"), role: .destructive) { Task { await load() } }.accessibilityIdentifier("files.discardAndReload"); Button(L("closeWithoutSaving"), role: .destructive) { dismiss() }.accessibilityIdentifier("files.closeWithoutSaving"); Button(L("cancel"), role: .cancel) {}.accessibilityIdentifier("files.cancel") }
        .task { tab = initialTab; await load() }
        .onChange(of: text) { _, value in revision &+= 1; let changed = original.map { value != $0.content } ?? false; if changed != dirty { dirty = changed } }
        .task(id: "\(tab)|\(revision)") {
            guard tab == 2, let original, let root = store.repository?.root, dirty else { previewLoading = false; return }
            previewLoading = true
            do {
                let value: String = try await store.engine.call(["method": "previewFile", "path": root, "expected": original.content, "content": text])
                guard !Task.isCancelled else { return } // the task that replaced this one owns the spinner now
                preview = value; previewLoading = false
            } catch { guard !Task.isCancelled else { return }; self.error = error.localizedDescription; previewLoading = false }
        }
    }
    private func load() async {
        guard let root = store.repository?.root else { return }; error = ""
        do { let value: WorkingFile = try await store.engine.call(["method": "readFile", "path": root, "file": path]); original = value; text = value.content; dirty = false; preview = "" }
        catch { self.error = error.localizedDescription }
    }
    private func save() async {
        guard let root = store.repository?.root, let original, store.canWrite, !saving else { return }; saving = true; store.busy = true
        defer { saving = false; store.busy = false }
        let content = text
        do { let _: String = try await store.engine.call(["method": "saveFile", "path": root, "file": path, "content": content, "expected": original.content, "head": original.head, "branch": original.branch, "confirmed": true]); self.original = WorkingFile(content: content, head: original.head, branch: original.branch); dirty = text != content; error = ""; await store.refresh(); store.status = L("fileSaved") }
        catch { self.error = error.localizedDescription }
    }
}

/// Empty or failed state inside the editor sheet (see the note on ContentUnavailableView above).
private struct EditorNotice: View {
    let icon: String; let title: String; var detail = ""
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.ui(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.ui(size: 15, weight: .semibold)).foregroundStyle(.secondary)
            if !detail.isEmpty { Text(detail).font(.uiCaption).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled).padding(.horizontal, 40) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Brand.surface).accessibilityElement(children: .combine)
    }
}

/// Readable preview of Markdown files: headings, lists, quotes, rules and code blocks.
struct MarkdownPreview: View {
    let source: String
    /// Parsed once per change of `source` (not on every render) and built lazily: a long document is thousands of blocks.
    @State private var blocks: [Block] = []
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in view(for: block) }
            }.padding(.horizontal, 36).padding(.vertical, 28).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Brand.surface).task(id: source) { blocks = Self.parse(source) }
    }
    private enum Block { case heading(Int, String), paragraph(String), bullet(String, Int, String), quote(String), rule, code(String) }
    private static func parse(_ source: String) -> [Block] {
        var result: [Block] = []; var code: [String]? = nil; var paragraph: [String] = []
        func flush() { if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] } }
        for piece in source.components(separatedBy: "\n") {
            // CRLF files: the carriage return stays at the end of each piece.
            let raw = piece.hasSuffix("\r") ? String(piece.dropLast()) : piece
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
            inline(text).font(.ui(size: [26, 20, 16.5, 14.5, 13.5, 13][min(level, 6) - 1], weight: level <= 2 ? .bold : .semibold)).padding(.top, level <= 2 ? 10 : 4)
            if level <= 2 { Divider() }
        case let .paragraph(text): inline(text).font(.ui(size: 13.5)).lineSpacing(3).textSelection(.enabled)
        case let .bullet(marker, indent, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) { Text(marker).font(.ui(size: 13.5, weight: .medium)).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing); inline(text).font(.ui(size: 13.5)).lineSpacing(3).textSelection(.enabled) }.padding(.leading, CGFloat(indent) * 18)
        case let .quote(text): inline(text).font(.ui(size: 13.5)).foregroundStyle(.secondary).padding(.leading, 12).overlay(alignment: .leading) { Rectangle().fill(Brand.accent.opacity(0.5)).frame(width: 3) }
        case .rule: Divider().padding(.vertical, 6)
        case let .code(text): Text(text).font(.ui(size: 12, design: .monospaced)).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
