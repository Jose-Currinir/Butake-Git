import SwiftUI
import AppKit

struct WorkspaceView: View {
    @Bindable var store: WorkspaceStore
    @State private var rebaseSheet = false
    @State private var updates = UpdateService.shared
    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 195, ideal: 220, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if let repository = store.repository, !repository.operation.isEmpty { OperationBanner(store: store, operation: repository.operation).transition(.move(edge: .top).combined(with: .opacity)) }
                WorkspaceDetail(store: store)
                StatusBar(store: store)
            }
            .overlay(alignment: .top) { if store.busy || store.terminalActive { ActivityBar(active: true).transition(.opacity) } }
            .overlay(alignment: .bottom) { if let toast = store.toast { ToastView(toast: toast).padding(.bottom, 42).transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.92))) } }
            .animation(.smooth(duration: 0.25), value: store.repository?.operation)
            // The system toolbar background overhangs the split divider by ~3 pt and draws a step against
            // the content edge; without it the title sits on the window background and only the glass items remain.
            .toolbarBackground(.hidden, for: .windowToolbar)
            .modifier(FullScreenGlassToolbar())
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { store.action("fetch") } label: { Label(L("fetch"), systemImage: "arrow.down.to.line").symbolEffect(.pulse, isActive: store.runningAction == "fetch") }
                        .disabled(!store.canFetch).help(store.remoteHelp("fetchHelp")).accessibilityIdentifier("toolbar.fetch")
                    Button { store.action("pull", confirm: true) } label: { Label(L("pull"), systemImage: "arrow.down").symbolEffect(.pulse, isActive: store.runningAction == "pull") }.disabled(!store.canPull).help(store.remoteHelp("pullHelp")).accessibilityIdentifier("toolbar.pull")
                    Button { store.action("push", confirm: true) } label: { Label(L("push"), systemImage: "arrow.up").symbolEffect(.pulse, isActive: store.runningAction == "push") }.disabled(!store.canPush).help(store.remoteHelp("pushHelp")).accessibilityIdentifier("toolbar.push")
                }
                // Separate groups instead of a Divider (which renders as a stray dash); the system draws
                // each group as its own glass capsule.
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button(L("newBranch")) { store.creatingBranch = true }
                        Button(L("organizeMenu")) { store.organizing = true }.disabled(!store.canWrite).keyboardShortcut("o", modifiers: [.command, .shift])
                        Button(L("advancedRebase")) { rebaseSheet = true }.disabled(!store.canWrite)
                        Button(L("openBrowser")) { store.openPR() }
                        Button(L("openFinder")) { if let root = store.repository?.root { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root) } }
                    } label: { Label(L("tools"), systemImage: "ellipsis.circle") }.accessibilityIdentifier("toolbar.tools").disabled(store.repository == nil || store.busy || store.terminalActive)
                    Button { Task { await store.refresh(); store.notify(L("refreshed"), icon: "arrow.clockwise.circle.fill") } } label: { Label(L("refresh"), systemImage: "arrow.clockwise") }.accessibilityIdentifier("toolbar.refresh").disabled(store.repository == nil || store.busy || store.terminalActive)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { store.showInspector.toggle() } label: { Label(L("inspector"), systemImage: "sidebar.right") }.accessibilityIdentifier("toolbar.inspector")
                }
            }
            .inspector(isPresented: $store.showInspector) { InspectorContent(store: store).inspectorColumnWidth(min: 245, ideal: 285, max: 420) }
            // With the inspector open the search field spans both columns. The system toolbar background
            // overhangs the sidebar divider by ~3 pt, so the bar surface is drawn here, flush with the column.
            .overlay { if store.showInspector { ToolbarStrip().transition(.opacity) } }
        }
        .sheet(item: $store.pending) { operation in OperationConfirmation(store: store, operation: operation) }
        .sheet(item: $store.diffRequest) { request in QueryDiffSheet(store: store, request: request) }
        .sheet(isPresented: $store.organizing) { OrganizeCommitsView(store: store) }
        .sheet(item: $store.pullProblem) { problem in PullAssistantView(store: store, problem: problem) }
        .sheet(item: $store.resolving) { file in ConflictResolutionView(store: store, file: file) }
        .sheet(isPresented: $store.creatingBranch) { NewBranchSheet(store: store) }
        .sheet(isPresented: $store.cloningRepository) { CloneRepositorySheet(store: store) }
        .sheet(isPresented: $store.creatingRepository) { NewRepositorySheet(store: store) }
        .sheet(isPresented: $store.publishingRepository) { PublishRepositorySheet(store: store) }
        .sheet(item: Binding(get: { store.renamingBranch.map { BranchName(name: $0) } }, set: { store.renamingBranch = $0?.name })) { RenameBranchSheet(store: store, original: $0.name) }
        .sheet(isPresented: $rebaseSheet) { RebasePlannerView(store: store) }
        .sheet(isPresented: $updates.showingSheet) { UpdateSheet(updates: updates) }
        .alert(L("operationFailed"), isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button(L("close"), role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "").textSelection(.enabled) }
        .controlSize(.regular)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Picks up edits made in other tools without polling the filesystem.
            if store.repository != nil && !store.busy && !store.terminalActive { Task { await store.refresh() } }
        }
        .background(GeometryReader { geometry in Color.clear.onChange(of: geometry.size.width) { _, width in if width < 1120 { store.showInspector = false } } })
    }
}
private struct WorkspaceDetail: View {
    @Bindable var store: WorkspaceStore
    var showsRepository: Bool { store.repository != nil && store.route != .dictionary && store.route != .console }
    // No clipping or GeometryReader here: content and material backgrounds must extend under the
    // toolbar so the system glass keeps blurring them.
    var body: some View {
        ZStack {
            // History and Changes stay mounted: rebuilding them on every switch cost 50–120 ms
            // with 1 500 files / thousands of commits. Hidden ones skip hit-testing and accessibility.
            if store.repository != nil {
                PersistentPane(active: showsRepository && store.route == .history) { HistoryView(store: store) }
                PersistentPane(active: showsRepository && store.route == .changes) { ChangesView(store: store) }
            }
            Group {
                if store.route == .dictionary { DictionaryView(store: store) }
                else if store.route == .console { GitConsoleView(store: store) }
                else if store.repository == nil { WelcomeView(store: store) }
                else {
                    switch store.route {
                    case .review: ReviewView(store: store)
                    case .files: FileBrowserView(store: store)
                    case .branches: BranchesView(store: store)
                    case .sync: BranchSyncView(store: store)
                    case .worktrees, .tags, .stash, .remotes, .reflog: RepositoryToolsView(store: store)
                    case .pullRequests: PullRequestsView(store: store)
                    case .pipelines: PipelinesView(store: store)
                    case .agents: AgentsView(store: store)
                    default: EmptyView()
                    }
                }
            }
            .id(store.repository == nil && store.route != .dictionary && store.route != .console ? "welcome" : store.route.rawValue)
            .transition(.opacity)
        }
        .searchable(text: $store.search, prompt: L(store.route == .changes || store.route == .review ? "searchChanges" : "searchHistory"))
        // Route-dependent window chrome lives here, not in WorkspaceView: reading the route there re-evaluated the
        // whole window (toolbar, sheets, split view) on every section switch.
        .navigationTitle(store.title)
        .navigationSubtitle(store.route.title)
        .onChange(of: store.route) { _, route in if route != .history && route != .changes { store.showInspector = false } }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.3), value: store.repository == nil)
    }
}
/// Keeps an expensive view alive while hidden; only opacity changes on route switches.
private struct PersistentPane<Content: View>: View {
    let active: Bool
    @ViewBuilder let content: Content
    var body: some View {
        // Opacity 0 (not a large offset): far-offset panes inflated the composited bounds past texture
        // limits and parts of the window stopped drawing.
        content
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
    }
}
private struct SidebarView: View {
    @Bindable var store: WorkspaceStore
    @AppStorage("showRemoteBranches") private var showRemotes = false
    var selection: Binding<WorkspaceRoute?> { Binding(get: { store.route }, set: { if let route = $0 { store.route = route } }) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                BrandMark(size: 34)
                Text("Git").font(.system(size: 22, weight: .semibold))
                Spacer(minLength: 0)
            }.padding(.horizontal, 20).padding(.vertical, 18)
            Menu {
                Button(L("openRepository"), action: store.chooseRepository)
                Button(L("cloneRepository") + "…") { store.cloningRepository = true }.accessibilityIdentifier("sidebar.clone")
                Button(L("newRepository") + "…") { store.creatingRepository = true }.accessibilityIdentifier("sidebar.newRepository")
                if store.repository?.canPublish == true { Button(L("publishRepository") + "…") { store.publishingRepository = true }.accessibilityIdentifier("sidebar.publish") }
                if !store.recent.isEmpty { Divider(); ForEach(store.recent, id: \.self) { path in Button { store.reopenRecent(path) } label: { Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: path == store.repository?.root ? "checkmark" : "folder") } } }
            } label: {
                HStack { Image(systemName: "folder.fill").foregroundStyle(Brand.accent); VStack(alignment: .leading, spacing: 1) { Text(store.repository?.name ?? L("openRepository")).lineLimit(1); if let branch = store.repository?.branch { Text(branch).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).contentTransition(.interpolate) } }; Spacer(); Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary) }
                    .padding(10).background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
            }.menuStyle(.borderlessButton).accessibilityIdentifier("sidebar.repository").accessibilityLabel(L("openRepository")).accessibilityValue(store.repository.map { "\($0.name), \($0.branch)" } ?? "").padding(.horizontal, 14).padding(.bottom, 10).disabled(store.busy || store.terminalActive)
            List(selection: selection) {
                Section(L("repository")) {
                    ForEach([WorkspaceRoute.history, .changes, .review, .files, .branches, .sync, .worktrees, .tags, .stash, .remotes, .reflog]) { route in
                        Label { HStack { Text(route.title); Spacer(); if route == .changes || route == .review, case let count = route == .review ? store.files.count - store.reviewedCount : store.files.count, count > 0 { Text("\(count)").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(Brand.accent).padding(.horizontal, 6).padding(.vertical, 1).background(Brand.accent.opacity(0.14), in: Capsule()).countTransition(count).transition(.scale.combined(with: .opacity)) } } } icon: { Image(systemName: route.icon) }.listItemTint(Brand.accent).tag(route).accessibilityIdentifier("route.\(route.rawValue)")
                    }
                }
                Section(L("collaboration")) { ForEach([WorkspaceRoute.pullRequests, .pipelines, .agents]) { route in Label(route.title, systemImage: route.icon).listItemTint(Brand.accent).tag(route).accessibilityIdentifier("route.\(route.rawValue)") } }
                Section(L("tools")) { ForEach([WorkspaceRoute.dictionary, .console]) { route in Label(route.title, systemImage: route.icon).listItemTint(Brand.accent).tag(route).accessibilityIdentifier("route.\(route.rawValue)") } }
                if let repo = store.repository, !repo.branches.isEmpty {
                    Section {
                        ForEach(BranchNaming.groups(repo.branches, name: \.name), id: \.prefix) { group in
                            if let prefix = group.prefix {
                                DisclosureGroup {
                                    ForEach(group.items) { branch in SidebarBranchRow(store: store, branch: branch, grouped: true) }
                                } label: { BranchGroupLabel(prefix: prefix, count: group.items.count) }
                            } else {
                                ForEach(group.items) { branch in SidebarBranchRow(store: store, branch: branch) }
                            }
                        }
                    } header: {
                        HStack { Text(L("localBranches")); Spacer(); Button { store.creatingBranch = true } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help(L("newBranch")).accessibilityLabel(L("newBranch")).accessibilityIdentifier("sidebar.newBranch") }
                    }
                    if !repo.remoteOnly.isEmpty {
                        Section(isExpanded: $showRemotes) {
                            ForEach(BranchNaming.groups(repo.remoteOnly, name: \.short), id: \.prefix) { group in
                                if let prefix = group.prefix {
                                    DisclosureGroup {
                                        ForEach(group.items) { remote in SidebarRemoteBranchRow(store: store, remote: remote, grouped: true) }
                                    } label: { BranchGroupLabel(prefix: prefix, count: group.items.count) }
                                } else {
                                    ForEach(group.items) { remote in SidebarRemoteBranchRow(store: store, remote: remote) }
                                }
                            }
                        } header: { Text("\(L("remoteBranches")) · \(repo.remoteOnly.count)") }
                    }
                }
            }.listStyle(.sidebar).scrollIndicators(.automatic).scrollBounceBehavior(.basedOnSize).disabled(store.busy || store.terminalActive)
            HStack { VersionBadge(updates: UpdateService.shared); Spacer(); SettingsLink { Image(systemName: "gearshape").font(.system(size: 13)) }.buttonStyle(.borderless).help(L("settings")) }.padding(.horizontal, 16).padding(.vertical, 10)
                .animation(.snappy, value: UpdateService.shared.updateAvailable)
        }
    }
}
private struct WelcomeView: View {
    let store: WorkspaceStore
    @State private var appeared = false
    @State private var glow = false
    var body: some View {
        VStack(spacing: 22) {
            BrandMark(size: 90)
                .shadow(color: Brand.green.opacity(glow ? 0.28 : 0.10), radius: glow ? 40 : 26, y: 8)
                .scaleEffect(appeared ? 1 : 0.82).opacity(appeared ? 1 : 0)
            VStack(spacing: 10) { Text(L("welcomeTitle")).font(.system(size: 34, weight: .semibold, design: .rounded)); Text(L("welcomeDetail")).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 430) }
                .offset(y: appeared ? 0 : 12).opacity(appeared ? 1 : 0)
            HStack(spacing: 10) {
                Button(L("openRepository"), action: store.chooseRepository).accessibilityIdentifier("welcome.open").buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut("o")
                Button(L("cloneRepository") + "…") { store.cloningRepository = true }.accessibilityIdentifier("welcome.clone").controlSize(.large)
                Button(L("newRepository") + "…") { store.creatingRepository = true }.accessibilityIdentifier("welcome.newRepository").controlSize(.large)
            }
                .opacity(appeared ? 1 : 0)
            if !store.recent.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("recent")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 4)
                    ForEach(Array(store.recent.prefix(5).enumerated()), id: \.element) { index, path in
                        RecentRow(path: path) { store.reopenRecent(path) }
                            .offset(y: appeared ? 0 : 10).opacity(appeared ? 1 : 0)
                            .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.18 + Double(index) * 0.05), value: appeared)
                    }
                }.frame(width: 380, alignment: .leading).padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
            }
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { appeared = true }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true).delay(0.6)) { glow = true }
        }
    }
}
private struct RecentRow: View {
    let path: String; let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").foregroundStyle(Brand.accent).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                    Text((path as NSString).abbreviatingWithTildeInPath).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary).opacity(hovering ? 1 : 0).offset(x: hovering ? 0 : -4)
            }.padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).onHover { hover in withAnimation(.easeOut(duration: 0.15)) { hovering = hover } }
    }
}
private struct StatusBar: View {
    let store: WorkspaceStore
    var body: some View {
        HStack(spacing: 14) {
            Label(store.repository?.branch ?? L("localOnly"), systemImage: store.onProtectedMain ? "lock" : "arrow.triangle.branch").foregroundStyle(Brand.accent)
            Divider().frame(height: 10)
            if store.busy { ProgressView().controlSize(.mini).transition(.scale.combined(with: .opacity)) }
            Text(store.status).lineLimit(1).contentTransition(.opacity)
            Spacer()
            if let repo = store.repository {
                if repo.branch == repo.primary || repo.branches.contains(where: { $0.name == repo.primary }) { MainProtectionMenu(store: store, repository: repo) }
                if repo.canPublish {
                    Label(L(repo.hasRemote ? "notPublished" : "localOnly"), systemImage: "laptopcomputer").foregroundStyle(.tertiary).help(L(repo.hasRemote ? "notPublishedHelp" : "noRemoteHelp"))
                    Button(L("publishShort")) { store.publishingRepository = true }.buttonStyle(.link).help(L("publishSubtitle")).accessibilityIdentifier("status.publish")
                }
                else if repo.remote.isEmpty && repo.ahead == 0 && repo.behind == 0 { Text(L("noUpstream")).foregroundStyle(.tertiary) }
                else if repo.ahead == 0 && repo.behind == 0 { Label(L("upToDate"), systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                else {
                    HStack(spacing: 8) {
                        Label("\(repo.ahead)", systemImage: "arrow.up").foregroundStyle(repo.ahead > 0 ? Brand.accent : .secondary).contentTransition(.numericText(value: Double(repo.ahead)))
                        Label("\(repo.behind)", systemImage: "arrow.down").foregroundStyle(repo.behind > 0 ? Color.orange : .secondary).contentTransition(.numericText(value: Double(repo.behind)))
                    }.monospacedDigit().help(L("aheadBehindHelp"))
                }
            }
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 29).background(.bar)
        .animation(.snappy, value: store.busy).animation(.snappy, value: store.repository?.ahead).animation(.snappy, value: store.repository?.behind).animation(.easeOut(duration: 0.2), value: store.status)
    }
}
struct OperationConfirmation: View {
    @Environment(\.dismiss) private var dismiss
    let store: WorkspaceStore
    let operation: PendingOperation
    @State private var appeared = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: operation.destructive ? "exclamationmark.triangle.fill" : "arrow.triangle.branch").font(.system(size: 22, weight: .semibold)).foregroundStyle(operation.destructive ? Color.red : Brand.accent)
                    .frame(width: 42, height: 42).background((operation.destructive ? Color.red : Brand.accent).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .symbolEffect(.bounce, value: appeared)
                VStack(alignment: .leading, spacing: 2) { Text(operation.destructive ? operation.title : L("confirmation")).font(.title2.weight(.semibold)); if operation.destructive { Text(L("cannotUndo")).font(.caption).foregroundStyle(.red) } }
            }
            Text(operation.detail ?? L("confirmationDetail")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LabeledContent(L("repository"), value: operation.root).font(.caption)
            Text(operation.preview).font(.system(.body, design: .monospaced)).textSelection(.enabled).accessibilityIdentifier("confirm.preview").frame(maxWidth: .infinity, alignment: .leading).padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack { Spacer(); Button(L("cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("confirm.cancel"); Button(operation.destructive ? L("discard") : L("confirm"), role: operation.destructive ? .destructive : nil) { dismiss(); Task { await store.perform(operation) } }.buttonStyle(.borderedProminent).tint(operation.destructive ? .red : Brand.accent).keyboardShortcut(.defaultAction).accessibilityIdentifier("confirm.execute") }
        }.padding(26).frame(width: 540)
        .onAppear { appeared = true }
    }
}
struct NewBranchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: WorkspaceStore
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) { Text(L("newBranch")).font(.title2.weight(.semibold)); TextField(L("branchName"), text: $name).textFieldStyle(.roundedBorder); HStack { Spacer(); Button(L("cancel"), role: .cancel) { dismiss() }; Button(L("createAndSwitch")) { store.action("create_branch", value: name); dismiss() }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.defaultAction) } }.padding(26).frame(width: 440)
    }
}
struct OperationBanner: View {
    let store: WorkspaceStore; let operation: String
    @State private var pulse = false
    var conflicts: Int { store.changes.conflicts.count }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: conflicts > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundStyle(conflicts > 0 ? .orange : Brand.accent).opacity(pulse && conflicts > 0 ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("op_\(operation)") == "op_\(operation)" ? "\(L("operationInProgress")): \(operation)" : L("op_\(operation)")).fontWeight(.semibold)
                Text(conflicts > 0 ? String(format: L("conflictsPending"), conflicts) : L("conflictsDone")).foregroundStyle(.secondary).contentTransition(.numericText(value: Double(conflicts)))
            }
            Spacer()
            if conflicts > 0 {
                Button(L("resolveNow")) { store.resolveNextConflict() }.buttonStyle(.borderedProminent).tint(.orange).accessibilityIdentifier("banner.resolve")
            } else {
                // Continue may open Git's editor, so it runs in the PTY after confirmation.
                Button(L("continue")) { Task { await store.prepare(operation, arguments: "--continue", interactive: true) } }.buttonStyle(.borderedProminent).tint(Brand.accent).accessibilityIdentifier("banner.continue")
            }
            if operation == "rebase" { Button(L("skip")) { Task { await store.prepare("rebase", arguments: "--skip", interactive: true) } }.accessibilityIdentifier("banner.skip") }
            Button(L("abortOperation"), role: .destructive) { store.abortOperation() }.accessibilityIdentifier("banner.abort")
            Button { store.inspect(operation, arguments: "--continue") } label: { Image(systemName: "terminal") }.help(L("inspectConsole")).accessibilityLabel(L("inspectConsole"))
        }
        .font(.caption).controlSize(.small).padding(.horizontal, 14).padding(.vertical, 8).background((conflicts > 0 ? Color.orange : Brand.accent).opacity(0.12))
        .disabled(store.busy || store.terminalActive)
        .animation(.snappy, value: conflicts)
        .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true } }
    }
}
/// Explains a failed pull in plain Spanish and offers the safe next steps.
struct PullAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    let store: WorkspaceStore; let problem: PullProblem
    @State private var showDetail = false
    var parts: (message: String, detail: String) {
        let pieces = problem.detail.components(separatedBy: "\n\nDetalle de Git: ")
        return (pieces.first ?? problem.detail, pieces.count > 1 ? pieces[1] : "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 44, height: 44).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) { Text(L("pullAssistant")).font(.caption).foregroundStyle(.secondary); Text(title).font(.title3.weight(.semibold)) }
            }
            Text(body_).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) { options }
            if !parts.detail.isEmpty {
                DisclosureGroup(L("gitDetail"), isExpanded: $showDetail) {
                    Text(parts.detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }.font(.caption)
            }
            HStack { Spacer(); Button(L("close")) { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("pull.close") }
        }.padding(24).frame(width: 520)
    }
    private var icon: String { switch problem.code { case "pull_diverged": "arrow.triangle.branch"; case "pull_local_changes": "tray.full"; case "pull_conflicts": "exclamationmark.triangle.fill"; case "pull_no_upstream": "icloud.slash"; default: "wifi.exclamationmark" } }
    private var tint: Color { problem.code == "pull_conflicts" ? .orange : Brand.accent }
    private var title: String { switch problem.code { case "pull_diverged": L("pullDivergedTitle"); case "pull_local_changes": L("pullLocalTitle"); case "pull_conflicts": L("pullConflictsTitle"); case "pull_no_upstream": L("pullNoUpstreamTitle"); default: L("pullRemoteTitle") } }
    private var body_: String {
        switch problem.code {
        case "pull_diverged": String(format: L("pullDivergedBody"), store.repository?.ahead ?? 0, store.repository?.behind ?? 0)
        case "pull_local_changes": L("pullLocalBody")
        case "pull_conflicts": L("pullConflictsBody") + "\n\n" + L("conflictSteps")
        default: parts.message
        }
    }
    @ViewBuilder private var options: some View {
        switch problem.code {
        case "pull_diverged" where store.onProtectedMain:
            OptionCard(icon: "arrow.triangle.swap", title: L("pullProtectedSync"), detail: L("pullProtectedSyncDetail"), recommended: true, id: "pull.sync") { dismiss(); store.route = .sync }
            OptionCard(icon: "arrow.triangle.branch", title: L("pullProtectedBranch"), detail: L("pullProtectedBranchDetail"), id: "pull.branches") { dismiss(); store.route = .branches }
        case "pull_diverged":
            OptionCard(icon: "arrow.triangle.merge", title: L("pullMergeTitle"), detail: L("pullMergeDetail"), recommended: true, id: "pull.merge") { dismiss(); store.pull("pull_merge") }
            OptionCard(icon: "arrow.up.to.line", title: L("pullRebaseTitle"), detail: L("pullRebaseDetail"), id: "pull.rebase") { dismiss(); store.pull("pull_rebase") }
        case "pull_local_changes":
            OptionCard(icon: "archivebox", title: L("pull_autostash"), detail: L("pullAutostashDetail"), recommended: true, id: "pull.autostash") { dismiss(); store.pull("pull_autostash") }
            OptionCard(icon: "square.and.pencil", title: L("pullGoCommit"), detail: L("commitHelp"), id: "pull.goCommit") { dismiss(); store.route = .changes }
        case "pull_conflicts":
            OptionCard(icon: "arrow.triangle.merge", title: L("resolveNow"), detail: String(format: L("conflictsPending"), store.changes.conflicts.count), recommended: true, id: "pull.resolve") { dismiss(); store.resolveNextConflict() }
            OptionCard(icon: "arrow.uturn.backward", title: L("abortOperation"), detail: L("abortDetail"), id: "pull.abort") { dismiss(); store.abortOperation() }
        case "pull_no_upstream":
            OptionCard(icon: "arrow.up", title: L("pushNow"), detail: L("pushHelp"), recommended: true, id: "pull.push") { dismiss(); store.action("push", confirm: true) }
        default:
            OptionCard(icon: "arrow.clockwise", title: L("retry"), detail: L("pullHelp"), id: "pull.retry") { dismiss(); store.action("pull", confirm: true) }
        }
    }
}
private struct OptionCard: View {
    let icon: String; let title: String; let detail: String; var recommended = false; let id: String; let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(recommended ? Brand.accent : .secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 13, weight: .semibold)); Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading) }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).offset(x: hovering ? 2 : 0)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(RoundedRectangle(cornerRadius: 10))
            .background(hovering ? Brand.accent.opacity(0.10) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(recommended ? Brand.accent.opacity(0.5) : Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain).accessibilityLabel(title).accessibilityHint(detail).accessibilityIdentifier(id)
        .onHover { hover in withAnimation(.easeOut(duration: 0.12)) { hovering = hover } }
    }
}
/// Native, selectable diff for any read-only query; replaces sending users to the console just to look.
struct QueryDiffSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: WorkspaceStore; let request: DiffRequest
    @State private var text = ""
    @State private var loaded = false
    var stats: LineStats {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return LineStats(additions: lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count, deletions: lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count)
    }
    /// The title is a repository path when the sheet shows one file (commit file, file history).
    private var isFile: Bool { !request.title.contains(" ") && (request.title.contains(".") || request.title.contains("/")) }
    private var localURL: URL? {
        guard let root = store.repository?.root else { return nil }
        let url = URL(fileURLWithPath: root).appendingPathComponent(request.title)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    private var kind: ChangeKind? {
        if text.contains("new file mode") { return .added }
        if text.contains("deleted file mode") { return .deleted }
        if text.contains("rename from ") { return .renamed }
        return text.isEmpty ? nil : .modified
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if isFile { FileTypeIcon(path: request.title, size: 30) }
                else { Image(systemName: "plus.forwardslash.minus").foregroundStyle(Brand.accent).font(.system(size: 17, weight: .semibold)).frame(width: 30) }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(isFile ? (request.title as NSString).lastPathComponent : request.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if loaded, isFile, let kind { ChangeKindBadge(kind: kind) }
                    }
                    HStack(spacing: 6) {
                        if isFile, case let folder = (request.title as NSString).deletingLastPathComponent, !folder.isEmpty { Label(folder, systemImage: "folder").labelStyle(.titleAndIcon) }
                        if !request.subtitle.isEmpty { Text(request.subtitle).lineLimit(1).truncationMode(.middle) }
                    }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                if loaded { StatsBadge(stats: stats).scaleEffect(1.15).transition(.opacity) }
                ControlGroup {
                    Button { store.copyToPasteboard(text) } label: { Image(systemName: "doc.on.doc") }.help(L("copyDiff")).accessibilityLabel(L("copyDiff")).accessibilityIdentifier("diff.copy").disabled(text.isEmpty)
                    if isFile, let url = localURL { Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.app") }.help(L("openInEditor")).accessibilityLabel(L("openInEditor")).accessibilityIdentifier("diff.openEditor") }
                }.fixedSize()
                Button(L("close")) { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("diff.close")
            }.padding(.horizontal, 16).padding(.vertical, 12).background(.bar)
            Divider()
            if !loaded { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if text.isEmpty { ContentUnavailableView(L("noDifferences"), systemImage: "equal.circle", description: Text(L("noDifferencesDetail"))).frame(maxWidth: .infinity, maxHeight: .infinity).transition(.opacity) }
            else { DiffView(text: text, path: isFile ? request.title : nil).transition(.opacity).accessibilityIdentifier("diff.content") }
        }
        .frame(minWidth: 760, idealWidth: 940, minHeight: 520, idealHeight: 660)
        .animation(.easeOut(duration: 0.2), value: loaded)
        .task {
            guard let root = store.repository?.root else { return }
            do { text = try await store.engine.query(root, request.args) } catch { text = error.localizedDescription }
            loaded = true
        }
    }
}

/// Indeterminate brand-colored sweep shown while Git is working.
struct ActivityBar: View {
    let active: Bool
    @State private var phase: CGFloat = -0.35
    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(LinearGradient(colors: [Brand.accent.opacity(0), Brand.accent, Brand.accent.opacity(0)], startPoint: .leading, endPoint: .trailing))
                .frame(width: geometry.size.width * 0.35, height: 2)
                .offset(x: geometry.size.width * phase)
        }
        .frame(height: 2).clipped().opacity(active ? 1 : 0).allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.2), value: active)
        .onChange(of: active, initial: true) { _, running in
            guard running else { phase = -0.35; return }
            phase = -0.35
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1.0 }
        }
        .accessibilityHidden(true)
    }
}
struct ToastView: View {
    let toast: Toast
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: toast.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(toast.destructive ? Color.orange : Brand.accent).symbolEffect(.bounce, value: toast.id)
            Text(toast.message).font(.system(size: 12, weight: .medium)).lineLimit(2)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isStaticText)
    }
}

