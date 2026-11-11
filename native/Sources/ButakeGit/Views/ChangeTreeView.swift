import SwiftUI

/// Changes as a folder tree. Same files and same staging as the list: each checkbox is "in the commit".
/// A folder's checkbox stages or unstages everything inside it.
struct ChangeTreePane: View {
    let store: WorkspaceStore
    let onResolve: (ChangedFile) -> Void
    @State private var collapsed: Set<String> = []
    /// Checkbox clicks show at once; Git confirms and the next tree replaces these overrides.
    @State private var optimistic: [String: Bool] = [:]
    @FocusState private var focused: Bool

    private struct Row: Identifiable { let node: ChangeNode; let depth: Int; var id: String { node.id } }

    var body: some View {
        let tree = store.changeTree
        let rows = flatten(tree.nodes, depth: 0)
        let files = tree.files
        let staged = { (file: ChangedFile) in optimistic[file.path] ?? Self.hasStaged(file) }
        let stagedCount = files.filter(staged).count
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TreeCheckbox(state: state(of: files)) { toggle(files) }
                    .disabled(files.isEmpty || store.busy || store.terminalActive)
                    .accessibilityLabel(L(state(of: files) == .all ? "unstageAll" : "stageAll"))
                Text(L("filesInCommit")).font(.system(size: 11, weight: .semibold))
                Text("\(stagedCount)/\(files.count)").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary.opacity(0.7), in: Capsule())
                Spacer(minLength: 0)
                Menu {
                    Button(L("expandAll")) { withAnimation(.snappy) { collapsed = [] } }
                    Button(L("collapseAll")) { withAnimation(.snappy) { collapsed = Set(rows.filter(\.node.isFolder).map(\.id)) } }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel(L("more"))
            }
            .padding(.horizontal, 13).frame(height: 35).background(.bar)
            Divider()
            if files.isEmpty && !store.files.isEmpty {
                Spinner(size: 14).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                VStack(spacing: 5) { Image(systemName: "checkmark").font(.system(size: 17, weight: .light)).foregroundStyle(.tertiary); Text(L("noUnstaged")).font(.caption2).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                TreeRow(store: store, node: row.node, state: state(of: row.node.files), stagedCount: row.node.files.filter(staged).count, depth: row.depth, collapsed: collapsed.contains(row.id),
                                        selected: !row.node.isFolder && store.selectedFile?.path == row.node.file?.path,
                                        onToggleFolder: { withAnimation(.snappy(duration: 0.2)) { if collapsed.contains(row.id) { collapsed.remove(row.id) } else { collapsed.insert(row.id) } } },
                                        onCheck: { row.node.file?.conflict == true ? onResolve(row.node.file!) : toggle(row.node.files) },
                                        onSelect: { if let file = row.node.file { select(file) } })
                                .id(row.id)
                            }
                        }.padding(.vertical, 4)
                    }
                    .focusable().focused($focused).focusEffectDisabled()
                    .onKeyPress(.downArrow) { move(1, rows: rows, proxy: proxy) }
                    .onKeyPress(.upArrow) { move(-1, rows: rows, proxy: proxy) }
                    .onKeyPress(.space) {
                        guard let file = store.selectedFile, files.contains(where: { $0.path == file.path }), !file.conflict, !store.busy else { return .ignored }
                        toggle([file]); return .handled
                    }
                }
            }
        }
        .background(Brand.surface)
        .onChange(of: tree.revision) { _, _ in
            // Drop overrides once Git agrees; a failed stage clears its leftovers shortly after.
            guard !optimistic.isEmpty else { return }
            optimistic = optimistic.filter { path, inCommit in
                guard let file = tree.files.first(where: { $0.path == path }) else { return false }
                return (inCommit ? Self.hasStaged(file) && !Self.hasUnstaged(file) : !Self.hasStaged(file)) == false
            }
        }
        .task(id: optimistic.isEmpty) { if !optimistic.isEmpty { try? await Task.sleep(for: .seconds(3)); optimistic = [:] } }
        .onAppear { store.refreshChangeTree() }
        #if DEBUG || BUTAKE_QA
        // QA: presses the checkbox of a folder or file by its path, through the same toggle as a click.
        .onReceive(NotificationCenter.default.publisher(for: .init("butake.qa.treeToggle"))) { note in
            guard let id = note.object as? String, let node = rows.first(where: { $0.id == id })?.node else { return }
            toggle(node.files)
        }
        #endif
    }

    // MARK: Staging

    enum CheckState { case none, some, all }
    static func hasStaged(_ file: ChangedFile) -> Bool { file.index != " " && file.index != "?" }
    static func hasUnstaged(_ file: ChangedFile) -> Bool { file.worktree != " " || file.index == "?" }
    /// Fully in the commit / partly / not at all, counting pending clicks.
    private func state(of files: [ChangedFile]) -> CheckState {
        let candidates = files.filter { !$0.conflict }
        guard !candidates.isEmpty else { return .none }
        func full(_ file: ChangedFile) -> Bool { optimistic[file.path] ?? (Self.hasStaged(file) && !Self.hasUnstaged(file)) }
        func any(_ file: ChangedFile) -> Bool { optimistic[file.path] ?? Self.hasStaged(file) }
        if candidates.allSatisfy(full) { return .all }
        return candidates.contains(where: any) ? .some : .none
    }
    /// Everything in the commit → take it out; otherwise put the rest in.
    private func toggle(_ files: [ChangedFile]) {
        let candidates = files.filter { !$0.conflict }
        guard !candidates.isEmpty, !store.busy, !store.terminalActive else { return }
        let removing = state(of: candidates) == .all
        for file in candidates { optimistic[file.path] = !removing }
        if removing { store.stageFiles(candidates.filter(Self.hasStaged), staged: true) }
        else { store.stageFiles(candidates.filter(Self.hasUnstaged), staged: false) }
    }
    private func select(_ file: ChangedFile) {
        // Show what is still outside the commit first; a fully staged file shows its staged diff.
        store.selectFile(file, staged: !Self.hasUnstaged(file))
        focused = true
    }
    private func move(_ offset: Int, rows: [Row], proxy: ScrollViewProxy) -> KeyPress.Result {
        let fileRows = rows.compactMap(\.node.file)
        guard !fileRows.isEmpty else { return .ignored }
        let current = fileRows.firstIndex { $0.path == store.selectedFile?.path } ?? (offset > 0 ? -1 : fileRows.count)
        let next = fileRows[min(max(current + offset, 0), fileRows.count - 1)]
        select(next)
        withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo(next.path) }
        return .handled
    }
    private func flatten(_ nodes: [ChangeNode], depth: Int) -> [Row] {
        var result: [Row] = []
        for node in nodes {
            result.append(Row(node: node, depth: depth))
            if let children = node.children, !collapsed.contains(node.id) { result += flatten(children, depth: depth + 1) }
        }
        return result
    }
}

