import SwiftUI

struct ChangesView: View {
    @Bindable var store: WorkspaceStore
    @State private var amend = false
    @State private var editing: FileEditorTarget?
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if !store.changes.conflicts.isEmpty, case let conflicts = store.changes.conflicts { ConflictsPane(store: store, files: conflicts).transition(.move(edge: .top).combined(with: .opacity)); Divider() }
                // Same files and same staging, shown as two lists or as a folder tree (selector above).
                if store.route == .review {
                    ChangeTreePane(store: store, onResolve: { store.resolving = $0 }).frame(maxHeight: .infinity)
                } else {
                    VSplitView {
                        FileGroupPane(store: store, title: L("unstaged"), files: store.filteredChanges(staged: false), staged: false, onResolve: { store.resolving = $0 })
                            .frame(minHeight: 105, idealHeight: 260)
                        FileGroupPane(store: store, title: L("staged"), files: store.filteredChanges(staged: true), staged: true, onResolve: { store.resolving = $0 })
                            .frame(minHeight: 100, idealHeight: 170)
                    }.frame(maxHeight: .infinity)
                }
                Divider()
                CommitComposer(store: store, amend: $amend, onCommit: createCommit)
            }.frame(minWidth: 260, idealWidth: 320, maxWidth: 440)
            VStack(spacing: 0) {
                HStack { Label(store.selectedFile?.path ?? L("diff"), systemImage: "doc.text").font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle).contentTransition(.opacity); Spacer(); if let file = store.selectedFile, let stats = store.stats(for: file, staged: store.stagedSelection) { StatsBadge(stats: stats) }; if let file = store.selectedFile, !file.conflict { Button { editing = FileEditorTarget(path: file.path) } label: { Label(L("editFile"), systemImage: "pencil") }.controlSize(.small).disabled(!store.canWrite) }; if store.selectedFile != nil { Text(L(store.stagedSelection ? "staged" : "unstaged")).font(.caption2).foregroundStyle(.secondary) } }.padding(.horizontal, 16).frame(height: 39).background(.bar)
                Divider()
                if store.selectedFile != nil && store.diff.isEmpty { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity).transition(.opacity) }
                else if store.selectedFile != nil { DiffView(text: store.diff, path: store.selectedFile?.path, onHunk: store.busy || store.terminalActive ? nil : { store.stageHunk($0) }, hunkTitle: L(store.stagedSelection ? "hunkUnstage" : "hunkStage")) }
                else { ContentUnavailableView(L(store.files.isEmpty == true ? "clean" : "diff"), systemImage: store.files.isEmpty == true ? "checkmark.circle" : "doc.text.magnifyingglass", description: Text(L(store.files.isEmpty == true ? "cleanDetail" : "chooseFile"))).frame(maxHeight: .infinity) }
            }.frame(minWidth: 310).animation(.easeOut(duration: 0.15), value: store.diff.isEmpty)
        }.sheet(item: $editing) { target in FileEditorView(store: store, path: target.path) }
    }
    private func createCommit() {
        if amend { Task { await store.prepare("commit", arguments: "--amend -m \(shellQuote(store.message))") } }
        else { store.action("commit", value: store.message) }
    }
}
private struct FileGroupPane: View {
    let store: WorkspaceStore; let title: String; let files: [ChangedFile]; let staged: Bool; let onResolve: (ChangedFile) -> Void
    /// SwiftUI's List walks every element on each update; with thousands of files (an agent's burst) each refresh
    /// cost ~70 ms. The list shows the first rows and the rest on request; search and "stage all" still cover all.
    static let window = 150
    @State private var showAll = false
    var visible: [ChangedFile] { showAll || files.count <= Self.window ? files : Array(files.prefix(Self.window)) }
    var selection: Binding<String?> { Binding(get: { store.stagedSelection == staged ? store.selectedFile?.path : nil }, set: { path in if let file = files.first(where: { $0.path == path }) { store.selectFile(file, staged: staged) } }) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: staged ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(staged ? Brand.accent : Color.secondary).symbolEffect(.bounce, value: files.count < WorkspaceStore.animationLimit ? files.count : 0)
                Text(title).font(.system(size: 11, weight: .semibold))
                Text("\(files.count)").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary.opacity(0.7), in: Capsule()).countTransition(files.count)
                Spacer(minLength: 0)
                if !files.isEmpty { GroupTotals(store: store, files: files, staged: staged).transition(.opacity) }
                Button { store.stageFiles(files, staged: staged) } label: { Image(systemName: staged ? "minus" : "plus") }.buttonStyle(.borderless).frame(width: 22, height: 22).help(L(staged ? "unstageAll" : "stageAll")).accessibilityLabel(L(staged ? "unstageAll" : "stageAll")).accessibilityIdentifier(staged ? "changes.unstageAll" : "changes.stageAll").disabled(files.isEmpty || store.busy || store.terminalActive)
            }.padding(.horizontal, 13).frame(height: 35).background(.bar).animation(files.count < WorkspaceStore.animationLimit ? .snappy : nil, value: files.count)
            Divider()
            if files.isEmpty { VStack(spacing: 5) { Image(systemName: staged ? "tray" : "checkmark").font(.system(size: 17, weight: .light)).foregroundStyle(.tertiary); Text(L(staged ? "noStaged" : "noUnstaged")).font(.caption2).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity).transition(.opacity.combined(with: .scale(scale: 0.96))) }
            else {
                List(selection: selection) {
                    ForEach(visible) { file in
                        FileRow(store: store, file: file, staged: staged)
                            .tag(file.path)
                            .accessibilityIdentifier("file.\(staged ? "staged" : "unstaged").\(file.path)")
                    }
                    if visible.count < files.count {
                        Button { showAll = true } label: {
                            Label(String(format: L("showRemainingFiles"), files.count - visible.count), systemImage: "chevron.down.circle")
                                .font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderless).padding(.vertical, 6).selectionDisabled()
                        .accessibilityIdentifier(staged ? "changes.showAllStaged" : "changes.showAllUnstaged")
                    }
                }
                .contextMenu(forSelectionType: String.self) { paths in
                    if let file = files.first(where: { paths.contains($0.path) }) {
                        if file.conflict { Button(L("resolveConflict")) { onResolve(file) } }
                        Button(L(staged ? "unstage" : "stage")) { store.action(staged ? "unstage" : "stage", value: file.path) }
                        if !staged && !file.conflict { Button(L("discardChanges"), role: .destructive) { store.discard(file) } }
                        Divider()
                        Button(L("copyPath")) { store.copyToPasteboard(file.path) }
                        Button(L("openFinder")) { if let root = store.repository?.root { NSWorkspace.shared.selectFile(URL(fileURLWithPath: root).appendingPathComponent(file.path).path, inFileViewerRootedAtPath: root) } }
                        Button(L("inspectConsole")) { store.inspect("diff", arguments: "\(staged ? "--cached " : "")-- \(shellQuote(file.path))") }
                        Button(L("fileHistory")) { store.showDiff(file.path, subtitle: L("fileHistory"), args: ["log", "--follow", "--patch", "--no-ext-diff", "--no-color", "-n", "30", "--format=%x01%h %s · %an", "--", file.path]) }
                    }
                } primaryAction: { paths in
                    // Double-click moves the file between panels.
                    if let file = files.first(where: { paths.contains($0.path) }), !file.conflict { store.action(staged ? "unstage" : "stage", value: file.path) }
                    else if let file = files.first(where: { paths.contains($0.path) }) { onResolve(file) }
                }
                .onKeyPress(.space) {
                    guard store.stagedSelection == staged, let file = store.selectedFile, files.contains(file), !file.conflict, !store.busy else { return .ignored }
                    store.action(staged ? "unstage" : "stage", value: file.path); return .handled
                }
                .listStyle(.inset).scrollIndicators(.automatic).scrollBounceBehavior(.basedOnSize)
                // A file chosen elsewhere (search, Review, notch) beyond the first rows expands the list.
                .onChange(of: store.selectedFile?.path) { _, path in
                    if !showAll, store.stagedSelection == staged, let path, files.count > Self.window, !visible.contains(where: { $0.path == path }), files.contains(where: { $0.path == path }) { showAll = true }
                }
                .transition(.opacity)
            }
        }.background(.background).animation(.smooth(duration: 0.25), value: files.isEmpty)
    }
}
/// Group line totals in their own view: reading every file's stats in the pane body re-evaluated the whole
/// List (and diffed thousands of rows) each time stats reloaded during an agent's burst of writes.
private struct GroupTotals: View {
    let store: WorkspaceStore; let files: [ChangedFile]; let staged: Bool
    var body: some View {
        var additions = 0, deletions = 0
        for file in files { if let stats = store.stats(for: file, staged: staged) { additions += stats.additions ?? 0; deletions += stats.deletions ?? 0 } }
        return StatsBadge(stats: LineStats(additions: additions, deletions: deletions))
    }
}
private struct FileRow: View {
    let store: WorkspaceStore; let file: ChangedFile; let staged: Bool
    @State private var hovering = false
    var code: String { let code = staged ? file.index : file.worktree; return code == "?" ? "A" : code }
    var color: Color { file.kind.color }
    var body: some View {
        HStack(spacing: 8) {
            Group { if file.conflict { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 12)) } else { FileTypeIcon(path: file.path, size: 15) } }.frame(width: 16)
            VStack(alignment: .leading, spacing: 3) { Text(file.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle).strikethrough(code == "D", color: .secondary); if file.kind == .renamed, let original = file.originalPath { Text(String(format: L("movedFrom"), original)).font(.system(size: 9)).foregroundStyle(.purple).lineLimit(1).truncationMode(.head) } else if !file.directory.isEmpty { Text(file.directory).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) } }
            Spacer(minLength: 3)
            if let stats = store.statBox(file, staged: staged).value, !hovering { StatsBadge(stats: stats).transition(.opacity) }
            else if file.index == "?" && !hovering { Text(L("newFile")).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary) }
            if hovering && !staged && !file.conflict {
                Button { store.discard(file) } label: { Image(systemName: "arrow.uturn.backward.circle").font(.system(size: 13)) }.buttonStyle(.borderless).foregroundStyle(.secondary).help(L("discardChanges")).disabled(store.busy || store.terminalActive)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            Text(code).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(color).frame(width: 16, height: 16).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4)).help(file.kind.title)
            Button { store.action(staged ? "unstage" : "stage", value: file.path) } label: { Image(systemName: staged ? "minus.circle.fill" : "plus.circle.fill").font(.system(size: 14)).symbolRenderingMode(.hierarchical) }.buttonStyle(.borderless).foregroundStyle(hovering ? (staged ? Color.orange : Brand.accent) : Color.secondary).scaleEffect(hovering ? 1.1 : 1).help(L(staged ? "unstage" : "stage")).disabled(store.busy || store.terminalActive || file.conflict)
        }
        .padding(.vertical, 3).contentShape(Rectangle())
        .onHover { hover in withAnimation(.easeOut(duration: 0.14)) { hovering = hover } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(file.path)
        .accessibilityValue(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { store.selectFile(file, staged: staged) }
        .accessibilityAction(named: L(staged ? "unstage" : "stage")) { if !file.conflict { store.action(staged ? "unstage" : "stage", value: file.path) } }
        .accessibilityAction(named: L("discardChanges")) { if !staged && !file.conflict { store.discard(file) } }
        .accessibilityAction(named: L("copyPath")) { store.copyToPasteboard(file.path) }
    }
    private var accessibilitySummary: String {
        var parts = [L(staged ? "staged" : "unstaged"), file.kind.title]
        if file.conflict { parts.append(L("conflict")) }
        if let stats = store.statBox(file, staged: staged).value, !stats.binary { parts.append("+\(stats.additions ?? 0) −\(stats.deletions ?? 0)") }
        return parts.joined(separator: ", ")
    }
}
private struct CommitComposer: View {
    @Bindable var store: WorkspaceStore
    @Binding var amend: Bool
    let onCommit: () -> Void
    @FocusState private var focused: Bool
    var subject: String { store.message.components(separatedBy: "\n").first ?? "" }
    var stagedCount: Int { store.changes.staged.count }
    var canCommit: Bool { store.canWrite && !store.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (stagedCount > 0 || amend) }
    var blockedReason: String? {
        if !store.canWrite { return nil }
        if stagedCount == 0 && !amend { return L(store.files.isEmpty ? "commitNothing" : "commitNeedsStage") }
        if store.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L("commitNeedsMessage") }
        return nil
    }
    var currentType: String? { CommitType.all.first { subject.hasPrefix($0.prefix + ":") || subject.hasPrefix($0.prefix + "(") }?.prefix }
    func applyType(_ prefix: String) {
        var lines = store.message.components(separatedBy: "\n")
        var first = lines.first ?? ""
        if let existing = currentType { first.removeFirst(existing.count) } else { first = ": " + first }
        lines[0] = prefix + first
        store.message = lines.joined(separator: "\n"); focused = true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("commit")).font(.headline)
                Spacer()
                Menu {
                    ForEach(CommitType.all, id: \.prefix) { type in
                        Button { applyType(type.prefix) } label: { Label("\(type.prefix) · \(L("ctype_" + type.prefix))", systemImage: type.icon) }
                    }
                } label: { Label(currentType ?? L("commitType"), systemImage: "tag").font(.system(size: 10.5, weight: .medium)) }
                .menuStyle(.borderlessButton).fixedSize().help(L("commitTypeHelp")).accessibilityIdentifier("commit.type")
                Text("\(subject.count)/72").font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(subject.count > 72 ? Color.orange : subject.count > 50 ? Color.secondary : Color.secondary.opacity(0.6)).contentTransition(.numericText()).help(L("subjectLengthHelp"))
            }
            ZStack(alignment: .topLeading) {
                if store.message.isEmpty { Text(L("messagePlaceholder")).font(.system(size: 12)).foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false) }
                TextEditor(text: $store.message).font(.system(size: 12)).scrollContentBackground(.hidden).focused($focused).padding(6).accessibilityLabel(L("message")).accessibilityIdentifier("commit.message")
            }
            .frame(height: 82)
            .background(.quaternary.opacity(focused ? 0.25 : 0.45), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Brand.accent.opacity(0.7) : Color.secondary.opacity(0.2), lineWidth: focused ? 1.5 : 1))
            .animation(.easeOut(duration: 0.15), value: focused)
            if subject.count > 72 { Label(L("subjectTooLong"), systemImage: "exclamationmark.circle").font(.caption2).foregroundStyle(.orange).transition(.opacity.combined(with: .move(edge: .top))) }
            HStack {
                Toggle(L("amend"), isOn: $amend).font(.caption).controlSize(.small).accessibilityIdentifier("commit.amend")
                    .help(L("amendHelp"))
                    .onChange(of: amend) { _, on in
                        if on, store.message.isEmpty, let head = store.repository?.headHash, let last = store.repository?.commits.first(where: { $0.hash == head }) { store.message = last.subject }
                    }
                Spacer(); Text("⌘↩").font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            if let reason = blockedReason { Label(reason, systemImage: "info.circle").font(.caption2).foregroundStyle(.secondary).transition(.opacity) }
            Button(action: onCommit) {
                HStack(spacing: 6) {
                    Image(systemName: amend ? "arrow.triangle.2.circlepath" : "checkmark").contentTransition(.symbolEffect(.replace))
                    Text(amend ? L("amendCommit") : stagedCount > 0 ? "\(L("commit")) · \(stagedCount)" : L("commit")).contentTransition(.numericText(value: Double(stagedCount)))
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(!canCommit).keyboardShortcut(.return, modifiers: [.command]).accessibilityIdentifier("commit.submit")
            .help(stagedCount == 0 ? L("noStaged") : L("commitHelp"))
        }
        .padding(16)
        .animation(.snappy, value: stagedCount).animation(.snappy, value: amend).animation(.smooth, value: subject.count > 72)
    }
}
/// Conflicted files get their own section: they belong to neither panel until resolved.
private struct ConflictsPane: View {
    let store: WorkspaceStore; let files: [ChangedFile]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).symbolEffect(.pulse)
                Text(L("conflicts")).font(.system(size: 11, weight: .semibold))
                Text("\(files.count)").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.orange).padding(.horizontal, 6).padding(.vertical, 2).background(.orange.opacity(0.15), in: Capsule())
                Spacer()
                Button(L("resolveNow")) { store.resolveNextConflict() }.controlSize(.small).buttonStyle(.borderedProminent).tint(.orange).accessibilityIdentifier("conflicts.resolveNext")
            }
            ForEach(files) { file in
                Button { store.resolving = file } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.merge").foregroundStyle(.orange).frame(width: 15)
                        VStack(alignment: .leading, spacing: 1) { Text(file.name).font(.system(size: 11, weight: .medium)).lineLimit(1); if file.kind == .renamed, let original = file.originalPath { Text(String(format: L("movedFrom"), original)).font(.system(size: 9)).foregroundStyle(.purple).lineLimit(1).truncationMode(.head) } else if !file.directory.isEmpty { Text(file.directory).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) } }
                        Spacer()
                        Text(L("resolveConflict")).font(.system(size: 10)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    }.padding(.vertical, 4).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(L("resolveConflict")) \(file.path)").accessibilityIdentifier("conflict.\(file.path)")
            }
        }.padding(12).background(.orange.opacity(0.07))
    }
}
func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }


/// Conventional commit types offered by the composer.
struct CommitType { let prefix: String; let icon: String
    static let all = [CommitType(prefix: "feat", icon: "sparkles"), CommitType(prefix: "fix", icon: "wrench.and.screwdriver"), CommitType(prefix: "refactor", icon: "arrow.triangle.2.circlepath"), CommitType(prefix: "perf", icon: "gauge.with.dots.needle.67percent"), CommitType(prefix: "docs", icon: "doc.text"), CommitType(prefix: "test", icon: "checkmark.seal"), CommitType(prefix: "style", icon: "paintbrush"), CommitType(prefix: "chore", icon: "shippingbox")]
}
