import SwiftUI

private struct BranchRename: Identifiable { var name: String; var id: String { name } }
private struct BranchComparison: Identifiable { var id: String { file }; var file: String; var head: String; var base: String }
struct BranchesView: View {
    @Bindable var store: WorkspaceStore
    @State private var selected = ""
    @State private var base = "main"
    @State private var search = ""
    @State private var details: BranchDetails?
    @State private var loading = false
    @State private var error = ""
    @State private var tab = 0
    @State private var newBranch = false
    @State private var fileSelection: String?
    @State private var comparison: BranchComparison?
    @State private var renaming: BranchRename?
    @State private var generation = UUID()
    private var branches: [GitBranch] { store.repository?.branches ?? [] }
    private var localNames: Set<String> { Set(branches.map(\.name)) }
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack { Text(L("branches")).font(.uiHeadline); Spacer(); Button { newBranch = true } label: { Image(systemName: "plus") }.accessibilityIdentifier("branches.newBranch").accessibilityLabel(L("newBranch")).help(L("newBranch")).disabled(store.busy || store.terminalActive) }.padding(14)
                TextField(L("findBranch"), text: $search).accessibilityIdentifier("branches.findBranch").textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 12)
                List(branches.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }, selection: $selected) { branch in
                    Label { VStack(alignment: .leading, spacing: 4) { Text(branch.name).font(.ui(size: 12, weight: .medium)); Text(branch.current ? L("current") : branch.upstream.isEmpty ? L("localBranch") : branch.upstream).font(.uiCaption2).foregroundStyle(.secondary).lineLimit(1) } } icon: { Image(systemName: store.isProtected(branch.name) ? "lock.fill" : "arrow.triangle.branch").foregroundStyle(branch.current ? Brand.accent : .secondary) }.padding(.vertical, 5).tag(branch.name)
                }.listStyle(.inset).themedScroll()
            }.frame(minWidth: 180, idealWidth: 215, maxWidth: 280)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Label(selected.isEmpty ? L("branches") : selected, systemImage: "arrow.triangle.branch").font(.uiHeadline).lineLimit(1)
                    Spacer()
                    Picker(L("compareBase"), selection: $base) { ForEach(branches) { Text($0.name).tag($0.name) } }.accessibilityIdentifier("branches.compareBase").fixedSize()
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityIdentifier("branches.refresh").accessibilityLabel(L("refresh")).help(L("refresh")).disabled(loading)
                }.padding(16).background(Brand.bar)
                Divider()
                if loading { Spinner(size: 18).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if !error.isEmpty { ContentUnavailableView(L("operationFailed"), systemImage: "exclamationmark.triangle", description: Text(error)).frame(maxHeight: .infinity) }
                else if let details { branchContent(details) }
                else { ContentUnavailableView(L("branches"), systemImage: "arrow.triangle.branch", description: Text(L("selectBranch"))).frame(maxHeight: .infinity) }
            }.frame(minWidth: 390)
        }
        .onAppear { if selected.isEmpty { selected = store.repository?.branch ?? branches.first?.name ?? "" }; if base == selected || !branches.contains(where: { $0.name == base }) { base = preferredBase(for: selected) } }
        .onChange(of: selected) { _, name in if base == name { base = preferredBase(for: name) } }
        .onChange(of: branches.map(\.name)) { _, names in
            if !names.contains(selected) { selected = store.repository?.branch ?? names.first ?? "" }
            if !names.contains(base) { base = preferredBase(for: selected) }
        }
        .task(id: "\(store.repository?.root ?? "")|\(selected)|\(base)|\(store.repository?.commits.first?.hash ?? "")|\(store.status)") { await load() }
        .sheet(item: $renaming) { branch in RenameBranchSheet(store: store, original: branch.name).themedSheet() }
        .sheet(isPresented: $newBranch) { NewBranchSheet(store: store).themedSheet() }
        .sheet(item: $comparison, onDismiss: { fileSelection = nil }) { item in BranchDiffSheet(store: store, comparison: item).themedSheet() }
    }
    private func branchContent(_ value: BranchDetails) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ViewThatFits(in: .horizontal) { HStack(spacing: 10) { metrics(value) }; VStack(spacing: 10) { metrics(value) } }
                    if let creation = value.creation {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.clock").font(.uiTitle2).foregroundStyle(Brand.accent)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(L("createdBy")) \(creation.actor)").font(.ui(size: 12, weight: .semibold))
                                Text(Date(timeIntervalSince1970: creation.timestamp), format: .dateTime.day().month().year().hour().minute()).font(.uiCaption).foregroundStyle(.secondary)
                                Text(creation.event).font(.uiCaption2.monospaced()).foregroundStyle(.secondary)
                                Text(L("reflogEvidence")).font(.uiCaption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let latest = value.commits.first(where: { $0.hash == value.head }) {
                        HStack(alignment: .top) { Image(systemName: "clock").foregroundStyle(.secondary); VStack(alignment: .leading, spacing: 4) { Text(L("lastBranchCommit")).font(.uiCaption.weight(.semibold)); Text(latest.subject).font(.uiCaption).lineLimit(1); Text("\(latest.author) · \(latest.shortHash)").font(.uiCaption2).foregroundStyle(.secondary); Text(latest.date, format: .dateTime.day().month().year().hour().minute()).font(.uiCaption2).foregroundStyle(.secondary) } }
                    }
                    if !value.upstream.isEmpty { Label(value.upstream, systemImage: "network").font(.uiCaption).foregroundStyle(.secondary); if let tracking = value.tracking, tracking.count == 2 { Text("↑ \(tracking[0])  ↓ \(tracking[1]) · \(L("versusUpstream"))").font(.uiCaption.monospacedDigit()) } }
                    HStack {
                        if selected == store.repository?.branch { Label(L("currentBranch"), systemImage: "checkmark.circle.fill").font(.uiCaption.weight(.medium)).foregroundStyle(Brand.accent) }
                        else { Button(L("switch_branch")) { store.action("switch_branch", value: selected) }.buttonStyle(.borderedProminent).disabled(store.busy || store.terminalActive).accessibilityIdentifier("branches.switch") }
                        Menu(L("branchActions")) {
                            Button("\(L("merge")) \(selected) → \(store.repository?.branch ?? "HEAD")") { store.action("merge", value: selected, confirm: true) }.accessibilityIdentifier("branches.merge").disabled(selected == store.repository?.branch || !store.canWrite)
                            Button("\(L("rebase")) \(store.repository?.branch ?? "HEAD") → \(selected)") { store.action("rebase", value: selected, confirm: true) }.accessibilityIdentifier("branches.rebase").disabled(selected == store.repository?.branch || !store.canWrite)
                            Button(L("rename")) { renaming = BranchRename(name: selected) }.accessibilityIdentifier("branches.rename").disabled(store.isProtected(selected))
                            Button(L("delete"), role: .destructive) { store.deleteBranch(selected) }.accessibilityIdentifier("branches.delete").disabled(store.isProtected(selected) || selected == store.repository?.branch)
                        }.accessibilityIdentifier("branches.branchActions").fixedSize().disabled(store.busy || store.terminalActive)
                        Spacer()
                    }.controlSize(.small)
                    if !value.authors.isEmpty {
                        Text(L("branchContributors")).font(.uiCaption.weight(.semibold))
                        ForEach(value.authors.sorted { $0.count > $1.count }) { author in
                            HStack { Text(author.name).font(.uiCaption).frame(maxWidth: 200, alignment: .leading); ProgressView(value: Double(author.count), total: Double(max(value.ahead, 1))).tint(Brand.accent); Text("\(author.count)").font(.uiCaption.monospacedDigit()).frame(width: 36, alignment: .trailing) }
                        }
                    }
                }.padding(20)
            }.frame(maxHeight: 330)
            Divider()
            Picker(L("branchDisplay"), selection: $tab) { Text(L("branchGraph")).tag(0); Text("\(L("files")) (\(value.files.count))").tag(1) }.accessibilityIdentifier("branches.branchDisplay").pickerStyle(.segmented).labelsHidden().fixedSize().frame(maxWidth: .infinity, alignment: .leading).padding(12)
            if tab == 0 { graph(value) }
            else {
                Text(L(value.mergeBase == nil ? "tipComparison" : "ancestorComparison")).font(.uiCaption2).foregroundStyle(.secondary).padding(.horizontal)
                List(value.files, selection: $fileSelection) { file in
                    HStack { Image(systemName: "doc.text").foregroundStyle(.secondary); Text(file.path).font(.ui(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle); Spacer(); Text(file.additions.map { "+\($0)" } ?? L("binary")).foregroundStyle(Brand.accent); Text(file.deletions.map { "−\($0)" } ?? "").foregroundStyle(Brand.danger) }.font(.uiCaption.monospacedDigit()).padding(.vertical, 4).tag(file.path)
                }.listStyle(.inset).themedScroll().overlay { if value.files.isEmpty { ContentUnavailableView(L("noBranchChanges"), systemImage: "equal.circle") } }
                .onChange(of: fileSelection) { _, path in if let path { comparison = BranchComparison(file: path, head: value.head, base: value.mergeBase ?? value.baseHead) } }

            }
        }
    }
    @ViewBuilder private func metrics(_ d: BranchDetails) -> some View {
        BranchMetric(title: L("reachableCommits"), value: d.total, icon: "point.topleft.down.to.point.bottomright.curvepath")
        BranchMetric(title: "\(L("exclusiveCommits")) · \(d.base)", value: d.ahead, icon: "arrow.up.right")
        BranchMetric(title: "\(L("missingCommits")) · \(d.base)", value: d.behind, icon: "arrow.down.left")
    }
    private func graph(_ value: BranchDetails) -> some View {
        let graph = CommitGraph(commits: value.commits)
        return VStack(spacing: 0) {
            Text(L("branchGraphLimit")).font(.uiCaption2).foregroundStyle(.secondary).padding(.horizontal)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(value.commits.enumerated()), id: \.element.id) { index, commit in
                        Button { store.selectedCommit = commit; store.showInspector = true } label: {
                            HStack(spacing: 10) { CommitGraphCell(row: graph.rows[index]).frame(width: CGFloat(graph.width * 18 + 12), height: 54); VStack(alignment: .leading, spacing: 4) { Text(commit.subject).font(.ui(size: 12, weight: .medium)).lineLimit(1); HStack(spacing: 5) { ForEach(CommitReference.parse(commit.refs, localBranches: localNames).prefix(3)) { ReferenceChip(reference: $0) }; Text("\(commit.author) · \(commit.shortHash)").font(.uiCaption2).foregroundStyle(.secondary) } }; Spacer(); Text(RelativeDateCache.shared.text(for: commit.date)).font(.uiCaption2).foregroundStyle(.secondary).help(commit.date.formatted(date: .abbreviated, time: .shortened)) }.padding(.horizontal, 14).contentShape(Rectangle())
                        }.buttonStyle(.plain).background(store.selectedCommit?.hash == commit.hash ? Brand.accent.opacity(0.08) : .clear)
                        Divider()
                    }
                }
            }
        }
    }
    /// Comparing a branch with itself says nothing: prefer main, then develop, then any other branch.
    private func preferredBase(for branch: String) -> String {
        let names = branches.map(\.name)
        return ["main", "master", "develop"].first { names.contains($0) && $0 != branch } ?? names.first { $0 != branch } ?? branch
    }
    private func load() async {
        guard let root = store.repository?.root, !selected.isEmpty, !base.isEmpty else { return }
        let id = UUID(); generation = id; loading = true; error = ""
        do { let result: BranchDetails = try await store.engine.call(["method": "branchDetails", "path": root, "branch": selected, "base": base]); guard generation == id, !Task.isCancelled else { return }; details = result; loading = false }
        catch { guard generation == id, !Task.isCancelled else { return }; self.error = error.localizedDescription; loading = false }
    }
}
private struct BranchMetric: View {
    let title: String; let value: Int; let icon: String
    var body: some View { VStack(alignment: .leading, spacing: 9) { Label(title, systemImage: icon).font(.uiCaption2).foregroundStyle(.secondary).lineLimit(2); Text(value, format: .number).font(.ui(size: 27, weight: .semibold, design: .rounded)).monospacedDigit() }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10)) }
}
private struct BranchDiffSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: WorkspaceStore; let comparison: BranchComparison
    @State private var text = ""
    @State private var error = ""
    var body: some View { VStack(spacing: 0) { HStack { Text(comparison.file).font(.uiHeadline).lineLimit(1); Spacer(); Button(L("close")) { dismiss() }.accessibilityIdentifier("branches.close") }.padding(); Divider(); if !error.isEmpty { Text(error).foregroundStyle(Brand.danger).padding() } else { DiffView(text: text, path: comparison.file) } }.frame(width: 850, height: 600).task { guard let root = store.repository?.root else { return }; do { text = try await store.engine.call(["method": "branchDiff", "path": root, "head": comparison.head, "base": comparison.base, "file": comparison.file]) } catch { self.error = error.localizedDescription } } }
}

struct RenameBranchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: WorkspaceStore; let original: String
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("renameBranch")).font(.uiTitle2.weight(.semibold))
            Text(original).font(.uiCaption.monospaced()).foregroundStyle(.secondary)
            TextField(L("branchName"), text: $name).accessibilityIdentifier("branches.branchName").textFieldStyle(.roundedBorder)
            HStack { Spacer(); Button(L("cancel"), role: .cancel) { dismiss() }.accessibilityIdentifier("branches.cancel"); Button(L("rename")) { let renamed = name.trimmingCharacters(in: .whitespacesAndNewlines); dismiss(); store.renameBranch(original, to: renamed) }.accessibilityIdentifier("branches.rename").buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == original).keyboardShortcut(.defaultAction) }
        }.padding(26).frame(width: 440).onAppear { name = original }
    }
}
