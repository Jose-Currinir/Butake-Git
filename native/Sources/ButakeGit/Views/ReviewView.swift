import SwiftUI

/// Reviewer for large change sets (typically produced by AI agents): folder tree with counts,
/// filters, per-file "reviewed" marks tied to content, and a keyboard-driven review loop.
struct ReviewView: View {
    @Bindable var store: WorkspaceStore
    @State private var extensionFilter: String?
    @State private var kindFilter: ChangeKind?
    @State private var hideReviewed = false
    @State private var selection: String?
    @State private var discarding: [ChangedFile] = []
    /// Collapsed folder ids; everything else is open, so a reviewer sees files by default.
    @State private var collapsed: Set<String> = []
    @FocusState private var treeFocused: Bool

    var body: some View {
        let model = store.reviewTree(query: store.search, extensionFilter: extensionFilter, kindFilter: kindFilter, hideReviewed: hideReviewed)
        VStack(spacing: 0) {
            header(files: model.files)
            Divider()
            if store.repository?.files.isEmpty ?? true {
                ContentUnavailableView(L("clean"), systemImage: "checkmark.circle", description: Text(L("cleanDetail"))).frame(maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    tree(model)
                        .frame(minWidth: 320, idealWidth: 380, maxWidth: 480)
                    Divider()
                    detail(files: model.files)
                }
            }
        }
        .confirmationDialog(String(format: L("discardFolderTitle"), discarding.count), isPresented: Binding(get: { !discarding.isEmpty }, set: { if !$0 { discarding = [] } }), titleVisibility: .visible) {
            Button(L("discard"), role: .destructive) { let files = discarding; discarding = []; Task { await discard(files) } }
        } message: { Text(L("discardFolderDetail")) }
    }

    // MARK: Header: progress and filters

