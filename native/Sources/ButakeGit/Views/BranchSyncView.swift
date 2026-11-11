import SwiftUI

/// Side-by-side comparison of two branches by patch content, with one-click copying of what is missing.
/// Built for teams that work on main and develop at the same time and move commits between them.
struct BranchSyncView: View {
    @Bindable var store: WorkspaceStore
    @State private var left = ""
    @State private var right = ""
    @State private var result: BranchSyncResult?
    @State private var loading = false
    @State private var error = ""
    @State private var selectedLeft: Set<String> = []
    @State private var selectedRight: Set<String> = []
    @State private var showEquivalent = false
    /// Repository whose remote was already consulted in this visit (one fetch per repository, plus the refresh button).
    @State private var fetchedRoot: String?
    @State private var fetching = false
    @State private var offline = false
    /// Every branch that really exists: the local ones and the remote ones not brought to this Mac yet.
    private var branchNames: [String] { (store.repository?.branches.map(\.name) ?? []) + (store.repository?.remoteOnly.map(\.name) ?? []) }
    private var reloadKey: String { "\(left)|\(right)|\(store.repository?.branch ?? "")|\(store.repository?.commits.first?.hash ?? "")|\(store.files.count)|\(store.repository?.branches.hashValue ?? 0)|\(store.repository?.remoteBranches?.hashValue ?? 0)" }
    /// What a chosen name is compared as. A local branch that is only behind its remote is compared through the
    /// remote branch (the real state); `stale` describes that gap and `local` says whether commits can be copied to it.
    private struct Side { var ref: String; var local: Bool; var behind = 0; var ahead = 0; var upstream = "" }
    private func side(_ name: String) -> Side {
        guard let branch = store.repository?.branches.first(where: { $0.name == name }) else { return Side(ref: name, local: false) }
        let behind = branch.behind ?? 0, ahead = branch.ahead ?? 0
        guard !branch.upstream.isEmpty, branch.gone != true, behind > 0 else { return Side(ref: name, local: true) }
        return Side(ref: ahead == 0 ? branch.upstream : name, local: true, behind: behind, ahead: ahead, upstream: branch.upstream)
    }
    /// Why commits cannot be copied to `name` right now, if they cannot.
    private func copyBlock(_ name: String) -> String? {
        let target = side(name)
        if !target.local { return String(format: L("syncTargetRemoteOnly"), name) }
        if target.behind > 0 { return String(format: L("syncTargetStale"), name) }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let result {
                summary(result)
                Divider()
                if result.onlyLeft.isEmpty && result.onlyRight.isEmpty {
                    ContentUnavailableView(L("inSync"), systemImage: "checkmark.seal", description: Text(String(format: L("alreadyBoth")) + ": \(result.equivalentLeft.count)"))
                        .frame(maxHeight: .infinity).transition(.opacity)
                } else {
                    // Plain SwiftUI columns: an AppKit split view here took over the window's drawing.
                    HStack(spacing: 0) {
                        SyncColumn(store: store, source: left, target: right, commits: result.onlyLeft, selection: $selectedLeft, blocked: copyBlock(right))
                        Divider()
                        SyncColumn(store: store, source: right, target: left, commits: result.onlyRight, selection: $selectedRight, blocked: copyBlock(left))
                    }
                }
                equivalentSection(result)
            } else if loading || fetching {
                VStack(spacing: 10) { Spinner(size: 18); if fetching { Text(L("syncFetching")).font(.uiCaption).foregroundStyle(.secondary) } }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(L("syncTitle"), systemImage: "arrow.left.arrow.right.circle", description: Text(error.isEmpty ? L("syncExplain") : error)).frame(maxHeight: .infinity)
            }
        }
        .onAppear(perform: chooseDefaults)
        .onChange(of: branchNames) { _, _ in chooseDefaults() }
        .task(id: reloadKey) { await load() }
        .animation(.smooth(duration: 0.2), value: result)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(L("syncTitle")).font(.uiHeadline)
            Spacer()
            BranchPicker(selection: $left, names: branchNames, store: store).accessibilityIdentifier("sync.left")
            Button { swap(&left, &right); selectedLeft = []; selectedRight = [] } label: { Image(systemName: "arrow.left.arrow.right") }
                .help(L("swapBranches")).accessibilityLabel(L("swapBranches")).accessibilityIdentifier("sync.swap")
            BranchPicker(selection: $right, names: branchNames, store: store).accessibilityIdentifier("sync.right")
            if fetching { Spinner(size: 13).help(L("syncFetching")) }
            Button { fetchedRoot = nil; Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help(L("syncRefreshHelp")).accessibilityLabel(L("refresh")).accessibilityIdentifier("sync.refresh").disabled(loading || fetching)
        }
        .padding(.horizontal, 18).frame(height: 46).background(Brand.bar)
    }

    private func summary(_ result: BranchSyncResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StatCard(value: result.onlyLeft.count, title: String(format: L("onlyIn"), left), detail: String(format: L("missingIn"), right), color: Brand.info)
                StatCard(value: result.onlyRight.count, title: String(format: L("onlyIn"), right), detail: String(format: L("missingIn"), left), color: Brand.warning)
                StatCard(value: result.equivalentLeft.count, title: L("alreadyBoth"), detail: L("inBoth"), color: .secondary)
            }
            // No fixedSize here: a vertically fixed text next to the lists created a layout cycle
            // that stopped the whole window from drawing.
            Text(L("syncExplain") + " " + L("mergesExcluded")).font(.uiCaption).foregroundStyle(.secondary).lineLimit(3)
            if !store.files.isEmpty { Label(L("dirtyHint"), systemImage: "exclamationmark.circle").font(.uiCaption).foregroundStyle(Brand.warning) }
            // What is really being compared when a local branch is not up to date with its remote.
            ForEach([left, right], id: \.self) { name in
                let state = side(name)
                if state.behind > 0 {
                    Label(String(format: L(state.ahead == 0 ? "syncComparedWithRemote" : "syncDiverged"), name, state.behind, state.upstream), systemImage: "arrow.down.circle")
                        .font(.uiCaption).foregroundStyle(Brand.info).accessibilityIdentifier("sync.stale.\(name)")
                }
            }
            if offline { Label(L("syncOffline"), systemImage: "wifi.slash").font(.uiCaption).foregroundStyle(Brand.warning) }
        }.padding(16)
    }

    @ViewBuilder private func equivalentSection(_ result: BranchSyncResult) -> some View {
        if !result.equivalentLeft.isEmpty {
            Divider()
            DisclosureGroup(isExpanded: $showEquivalent) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(result.equivalentLeft) { commit in
                            let twin = result.equivalentRight.first { $0.subject == commit.subject }
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                                Text(commit.subject).font(.ui(size: 11)).lineLimit(1)
                                Spacer()
                                Text("\(left) \(commit.shortHash)").font(.ui(size: 10, design: .monospaced)).foregroundStyle(Brand.info)
                                if let twin { Text("≡ \(right) \(twin.shortHash)").font(.ui(size: 10, design: .monospaced)).foregroundStyle(Brand.warning) }
                            }.padding(.vertical, 2)
                        }
                    }.padding(.horizontal, 4)
                }.frame(maxHeight: 160)
            } label: {
                Label("\(L("alreadyBoth")) (\(result.equivalentLeft.count))", systemImage: "checkmark.circle").font(.uiCaption.weight(.semibold))
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private func chooseDefaults() {
        let names = branchNames
        guard !names.isEmpty else { return }
        if !names.contains(left) { left = store.repository?.branch ?? names[0] }
        if !names.contains(right) || right == left {
            // The repository's primary branch, or else the branch that moved most recently: nothing assumed by name.
            let primary = store.repository?.primary ?? ""
            let recent = (store.repository?.branches ?? []).filter { $0.name != left }.max { ($0.updated ?? 0) < ($1.updated ?? 0) }?.name
            right = [primary, recent ?? ""].first { !$0.isEmpty && $0 != left && names.contains($0) } ?? names.first { $0 != left } ?? left
        }
    }

    private func load() async {
        guard let root = store.repository?.root, !left.isEmpty, !right.isEmpty, left != right else { result = nil; return }
        // First the real state of the remote (once per repository, and again with the refresh button).
        if fetchedRoot != root, store.repository?.hasRemote == true, !store.busy, !store.terminalActive {
            fetchedRoot = root; fetching = true
            let fetched = (try? await store.engine.call(["method": "action", "path": root, "action": "fetch", "value": ""]) as String) != nil
            offline = !fetched
            if fetched { store.lastFetch = Date() }
            await store.refresh()
            fetching = false
        }
        loading = true; defer { loading = false }
        do {
            let value: BranchSyncResult = try await store.engine.call(["method": "branchSync", "path": root, "left": side(left).ref, "right": side(right).ref])
            result = value; error = ""
            selectedLeft.formIntersection(value.onlyLeft.map(\.hash)); selectedRight.formIntersection(value.onlyRight.map(\.hash))
        } catch { self.error = error.localizedDescription; result = nil }
    }
}