/// Square checkbox with a mixed state (some files of a folder in the commit).
private struct TreeCheckbox: View {
    let state: ChangeTreePane.CheckState
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: state == .all ? "checkmark.square.fill" : state == .some ? "minus.square.fill" : "square")
                .font(.system(size: 14))
                .foregroundStyle(state == .none ? Color.secondary : Brand.accent)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
    }
}

private struct TreeRow: View {
    let store: WorkspaceStore
    let node: ChangeNode
    let state: ChangeTreePane.CheckState
    let stagedCount: Int
    let depth: Int
    let collapsed: Bool
    let selected: Bool
    let onToggleFolder: () -> Void
    let onCheck: () -> Void
    let onSelect: () -> Void
    var body: some View {
        HStack(spacing: 7) {
            Group {
                if node.isFolder {
                    Button(action: onToggleFolder) { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(collapsed ? 0 : 90)).foregroundStyle(.secondary) }
                        .buttonStyle(.borderless).accessibilityLabel(L(collapsed ? "expand" : "collapse"))
                } else { Color.clear }
            }.frame(width: 12)
            if let file = node.file, file.conflict {
                Button(action: onCheck) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.warning) }.buttonStyle(.borderless).help(L("resolveConflict"))
            } else {
                TreeCheckbox(state: state, action: onCheck)
                    .disabled(store.busy || store.terminalActive)
                    .accessibilityLabel(L(state == .all ? "unstage" : "stage"))
            }
            if node.isFolder {
                Image(systemName: collapsed ? "folder.fill" : "folder").foregroundStyle(.secondary).font(.system(size: 11))
                Text(node.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(stagedCount)/\(node.files.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            } else if let file = node.file {
                FileTypeIcon(path: file.path, size: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                        .strikethrough(file.kind == .deleted, color: .secondary)
                    if file.kind == .renamed, let original = file.originalPath {
                        Text(String(format: L("movedFrom"), original)).font(.system(size: 9)).foregroundStyle(Brand.special).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                ChangeKindBadge(kind: file.kind, compact: true)
            }
            if node.additions + node.deletions > 0 { StatsBadge(stats: LineStats(additions: node.additions, deletions: node.deletions)) }
        }
        .padding(.leading, CGFloat(depth) * 16 + 10).padding(.trailing, 12).frame(height: 30)
        .background { if selected { RoundedRectangle(cornerRadius: 6).fill(Brand.accent.opacity(0.14)).padding(.horizontal, 6) } }
        .contentShape(Rectangle())
        .onTapGesture { if node.isFolder { onToggleFolder() } else { onSelect() } }
        .onTapGesture(count: 2) { if !node.isFolder { onCheck() } }
        .contextMenu { if let file = node.file { FileMenu(store: store, file: file) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("tree.\(node.id)")
    }
}

private struct FileMenu: View {
    let store: WorkspaceStore
    let file: ChangedFile
    var body: some View {
        if ChangeTreePane.hasUnstaged(file) && !file.conflict { Button(L("discardChanges"), role: .destructive) { store.discard(file) } }
        Button(L("copyPath")) { store.copyToPasteboard(file.path) }
        Button(L("openFinder")) { if let root = store.repository?.root { NSWorkspace.shared.selectFile(URL(fileURLWithPath: root).appendingPathComponent(file.path).path, inFileViewerRootedAtPath: root) } }
        Button(L("fileHistory")) { store.showDiff(file.path, subtitle: L("fileHistory"), args: ["log", "--follow", "--patch", "--no-ext-diff", "--no-color", "-n", "30", "--format=%x01%h %s · %an", "--", file.path]) }
    }
}
