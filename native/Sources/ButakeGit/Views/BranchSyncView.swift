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
    private var branchNames: [String] { store.repository?.branches.map(\.name) ?? [] }
    private var reloadKey: String { "\(left)|\(right)|\(store.repository?.branch ?? "")|\(store.repository?.commits.first?.hash ?? "")|\(store.files.count)" }

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
                        SyncColumn(store: store, source: result.left, target: result.right, commits: result.onlyLeft, selection: $selectedLeft)
                        Divider()
                        SyncColumn(store: store, source: result.right, target: result.left, commits: result.onlyRight, selection: $selectedRight)
                    }
                }
                equivalentSection(result)
            } else if loading {
                Spinner(size: 18).frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Text(L("syncTitle")).font(.headline)
            Spacer()
            BranchPicker(selection: $left, names: branchNames, store: store).accessibilityIdentifier("sync.left")
            Button { swap(&left, &right); selectedLeft = []; selectedRight = [] } label: { Image(systemName: "arrow.left.arrow.right") }
                .help(L("swapBranches")).accessibilityLabel(L("swapBranches")).accessibilityIdentifier("sync.swap")
            BranchPicker(selection: $right, names: branchNames, store: store).accessibilityIdentifier("sync.right")
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help(L("refresh")).accessibilityLabel(L("refresh")).disabled(loading)
        }
        .padding(.horizontal, 18).frame(height: 46).background(.bar)
    }

    private func summary(_ result: BranchSyncResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StatCard(value: result.onlyLeft.count, title: String(format: L("onlyIn"), result.left), detail: String(format: L("missingIn"), result.right), color: .blue)
                StatCard(value: result.onlyRight.count, title: String(format: L("onlyIn"), result.right), detail: String(format: L("missingIn"), result.left), color: .orange)
                StatCard(value: result.equivalentLeft.count, title: L("alreadyBoth"), detail: L("inBoth"), color: .secondary)
            }
            // No fixedSize here: a vertically fixed text next to the lists created a layout cycle
            // that stopped the whole window from drawing.
            Text(L("syncExplain") + " " + L("mergesExcluded")).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            if !store.files.isEmpty { Label(L("dirtyHint"), systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
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
                                Text(commit.subject).font(.system(size: 11)).lineLimit(1)
                                Spacer()
                                Text("\(result.left) \(commit.shortHash)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.blue)
                                if let twin { Text("≡ \(result.right) \(twin.shortHash)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.orange) }
                            }.padding(.vertical, 2)
                        }
                    }.padding(.horizontal, 4)
                }.frame(maxHeight: 160)
            } label: {
                Label("\(L("alreadyBoth")) (\(result.equivalentLeft.count))", systemImage: "checkmark.circle").font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private func chooseDefaults() {
        let names = branchNames
        guard !names.isEmpty else { return }
        if !names.contains(left) { left = store.repository?.branch ?? names[0] }
        if !names.contains(right) || right == left {
            let primary = store.repository?.primary ?? "main"
            right = [left == primary ? "develop" : primary, "develop", primary].first { $0 != left && names.contains($0) } ?? names.first { $0 != left } ?? left
        }
    }

    private func load() async {
        guard let root = store.repository?.root, !left.isEmpty, !right.isEmpty, left != right else { result = nil; return }
        loading = true; defer { loading = false }
        do {
            let value: BranchSyncResult = try await store.engine.call(["method": "branchSync", "path": root, "left": left, "right": right])
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
            ForEach(names, id: \.self) { name in Label(name, systemImage: store.isProtected(name) ? "lock" : "arrow.triangle.branch").tag(name) }
        }.labelsHidden().fixedSize()
    }
}

private struct StatCard: View {
    let value: Int; let title: String; let detail: String; let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)").font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(color).contentTransition(.numericText(value: Double(value)))
            Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
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
    var selected: [GitCommit] { commits.filter { selection.contains($0.hash) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(format: L("onlyIn"), source)).font(.system(size: 12, weight: .semibold))
                    Text(String(format: L("missingIn"), target)).font(.caption2).foregroundStyle(.secondary)
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
                            Button(String(format: L("copyTo"), target)) { store.copyCommits([commit], to: target) }.disabled(store.isProtected(target) || store.busy)
                        }
                        .accessibilityIdentifier("sync.commit.\(commit.shortHash)")
                        .accessibilityAction(named: L("viewCommit")) { store.showCommit(commit.hash, title: commit.subject) }
                }
                .listStyle(.inset)
            }
            Divider()
            VStack(spacing: 6) {
                Button { store.copyCommits(selected, to: target) } label: {
                    Label(String(format: L("copyN"), selected.count, target), systemImage: "arrow.right.doc.on.clipboard").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(selected.isEmpty || store.isProtected(target) || store.busy || store.terminalActive || !store.files.isEmpty)
                .accessibilityIdentifier("sync.copyTo.\(target)")
                if store.isProtected(target) { Text(String(format: L("targetProtected"), target)).font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center) }
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
                Text(commit.subject).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("\(commit.author) · \(commit.date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(commit.shortHash).font(.system(size: 10, design: .monospaced)).foregroundStyle(Brand.accent)
            Button(action: onView) { Image(systemName: "eye") }.buttonStyle(.borderless).help(L("viewCommit")).accessibilityLabel(L("viewCommit"))
        }
        .padding(.vertical, 3).contentShape(Rectangle())
        .onTapGesture(count: 2) { onView() }
        .onTapGesture { isOn.toggle() }
    }
}