private struct BranchName: Identifiable { var name: String; var id: String { name } }
private struct BranchGroupLabel: View {
    let prefix: String; let count: Int
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: BranchNaming.groupIcon(prefix)).font(.caption).foregroundStyle(.secondary).frame(width: 14)
            Text(BranchNaming.groupTitle(prefix)).font(.system(size: 11)).lineLimit(1)
            Spacer()
            Text("\(count)").font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundStyle(.tertiary)
        }.help("\(prefix)/").accessibilityLabel("\(BranchNaming.groupTitle(prefix)), \(count)")
    }
}
/// A branch that only exists on the remote: bring it in (local branch tracking it) or delete it there.
private struct SidebarRemoteBranchRow: View {
    let store: WorkspaceStore; let remote: RemoteBranch; var grouped = false
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "cloud").font(.caption).foregroundStyle(.secondary).frame(width: 14)
            Text(grouped ? BranchNaming.leaf(remote.short) : remote.short).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            Spacer()
            if let date = remote.date { Text(RelativeDateCache.shared.text(for: date)).font(.system(size: 9.5)).foregroundStyle(.tertiary) }
        }
        .font(.system(size: 11)).contentShape(Rectangle())
        .help(remote.name)
        .onTapGesture(count: 2) { store.trackBranch(remote) }
        .contextMenu {
            Button(L("trackBranch")) { store.trackBranch(remote) }
            Button(L("filterHistory")) { store.search = remote.name; store.route = .history }
            Button(L("copyBranchName")) { store.copyToPasteboard(remote.short) }
            Divider()
            Button(L("deleteRemoteBranch") + "…", role: .destructive) { store.deleteRemoteBranch(remote) }.disabled(remote.short == store.repository?.primary || remote.short == "develop")
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(remote.name).accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("remoteBranch.\(remote.name)")
        .accessibilityAction(named: L("trackBranch")) { store.trackBranch(remote) }
        .accessibilityAction(named: L("deleteRemoteBranch")) { store.deleteRemoteBranch(remote) }
    }
}
private struct SidebarBranchRow: View {
    let store: WorkspaceStore; let branch: GitBranch; var grouped = false
    @State private var hovering = false
    @State private var showCard = false
    @State private var hoverTask: Task<Void, Never>?
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: store.isProtected(branch.name) ? "lock" : "arrow.triangle.branch").font(.caption).foregroundStyle(branch.current ? Brand.accent : .secondary)
            Text(grouped ? BranchNaming.leaf(branch.name) : branch.name).lineLimit(1).truncationMode(.middle).fontWeight(branch.current ? .semibold : .regular)
            Spacer()
            if branch.gone == true { Image(systemName: "cloud.slash").font(.system(size: 9)).foregroundStyle(.orange).help(L("branchGone")) }
            if (branch.ahead ?? 0) > 0 || (branch.behind ?? 0) > 0 { Text(String(format: L("aheadBehind"), branch.ahead ?? 0, branch.behind ?? 0)).font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(.secondary) }
            if branch.current { Circle().fill(Brand.accent).frame(width: 6, height: 6).shadow(color: Brand.accent.opacity(0.6), radius: hovering ? 4 : 0) }
            else if hovering { Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.secondary).transition(.opacity) }
        }
        .font(.system(size: 11)).contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
            hoverTask?.cancel()
            hoverTask = Task { try? await Task.sleep(for: .milliseconds(inside ? 500 : 200)); if !Task.isCancelled { showCard = inside } }
        }
        .popover(isPresented: $showCard, arrowEdge: .trailing) { SidebarBranchCard(store: store, branch: branch) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(branch.name)
        .accessibilityValue([branch.current ? L("current") : nil, branch.upstream.isEmpty ? L("noUpstream") : branch.upstream].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("branch.\(branch.name)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: L("switch_branch")) { if !branch.current { store.action("switch_branch", value: branch.name) } }
        .accessibilityAction(named: L("filterHistory")) { store.search = branch.name; store.route = .history }
        .accessibilityAction(named: L("copyBranchName")) { store.copyToPasteboard(branch.name) }
        .onTapGesture(count: 2) { if !branch.current { store.action("switch_branch", value: branch.name) } }
        .contextMenu {
            Button(L("switch_branch")) { store.action("switch_branch", value: branch.name) }.disabled(branch.current)
            Button(L("copyBranchName")) { store.copyToPasteboard(branch.name) }
            Button(L("filterHistory")) { store.search = branch.name; store.route = .history }
            Button(L("inspectConsole")) { store.inspect("log", arguments: "--oneline \(branch.name)") }
            Divider()
            Button(L("newBranchFromHere")) { store.creatingBranch = true }
            Button(L("renameBranch")) { store.renamingBranch = branch.name }.disabled(branch.name == store.repository?.primary)
            Button(L("deleteBranch") + "…", role: .destructive) { store.deleteBranch(branch.name) }.disabled(branch.current || branch.name == store.repository?.primary)
        }
        .accessibilityAction(named: L("deleteBranch")) { if !branch.current { store.deleteBranch(branch.name) } }
        .accessibilityAction(named: L("rename_branch")) { store.renamingBranch = branch.name }
    }
}
private struct SidebarBranchCard: View {
    let store: WorkspaceStore; let branch: GitBranch
    var body: some View {
        let locals = Set(store.repository?.branches.map(\.name) ?? [])
        let tip = store.repository?.commits.first { commit in CommitReference.parse(commit.refs, localBranches: locals).contains { ($0.kind == .head || $0.kind == .branch) && $0.name == branch.name } }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: store.isProtected(branch.name) ? "lock.fill" : "arrow.triangle.branch").foregroundStyle(Brand.accent)
                Text(branch.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if branch.current { Text(L("current")).font(.system(size: 9, weight: .semibold)).foregroundStyle(Brand.accent).padding(.horizontal, 6).padding(.vertical, 2).background(Brand.accent.opacity(0.14), in: Capsule()) }
            }
            Label(branch.upstream.isEmpty ? L("noUpstream") : branch.upstream, systemImage: "network").font(.caption).foregroundStyle(.secondary)
            if branch.current, let repo = store.repository, !branch.upstream.isEmpty {
                HStack(spacing: 12) {
                    Label("\(repo.ahead) \(L("toPush"))", systemImage: "arrow.up").foregroundStyle(repo.ahead > 0 ? Brand.accent : .secondary)
                    Label("\(repo.behind) \(L("toPull"))", systemImage: "arrow.down").foregroundStyle(repo.behind > 0 ? Color.orange : .secondary)
                }.font(.caption.monospacedDigit())
            }
            if store.isProtected(branch.name) { Label(String(format: L("protectedMain"), branch.name), systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary) }
            Divider()
            if let tip {
                Text(L("lastBranchCommit")).font(.caption2).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 10) {
                    AuthorAvatar(name: tip.author, size: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tip.subject).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        Text("\(tip.author) · \(tip.date.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                        Text(tip.shortHash).font(.system(size: 10, design: .monospaced)).foregroundStyle(Brand.accent)
                    }
                }
            } else { Text(L("tipOutsideHistory")).font(.caption).foregroundStyle(.secondary) }
            if !branch.current { Text(L("doubleClickSwitch")).font(.caption2).foregroundStyle(.tertiary) }
        }.padding(14).frame(width: 290, alignment: .leading)
    }
}