    private func header(files: [ChangedFile]) -> some View {
        let total = store.repository?.files.count ?? 0
        let done = store.reviewedCount
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: L("reviewProgress"), done, total)).font(.system(size: 13, weight: .semibold)).contentTransition(.numericText(value: Double(done)))
                    ProgressView(value: Double(done), total: Double(max(total, 1))).progressViewStyle(.linear).tint(Brand.accent).frame(width: 260)
                }
                Spacer()
                Toggle(L("hideReviewed"), isOn: $hideReviewed).toggleStyle(.checkbox).controlSize(.small).accessibilityIdentifier("review.hideReviewed")
                Button { nextUnreviewed(in: files) } label: { Label(L("nextUnreviewed"), systemImage: "arrow.down.to.line.compact") }
                    .controlSize(.small).disabled(done == total).accessibilityIdentifier("review.next")
                Menu {
                    Button(L("expandAll")) { withAnimation(.snappy) { collapsed = [] } }
                    Button(L("collapseAll")) { withAnimation(.snappy) { collapsed = Set(allFolderIDs(store.reviewTree(query: store.search, extensionFilter: extensionFilter, kindFilter: kindFilter, hideReviewed: hideReviewed).nodes)) } }
                    Divider()
                    Button(L("markAllVisible")) { store.setReviewed(files, true) }
                    Button(L("unmarkAll")) { store.setReviewed(store.repository?.files ?? [], false) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel(L("more"))
            }
            let summary = store.changeSummary
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    // Change types first ("Nuevos 120 · Eliminados 30 …"), then extensions.
                    ForEach(summary.kinds, id: \.kind) { item in
                        KindChip(kind: item.kind, count: item.count, active: kindFilter == item.kind) { kindFilter = kindFilter == item.kind ? nil : item.kind }
                    }
                    if summary.additions + summary.deletions > 0 {
                        StatsBadge(stats: LineStats(additions: summary.additions, deletions: summary.deletions)).padding(.horizontal, 6)
                    }
                    Divider().frame(height: 14)
                    FilterChip(title: L("allFiles"), count: total, active: extensionFilter == nil && kindFilter == nil) { extensionFilter = nil; kindFilter = nil }
                    ForEach(store.changeExtensions, id: \.ext) { item in
                        FilterChip(title: ".\(item.ext)", count: item.count, active: extensionFilter == item.ext) { extensionFilter = extensionFilter == item.ext ? nil : item.ext }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12).background(.bar)
        .animation(.snappy, value: done)
    }

    // MARK: Tree

    private func tree(_ model: (nodes: [ChangeNode], files: [ChangedFile])) -> some View {
        // Flat rows with indentation: lets the reviewer reveal the selected file and expand/collapse everything.
        ScrollViewReader { proxy in
        List(selection: $selection) {
          ForEach(visibleRows(model.nodes), id: \.node.id) { row in
            ReviewNodeRow(store: store, node: row.node, depth: row.depth, collapsed: collapsed.contains(row.node.id)) {
                withAnimation(.snappy(duration: 0.18)) { if collapsed.contains(row.node.id) { collapsed.remove(row.node.id) } else { collapsed.insert(row.node.id) } }
            }
                .tag(row.node.id)
                .contextMenu { menu(for: row.node) }
                .accessibilityIdentifier("review.node.\(row.node.id)")
                .accessibilityAction(named: L("markReviewed")) { store.setReviewed(row.node.files, true) }
                .accessibilityAction(named: L("stage")) { store.stageFiles(row.node.files.filter { $0.worktree != " " || $0.index == "?" }, staged: false) }
          }
        }
        .listStyle(.inset)
        .focused($treeFocused)
        .onChange(of: selection) { _, id in
            if let file = model.files.first(where: { $0.path == id }) { store.reviewSelect(file) }
            if let id { DispatchQueue.main.async { withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) } } }
        }
        .onChange(of: store.selectedFile?.path, initial: true) { _, path in
            guard let path, path != selection, model.files.contains(where: { $0.path == path }) else { return }
            reveal(path); selection = path
        }
        .onKeyPress(.space) { toggleSelected(in: model.files) }
        .onKeyPress(characters: .init(charactersIn: "sS")) { _ in stageSelected(in: model.files) }
        .onKeyPress(characters: .init(charactersIn: "nN")) { _ in nextUnreviewed(in: model.files); return .handled }
        .overlay { if model.files.isEmpty { ContentUnavailableView(L("noResults"), systemImage: "line.3.horizontal.decrease.circle", description: Text(L("reviewFilterEmpty"))) } }
        .safeAreaInset(edge: .bottom) {
            Text(L("reviewKeys")).font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 6).background(.bar)
        }
        }
    }

    @ViewBuilder private func menu(for node: ChangeNode) -> some View {
        let unstaged = node.files.filter { $0.worktree != " " || $0.index == "?" }
        let allReviewed = node.files.allSatisfy(store.isReviewed)
        Button(allReviewed ? L("unmarkReviewed") : L("markReviewed")) { store.setReviewed(node.files, !allReviewed) }
        Button(String(format: L("stageCount"), unstaged.count)) { store.stageFiles(unstaged, staged: false) }.disabled(unstaged.isEmpty)
        Button(L("discardChanges"), role: .destructive) { discarding = unstaged.filter { !$0.conflict } }.disabled(unstaged.isEmpty)
        Divider()
        Button(L("copyPath")) { store.copyToPasteboard(node.isFolder ? String(node.id.dropLast()) : node.id) }
    }

    // MARK: Detail

    @ViewBuilder private func detail(files: [ChangedFile]) -> some View {
        if let file = store.selectedFile, files.contains(where: { $0.path == file.path }) || store.repository?.files.contains(where: { $0.path == file.path }) == true {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if file.kind == .renamed, let original = file.originalPath {
                            Text(String(format: L("movedFrom"), original)).font(.caption).foregroundStyle(.purple).lineLimit(1).truncationMode(.middle)
                        } else {
                            Text(file.directory.isEmpty ? L("repositoryRoot") : file.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    ChangeKindBadge(kind: file.kind)
                    if let stats = store.totalStats(file) { StatsBadge(stats: stats) }
                    Spacer()
                    let reviewed = store.isReviewed(file)
                    Button { stage(file, in: files) } label: { Label(L("stage"), systemImage: "plus.circle") }
                        .disabled(!(file.worktree != " " || file.index == "?") || store.busy).accessibilityIdentifier("review.stage")
                    Button { markAndAdvance(file, in: files) } label: { Label(reviewed ? L("reviewed") : L("reviewedNext"), systemImage: reviewed ? "checkmark.circle.fill" : "checkmark.circle") }
                        .buttonStyle(.borderedProminent).tint(reviewed ? .secondary : Brand.accent).keyboardShortcut(.return, modifiers: [.option])
                        .accessibilityIdentifier("review.markNext")
                }
                .padding(.horizontal, 14).frame(height: 52).background(.bar)
                Divider()
                if store.diff.isEmpty { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { DiffView(text: store.diff, path: store.selectedFile?.path, onHunk: store.busy ? nil : { store.stageHunk($0) }, hunkTitle: L(store.stagedSelection ? "hunkUnstage" : "hunkStage")) }
            }
        } else {
            ContentUnavailableView(L("reviewPick"), systemImage: "checklist", description: Text(L("reviewPickDetail"))).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Tree helpers

    private func visibleRows(_ nodes: [ChangeNode], depth: Int = 0) -> [(node: ChangeNode, depth: Int)] {
        var rows: [(node: ChangeNode, depth: Int)] = []
        for node in nodes {
            rows.append((node, depth))
            if let children = node.children, !collapsed.contains(node.id) { rows += visibleRows(children, depth: depth + 1) }
        }
        return rows
    }
    private func allFolderIDs(_ nodes: [ChangeNode]) -> [String] { nodes.flatMap { $0.isFolder ? [$0.id] + allFolderIDs($0.children ?? []) : [] } }
    /// Opens every collapsed ancestor folder of a file.
    private func reveal(_ path: String) { collapsed = collapsed.filter { !path.hasPrefix($0) } }

    // MARK: Actions

    private func markAndAdvance(_ file: ChangedFile, in files: [ChangedFile]) {
        let wasReviewed = store.isReviewed(file)
        store.setReviewed([file], !wasReviewed)
        if !wasReviewed { nextUnreviewed(in: files, after: file.path) }
    }
    private func stage(_ file: ChangedFile, in files: [ChangedFile]) {
        store.setReviewed([file], true)
        store.stageFiles([file], staged: false)
        nextUnreviewed(in: files, after: file.path)
    }
    private func nextUnreviewed(in files: [ChangedFile], after path: String? = nil) {
        let start = path.flatMap { current in files.firstIndex { $0.path == current } }.map { $0 + 1 } ?? 0
        let ordered = Array(files[min(start, files.count)...]) + Array(files[..<min(start, files.count)])
        guard let next = ordered.first(where: { !store.isReviewed($0) && $0.path != path }) else { return }
        reveal(next.path)
        selection = next.path
        treeFocused = true
    }
    private func toggleSelected(in files: [ChangedFile]) -> KeyPress.Result {
        guard let id = selection else { return .ignored }
        if let file = files.first(where: { $0.path == id }) { markAndAdvance(file, in: files) }
        else { let folder = files.filter { $0.path.hasPrefix(id) }; store.setReviewed(folder, !folder.allSatisfy(store.isReviewed)) }
        return .handled
    }
    private func stageSelected(in files: [ChangedFile]) -> KeyPress.Result {
        guard let id = selection else { return .ignored }
        if let file = files.first(where: { $0.path == id }) { stage(file, in: files) }
        else { store.stageFiles(files.filter { $0.path.hasPrefix(id) && ($0.worktree != " " || $0.index == "?") }, staged: false) }
        return .handled
    }
    private func discard(_ files: [ChangedFile]) async {
        guard let root = store.repository?.root else { return }
        for file in files { let _: String? = try? await store.engine.call(["method": "action", "path": root, "action": "discard", "value": file.path, "confirmed": true]) }
        store.notify(String(format: L("discardedCount"), files.count), icon: "arrow.uturn.backward.circle.fill")
        await store.refresh()
    }
}

private struct ReviewNodeRow: View {
    let store: WorkspaceStore
    let node: ChangeNode
    var depth = 0
    var collapsed = false
    var onToggle: () -> Void = {}
    var body: some View {
        let reviewedCount = node.files.filter(store.isReviewed).count
        let done = reviewedCount == node.files.count
        HStack(spacing: 7) {
            Group {
                if node.isFolder {
                    Button(action: onToggle) { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(collapsed ? 0 : 90)).foregroundStyle(.secondary) }
                        .buttonStyle(.borderless).accessibilityLabel(L(collapsed ? "expand" : "collapse"))
                } else { Color.clear }
            }.frame(width: 12)
            Button { store.setReviewed(node.files, !done) } label: {
                Image(systemName: done ? "checkmark.circle.fill" : reviewedCount > 0 ? "circle.lefthalf.filled" : "circle")
                    .foregroundStyle(done ? Brand.accent : .secondary).contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless).help(L(done ? "unmarkReviewed" : "markReviewed")).accessibilityLabel(L(done ? "unmarkReviewed" : "markReviewed"))
            if node.isFolder {
                Image(systemName: "folder.fill").foregroundStyle(.secondary).font(.system(size: 11))
                Text(node.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(reviewedCount)/\(node.files.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            } else if let file = node.file {
                ChangeKindBadge(kind: file.kind, compact: true).frame(width: 14)
                FileTypeIcon(path: file.path, size: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).foregroundStyle(done ? .secondary : .primary)
                        .strikethrough(file.kind == .deleted, color: .secondary)
                    if file.kind == .renamed, let original = file.originalPath {
                        Text(String(format: L("movedFrom"), original)).font(.system(size: 9)).foregroundStyle(.purple).lineLimit(1).truncationMode(.head)
                    }
                }
                if file.index != " " && file.index != "?" { Image(systemName: "tray.full.fill").font(.system(size: 9)).foregroundStyle(Brand.accent).help(L("staged")) }
                Spacer(minLength: 4)
            }
            if node.additions + node.deletions > 0 { StatsBadge(stats: LineStats(additions: node.additions, deletions: node.deletions)) }
        }
        .opacity(done && !node.isFolder ? 0.7 : 1)
        .padding(.leading, CGFloat(depth) * 16)
    }
}

private struct FilterChip: View {
    let title: String; let count: Int; let active: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) { Text(title).fontWeight(.medium); Text(count.formatted()).foregroundStyle(active ? .white.opacity(0.85) : .secondary) }
                .font(.system(size: 11)).padding(.horizontal, 9).padding(.vertical, 4)
                .foregroundStyle(active ? .white : .primary)
                .background(active ? Brand.accent : Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain).accessibilityLabel("\(title) \(count)").accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct KindChip: View {
    let kind: ChangeKind; let count: Int; let active: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) { Image(systemName: kind.icon).font(.system(size: 10)); Text(kind.plural).fontWeight(.medium); Text(count.formatted()).foregroundStyle(active ? .white.opacity(0.85) : .secondary) }
                .font(.system(size: 11)).padding(.horizontal, 9).padding(.vertical, 4)
                .foregroundStyle(active ? .white : kind.color)
                .background(active ? kind.color : kind.color.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain).accessibilityLabel("\(kind.plural) \(count)").accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("review.kind.\(kind.rawValue)")
    }
}