private struct BranchPicker: View {
    @Binding var selection: String
    let names: [String]
    let store: WorkspaceStore
    var body: some View {
        Picker("", selection: $selection) {
            let locals = Set(store.repository?.branches.map(\.name) ?? [])
            ForEach(names, id: \.self) { name in Label(name, systemImage: store.isProtected(name) ? "lock" : locals.contains(name) ? "arrow.triangle.branch" : "cloud").tag(name) }
        }.labelsHidden().fixedSize()
    }
}

private struct StatCard: View {
    let value: Int; let title: String; let detail: String; let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)").font(.ui(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(color).contentTransition(.numericText(value: Double(value)))
            Text(title).font(.ui(size: 11, weight: .semibold)).lineLimit(1)
            Text(detail).font(.uiCaption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.18)))
        .accessibilityElement(children: .combine)
    }
}

/// Commits that exist only in `source`, with selection and a copy action toward `target`.
private struct SyncColumn: View {
    let store: WorkspaceStore
    let source: String; let target: String
    let commits: [GitCommit]
    @Binding var selection: Set<String>
    /// Reason why nothing can be copied to `target` (it only exists on the remote, or its local copy is behind).
    var blocked: String? = nil
    var selected: [GitCommit] { commits.filter { selection.contains($0.hash) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(format: L("onlyIn"), source)).font(.ui(size: 12, weight: .semibold))
                    Text(String(format: L("missingIn"), target)).font(.uiCaption2).foregroundStyle(.secondary)
                }
                Spacer()
                if !commits.isEmpty {
                    Button(selection.count == commits.count ? L("selectNone") : L("selectAll")) {
                        selection = selection.count == commits.count ? [] : Set(commits.map(\.hash))
                    }.controlSize(.small).buttonStyle(.borderless).accessibilityIdentifier("sync.selectAll.\(source)")
                }
            }.padding(.horizontal, 14).frame(height: 44)
            Divider()
            if commits.isEmpty {
                ContentUnavailableView(L("nothingMissing"), systemImage: "checkmark.circle").frame(maxHeight: .infinity)
            } else {
                List(commits) { commit in
                    SyncRow(commit: commit, isOn: Binding(get: { selection.contains(commit.hash) }, set: { on in if on { selection.insert(commit.hash) } else { selection.remove(commit.hash) } }), onView: { store.showCommit(commit.hash, title: commit.subject) })
                        .contextMenu {
                            Button(L("viewCommit")) { store.showCommit(commit.hash, title: commit.subject) }
                            Button(L("copyHash")) { store.copyToPasteboard(commit.hash) }
                            Button(String(format: L("copyTo"), target)) { store.copyCommits([commit], to: target) }.disabled(store.isProtected(target) || store.busy || blocked != nil)
                        }
                        .accessibilityIdentifier("sync.commit.\(commit.shortHash)")
                        .accessibilityAction(named: L("viewCommit")) { store.showCommit(commit.hash, title: commit.subject) }
                }
                .listStyle(.inset).themedScroll()
            }
            Divider()
            VStack(spacing: 6) {
                Button { store.copyCommits(selected, to: target) } label: {
                    Label(String(format: L("copyN"), selected.count, target), systemImage: "arrow.right.doc.on.clipboard").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(selected.isEmpty || store.isProtected(target) || store.busy || store.terminalActive || !store.files.isEmpty || blocked != nil)
                .accessibilityIdentifier("sync.copyTo.\(target)")
                if let blocked { Text(blocked).font(.uiCaption2).foregroundStyle(Brand.warning).multilineTextAlignment(.center) }
                if store.isProtected(target) { Text(String(format: L("targetProtected"), target)).font(.uiCaption2).foregroundStyle(Brand.warning).multilineTextAlignment(.center) }
            }.padding(12)
        }
        .frame(minWidth: 280, maxWidth: .infinity)
    }
}

private struct SyncRow: View {
    let commit: GitCommit
    @Binding var isOn: Bool
    let onView: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isOn).toggleStyle(.checkbox).labelsHidden().accessibilityLabel(commit.subject)
            AuthorAvatar(name: commit.author, size: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(commit.subject).font(.ui(size: 12, weight: .medium)).lineLimit(1)
                Text("\(commit.author) · \(commit.date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))").font(.ui(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(commit.shortHash).font(.ui(size: 10, design: .monospaced)).foregroundStyle(Brand.accent)
            Button(action: onView) { Image(systemName: "eye") }.buttonStyle(.borderless).help(L("viewCommit")).accessibilityLabel(L("viewCommit"))
        }
        .padding(.vertical, 3).contentShape(Rectangle())
        .onTapGesture(count: 2) { onView() }
        .onTapGesture { isOn.toggle() }
    }
}