/// Per-repository protection of `main`, shown in the status bar.
struct MainProtectionMenu: View {
    let store: WorkspaceStore; let repository: RepositorySnapshot
    var body: some View {
        let protected = repository.mainProtected == true
        let mode = repository.mainProtection ?? ""
        Menu {
            Picker(L("mainProtection"), selection: Binding(get: { mode }, set: { store.setMainProtection($0.isEmpty ? "auto" : $0) })) {
                Text(L("protectionAuto")).tag("")
                Text(L("protectionOn")).tag("true")
                Text(L("protectionOff")).tag("false")
            }.pickerStyle(.inline)
            Divider()
            Text(sourceText)
            Button(L("protectionCheckRemote")) { Task { await store.syncRemoteProtection() } }.accessibilityIdentifier("status.checkRemoteProtection")
            Text(L("protectionHelp"))
        } label: {
            Label(String(format: L(protected ? "protectedMain" : "mainFree"), repository.primary), systemImage: protected ? "lock.shield" : "lock.open")
        }
        .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
        .help(L("protectionHelp")).accessibilityIdentifier("status.mainProtection")
    }
    private var sourceText: String {
        let provider = (try? HostedRepository(remote: repository.remote))?.provider.title ?? L("remote")
        if let mode = repository.mainProtection, !mode.isEmpty { return L("protectionSourceManual") }
        switch repository.mainProtectionRemote ?? "" {
        case "true": return String(format: L("protectionSourceRemoteOn"), provider)
        case "false": return String(format: L("protectionSourceRemoteOff"), provider)
        default: return L("protectionSourceUnknown")
        }
    }
}

/// In full screen AppKit stacks the toolbar above the content, so nothing shows through its glass.
/// Revealing it on hover lets the content fill the screen and the toolbar float over it, as in a window.
/// Reads the route itself so only the inspector re-evaluates when the section changes.
private struct InspectorContent: View {
    let store: WorkspaceStore
    var body: some View { if store.route == .changes { FileInspector(store: store) } else { CommitInspector(store: store) } }
}
/// Bar material behind the toolbar, covering exactly the detail and inspector columns.
private struct ToolbarStrip: View {
    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Rectangle().fill(.bar).frame(height: proxy.safeAreaInsets.top)
                Rectangle().fill(.separator).frame(height: 0.5)
                Spacer(minLength: 0)
            }
            .ignoresSafeArea(edges: .top)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
private struct FullScreenGlassToolbar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.windowToolbarFullScreenVisibility(.onHover) } else { content }
    }
}
