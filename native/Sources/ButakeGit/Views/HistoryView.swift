import SwiftUI
import AppKit

struct HistoryView: View {
    @Bindable var store: WorkspaceStore
    @State private var scope = ""
    @State private var scopedHashes: Set<String>?
    @FocusState private var focused: Bool
    @State private var hover = HistoryHover()
    var body: some View {
        // Filtering and lane layout are memoized per snapshot/search/scope in the store.
        let model = store.historyModel(search: store.search, scope: scopedHashes)
        let commits = model.commits
        let graph = model.graph
        let locals = store.refs.localBranches
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Menu { Button(L("allBranches")) { scope = "" }; ForEach(store.repository?.branches ?? []) { branch in Button(branch.name) { scope = branch.name } } } label: { Label(scope.isEmpty ? L("allBranches") : scope, systemImage: "line.3.horizontal.decrease") }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Text(L("historyKeys")).foregroundStyle(.tertiary)
                Text("\(commits.count) \(L("commits"))").foregroundStyle(.secondary).contentTransition(.numericText(value: Double(commits.count))).animation(.snappy, value: commits.count)
            }.font(.uiCaption).padding(.horizontal, 20).frame(height: 40).background(Brand.bar)
            Divider()
            if let last = store.lastRewrite, last.branch == store.repository?.branch {
                HStack(spacing: 10) {
                    Image(systemName: "wand.and.stars").foregroundStyle(Brand.accent)
                    Text(L("rewriteBanner")).font(.uiCaption.weight(.medium))
                    Spacer()
                    Button(L("undo")) { store.undoRewrite() }.controlSize(.small).accessibilityIdentifier("history.undoRewrite")
                    Button { withAnimation(.snappy) { store.lastRewrite = nil } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).controlSize(.small).accessibilityLabel(L("close"))
                }
                .padding(.horizontal, 16).padding(.vertical, 7).background(Brand.accent.opacity(0.10))
                .transition(.move(edge: .top).combined(with: .opacity))
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(commits) { commit in
                            CommitRow(store: store, hover: hover, commit: commit, graph: graph.rows[model.rowIndex[commit.hash] ?? 0], graphWidth: graph.width, branch: graph.branchLabels[commit.hash], locals: locals)
                                .id(commit.hash)
                        }
                        if store.canLoadMoreHistory && scopedHashes == nil && store.search.isEmpty {
                            Button { store.loadMoreHistory() } label: {
                                HStack(spacing: 8) {
                                    if store.loadingHistory { Spinner(size: 14) } else { Image(systemName: "arrow.down.circle") }
                                    Text(store.loadingHistory ? L("loading") : L("loadMore"))
                                }.frame(maxWidth: .infinity).padding(.vertical, 14)
                            }.buttonStyle(.borderless).disabled(store.loadingHistory || store.busy).accessibilityIdentifier("history.loadMore")
                            .onAppear { store.loadMoreHistory() }
                        }
                    }
                    // One tracking area for the whole list instead of one per row: per-row onHover made
                    // AppKit rebuild hundreds of tracking areas on every layout.
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let index = Int(location.y / CommitRow.height)
                            hover.update(hash: commits.indices.contains(index) ? commits[index].hash : nil, overGraph: location.x < CGFloat(graph.width * 18 + 28))
                        case .ended: hover.update(hash: nil, overGraph: false)
                        }
                    }
                    if commits.isEmpty { ContentUnavailableView(L("noResults"), systemImage: "magnifyingglass").padding(.top, 60).transition(.opacity) }
                }
                .focusable(store.route == .history).focused($focused).focusEffectDisabled()
                .onKeyPress(.downArrow) { move(1, in: commits, proxy: proxy) }
                .onKeyPress(.upArrow) { move(-1, in: commits, proxy: proxy) }
                .onKeyPress(.return) { if let commit = store.selectedCommit { store.showInspector = true; store.selectedCommit = commit }; return .handled }
                .onAppear { focused = store.route == .history }
                .onChange(of: store.route) { _, route in focused = route == .history }
            }
        }
        .task(id: "\(scope)|\(pathFilterKey)|\(store.repository?.commits.count ?? 0)") {
            let query = SearchQuery(store.search)
            guard !scope.isEmpty || query.hasPathFilters, let root = store.repository?.root else { scopedHashes = nil; return }
            // Branch scope and/or commits that touched matching paths (@archivo / @ext).
            var args = ["log", "--format=%H"]
            if !scope.isEmpty { args.append(scope) }
            if query.hasPathFilters {
                store.ensureDeepHistory()
                await store.loadTrackedFiles()
                let paths = query.matchingPaths(in: store.trackedFiles)
                guard !paths.isEmpty else { scopedHashes = []; return }
                // One exact file: follow it through renames.
                if paths.count == 1, query.exts.isEmpty, query.files.first == paths.first { args.append("--follow") }
                args += ["--"] + paths
            }
            let file: String? = query.hasPathFilters ? "" : nil
            do {
                let ordered = try await store.engine.query(root, args).split(separator: "\n").map(String.init)
                scopedHashes = Set(ordered)  // no animation: animating the removal of thousands of rows froze the app for minutes
                // Show the file's latest commit in the inspector instead of one outside the filter.
                if file != nil, let selected = store.selectedCommit?.hash, !ordered.contains(selected), let first = ordered.first { store.selectCommit(hash: first) }
            } catch { store.fail(error) }
        }
    }
    /// Only the path filters reach Git; free text and @autor filter the loaded commits locally.
    private var pathFilterKey: String { let query = SearchQuery(store.search); return (query.files + ["|"] + query.exts).joined(separator: ",") }
    private func move(_ offset: Int, in commits: [GitCommit], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !commits.isEmpty else { return .ignored }
        let current = commits.firstIndex { $0.hash == store.selectedCommit?.hash } ?? (offset > 0 ? -1 : commits.count)
        let next = commits[min(max(current + offset, 0), commits.count - 1)]
        withAnimation(.snappy(duration: 0.18)) { store.selectedCommit = next; proxy.scrollTo(next.hash) }
        return .handled
    }
}
/// Hover state shared by the history rows; only rows whose hover value changes re-render.
@MainActor @Observable final class HistoryHover {
    var hash: String?
    var cardHash: String?
    @ObservationIgnored private var cardTask: Task<Void, Never>?
    func update(hash newHash: String?, overGraph: Bool) {
        if hash != newHash { withAnimation(.easeOut(duration: 0.1)) { hash = newHash } }
        let target = overGraph ? newHash : nil
        guard target != cardHash || target == nil else { return }
        cardTask?.cancel()
        if let target {
            cardTask = Task { [weak self] in try? await Task.sleep(for: .milliseconds(450)); if !Task.isCancelled { self?.cardHash = target } }
        } else if cardHash != nil {
            cardTask = Task { [weak self] in try? await Task.sleep(for: .milliseconds(250)); if !Task.isCancelled { self?.cardHash = nil } }
        }
    }
}
private struct CommitRow: View {
    static let height: CGFloat = 57
    let store: WorkspaceStore
    let hover: HistoryHover
    let commit: GitCommit
    let graph: GraphRow
    let graphWidth: Int
    let branch: String?
    let locals: Set<String>
    var hovering: Bool { hover.hash == commit.hash }
    var showCard: Binding<Bool> { Binding(get: { hover.cardHash == commit.hash }, set: { if !$0 && hover.cardHash == commit.hash { hover.cardHash = nil } }) }
    var selected: Bool { store.selectedCommit?.hash == commit.hash }
    var graphColumnWidth: CGFloat { CGFloat(graphWidth * 18 + 12) }
    var body: some View {
        HStack(spacing: 12) {
            CommitGraphCell(row: graph, selected: selected, hovering: hovering)
                .frame(width: graphColumnWidth, height: 57)
                // Only the hovered row carries a popover: one per row added an AppKit anchor to every visible row.
                .overlay { if hover.cardHash == commit.hash { Color.clear.popover(isPresented: showCard, arrowEdge: .trailing) { BranchHoverCard(store: store, commit: commit, branch: branch, locals: locals) } } }
            HStack(spacing: 12) {
                AuthorAvatar(name: commit.author, size: 24, tooltip: false)
                VStack(alignment: .leading, spacing: 5) {
                    Text(commit.subject).font(.ui(size: 12, weight: selected ? .semibold : .medium)).lineLimit(1)
                    HStack(spacing: 5) {
                        if let mark = store.syncMarks[commit.hash] { SyncChip(mark: mark) }
                        ForEach(CommitReference.parse(commit.refs, localBranches: locals).prefix(4)) { ReferenceChip(reference: $0) }
                        Text(commit.author).font(.ui(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 10)
                VStack(alignment: .trailing, spacing: 6) { Text(commit.shortHash).font(.ui(size: 10, design: .monospaced)).foregroundStyle(Brand.accent); Text(RelativeDateCache.shared.text(for: commit.date)).font(.ui(size: 9)).foregroundStyle(.tertiary).lineLimit(1) }
            }
        }
        .padding(.horizontal, 16).frame(height: 57).contentShape(Rectangle())
        .background {
            ZStack(alignment: .leading) {
                if selected { Brand.accent.opacity(0.10); Rectangle().fill(Brand.accent).frame(width: 3).transition(.move(edge: .leading)) }
                else if hovering { Color.primary.opacity(0.045) }
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(.separator.opacity(0.5)).frame(height: 0.5).padding(.leading, graphColumnWidth + 28) }
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { store.selectedCommit = commit } }
        .onTapGesture(count: 2) { store.selectedCommit = commit; store.showInspector = true }
        .animation(.snappy(duration: 0.2), value: selected)
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("commit.\(commit.shortHash)")
        .accessibilityHint(branch.map { "\(L("branchLabel")): \($0)" } ?? "")
        .accessibilityAction { store.selectedCommit = commit }
        .accessibilityAction(named: L("commitDetails")) { store.selectedCommit = commit; store.showInspector = true }
        .accessibilityAction(named: L("copyHash")) { store.copyToPasteboard(commit.hash) }
        .accessibilityAction(named: L("viewCommit")) { store.showCommit(commit.hash, title: commit.subject) }
        // Menu content lives in its own view so it is built when opened, not for every row that scrolls in.
        .contextMenu { CommitContextMenu(store: store, commit: commit) }
    }
}
/// Hover card for a graph node: the branch whose first-parent chain contains the commit, plus its tracking state.
struct BranchHoverCard: View {
    let store: WorkspaceStore
    let commit: GitCommit
    let branch: String?
    let locals: Set<String>
    var body: some View {
        let info = store.repository?.branches.first { $0.name == branch }
        let refs = CommitReference.parse(commit.refs, localBranches: locals)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: store.isProtected(branch ?? "") ? "lock.fill" : "arrow.triangle.branch").foregroundStyle(Brand.accent)
                Text(branch ?? L("unlabeledLane")).font(.ui(size: 13, weight: .semibold)).lineLimit(1)
                if info?.current == true { Text(L("current")).font(.ui(size: 9, weight: .semibold)).foregroundStyle(Brand.accent).padding(.horizontal, 6).padding(.vertical, 2).background(Brand.accent.opacity(0.14), in: Capsule()) }
            }
            if let upstream = info?.upstream, !upstream.isEmpty { Label(upstream, systemImage: "network").font(.uiCaption).foregroundStyle(.secondary) }
            if !refs.isEmpty { FlowChips(references: refs) }
            Divider()
            HStack(alignment: .top, spacing: 10) {
                AuthorAvatar(name: commit.author, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(commit.subject).font(.ui(size: 12, weight: .medium)).lineLimit(3)
                    Text("\(commit.author) · \(commit.date.formatted(date: .abbreviated, time: .shortened))").font(.uiCaption).foregroundStyle(.secondary)
                    Text(commit.parents.count > 1 ? "\(commit.shortHash) · \(L("mergeCommit"))" : commit.shortHash).font(.ui(size: 10, design: .monospaced)).foregroundStyle(Brand.accent)
                }
            }
        }.padding(14).frame(width: 300, alignment: .leading)
    }
}
private struct FlowChips: View {
    let references: [CommitReference]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) { ForEach(references) { ReferenceChip(reference: $0) } }
    }
}
struct ReferenceChip: View {
    let reference: CommitReference
    var body: some View {
        let (icon, color): (String, Color) = switch reference.kind {
        case .head: ("location.fill", Brand.accent)
        case .branch: ("arrow.triangle.branch", Brand.accent)
        case .remote: ("network", Brand.info)
        case .tag: ("tag.fill", Brand.warning)
        }
        Label(reference.name, systemImage: icon).labelStyle(ChipLabelStyle())
            .font(.ui(size: 9, weight: reference.kind == .head ? .bold : .medium)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(reference.kind == .head ? 0.18 : 0.10), in: Capsule())
            .overlay { if reference.kind == .head { Capsule().strokeBorder(color.opacity(0.5), lineWidth: 0.5) } }
            .lineLimit(1).fixedSize()
    }
}
private struct ChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { HStack(spacing: 3) { configuration.icon.font(.ui(size: 7)); configuration.title } }
}
struct AuthorAvatar: View {
    let name: String
    var size: CGFloat = 24
    /// Off in long lists: each `.help` installs an AppKit tooltip view per row and makes scrolling stutter.
    var tooltip = true
    var initials: String { name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
    var color: Color {
        let hash = name.unicodeScalars.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1.value) }
        return Brand.graph[abs(hash) % Brand.graph.count]
    }
    var body: some View {
        Text(initials.isEmpty ? "?" : initials).font(.ui(size: size * 0.38, weight: .semibold, design: .rounded)).foregroundStyle(color)
            .frame(width: size, height: size).background(color.opacity(0.16), in: Circle())
            .overlay(Circle().strokeBorder(color.opacity(0.35), lineWidth: 0.5))
            .help(tooltip ? name : "").accessibilityHidden(true)
    }
}
struct CommitGraphCell: View {
    let row: GraphRow
    var selected = false
    var hovering = false
    var body: some View {
        Canvas { context, size in
            let center = size.height / 2
            func x(_ lane: Int) -> CGFloat { CGFloat(lane * 18 + 8) }
            func color(_ lane: Int) -> Color { Brand.graph[lane % Brand.graph.count] }
            let width: CGFloat = 2
            for lane in row.incoming {
                var path = Path(); path.move(to: CGPoint(x: x(lane), y: -0.5)); path.addLine(to: CGPoint(x: x(lane), y: center))
                context.stroke(path, with: .color(color(lane).opacity(0.85)), style: StrokeStyle(lineWidth: width, lineCap: .butt))
            }
            for segment in row.outgoing {
                var path = Path(); path.move(to: CGPoint(x: x(segment.from), y: center))
                if segment.from == segment.to { path.addLine(to: CGPoint(x: x(segment.to), y: size.height + 0.5)) }
                else { path.addCurve(to: CGPoint(x: x(segment.to), y: size.height + 0.5), control1: CGPoint(x: x(segment.from), y: size.height * 0.85), control2: CGPoint(x: x(segment.to), y: size.height * 0.7)) }
                context.stroke(path, with: .color(color(segment.to).opacity(0.85)), style: StrokeStyle(lineWidth: width, lineCap: .butt))
            }
            let radius: CGFloat = selected ? 5.5 : hovering ? 5 : 4
            let node = CGRect(x: x(row.column) - radius, y: center - radius, width: radius * 2, height: radius * 2)
            if selected || hovering {
                let halo = node.insetBy(dx: -4, dy: -4)
                context.fill(Path(ellipseIn: halo), with: .color(color(row.column).opacity(selected ? 0.25 : 0.15)))
            }
            context.fill(Path(ellipseIn: node), with: .color(color(row.column)))
            if selected { context.stroke(Path(ellipseIn: node.insetBy(dx: 1.6, dy: 1.6)), with: .color(.white.opacity(0.9)), lineWidth: 1.2) }
        }
        .animation(.snappy(duration: 0.2), value: selected)
        .accessibilityHidden(true)
    }
}
struct CommitInspector: View {
    @Bindable var store: WorkspaceStore
    @State private var files: [CommitFileChange] = []
    @State private var body_ = ""
    @State private var viewing: CommitFileChange?
    @State private var fileLimit = 100
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text(L("commitDetails")).font(.uiHeadline); Spacer(); InspectorCloseButton(store: store) }
                if let commit = store.selectedCommit {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .top, spacing: 10) {
                            AuthorAvatar(name: commit.author, size: 34)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(commit.subject).font(.ui(size: 15, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Text("\(commit.author) · \(commit.date.formatted(.relative(presentation: .named)))").font(.uiCaption).foregroundStyle(.secondary)
                            }
                        }
                        if !body_.isEmpty { Text(body_).font(.ui(size: 11)).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8)) }
                        HStack { Text(commit.hash).font(.ui(size: 10, design: .monospaced)).foregroundStyle(Brand.accent).lineLimit(1).truncationMode(.middle); Spacer(); CopyIconButton(store: store, text: commit.hash, help: L("copyHash")) }
                        let refs = CommitReference.parse(commit.refs, localBranches: store.refs.localBranches)
                        if !refs.isEmpty { HStack(spacing: 4) { ForEach(refs.prefix(5)) { ref in Button { store.search = ref.name } label: { ReferenceChip(reference: ref) }.buttonStyle(.plain).help(L("filterHistory")) } } }
                        CommitActions(store: store, commit: commit)
                        Divider()
                        VStack(alignment: .leading, spacing: 14) {
                            InspectorField(label: L("date"), value: commit.date.formatted(date: .abbreviated, time: .shortened))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(L("parents")).font(.uiCaption2).foregroundStyle(.secondary)
                                if commit.parents.isEmpty { Text(L("rootCommit")).font(.ui(size: 11)) }
                                HStack(spacing: 6) { ForEach(commit.parents, id: \.self) { parent in Button { store.selectCommit(hash: parent) } label: { Label(String(parent.prefix(7)), systemImage: "arrow.down.right").font(.ui(size: 10, design: .monospaced)) }.buttonStyle(.link).help(L("goToParent")).accessibilityLabel("\(L("goToParent")) \(parent.prefix(7))").accessibilityIdentifier("inspector.parent.\(parent.prefix(7))") } }
                            }
                        }
                        Divider()
                        HStack {
                            Label(L("files"), systemImage: "doc.on.doc").font(.uiCaption.weight(.semibold))
                            Spacer()
                            let adds = files.compactMap(\.stats.additions).reduce(0, +), dels = files.compactMap(\.stats.deletions).reduce(0, +)
                            if !files.isEmpty { StatsBadge(stats: LineStats(additions: adds, deletions: dels)) }
                        }
                        if files.isEmpty { Text("—").foregroundStyle(.secondary) }
                        // Big commits (template imports, vendored code) can touch thousands of files: building a row for
                        // each one exhausted SwiftUI's graph and crashed the app. Show them in pages.
                        LazyVStack(spacing: 2) {
                            ForEach(files.prefix(fileLimit)) { file in CommitFileRow(file: file) { viewing = file } }
                        }
                        if files.count > fileLimit {
                            Button { fileLimit += 400 } label: {
                                Label(String(format: L("showMoreFiles"), min(400, files.count - fileLimit), files.count - fileLimit), systemImage: "chevron.down.circle")
                                    .font(.ui(size: 11, weight: .medium)).frame(maxWidth: .infinity)
                            }.buttonStyle(.borderless).padding(.vertical, 4).accessibilityIdentifier("inspector.moreFiles")
                        }
                        Divider()
                        VStack(spacing: 6) {
                            Button { store.compareWithHead(commit) } label: { Label(commit.hash == store.refs.headHash ? L("compareWorking") : L("compare"), systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity) }.accessibilityIdentifier("inspector.compare")
                                .help(commit.hash == store.refs.headHash ? L("compareWorkingHelp") : L("compareHelp"))
                            Button { store.showCommit(commit.hash, title: commit.subject) } label: { Label(L("viewCommit"), systemImage: "doc.text.magnifyingglass").frame(maxWidth: .infinity) }.accessibilityIdentifier("inspector.viewCommit")
                        }.controlSize(.regular)
                    }
                    .id(commit.hash)
                    .transition(.opacity.combined(with: .offset(x: 10)))
                } else { ContentUnavailableView(L("noSelection"), systemImage: "point.3.connected.trianglepath.dotted", description: Text(L("selectCommit"))) }
            }.padding(20)
            .animation(.smooth(duration: 0.22), value: store.selectedCommit?.hash)
        }.background(Brand.surface)
        .onChange(of: viewing?.id) { _, _ in
            guard let file = viewing, let commit = store.selectedCommit else { return }
            store.showDiff(file.path, subtitle: "\(commit.shortHash) · \(commit.subject)", args: ["show", "--format=", "--no-ext-diff", "--no-textconv", "--no-color", "--diff-merges=first-parent", commit.hash, "--", file.path])
            viewing = nil
        }
        .task(id: store.selectedCommit?.hash) {
            fileLimit = 100
            guard let root = store.repository?.root, let hash = store.selectedCommit?.hash else { files = []; body_ = ""; return }
            do {
                async let status = store.engine.query(root, ["show", "--format=", "--name-status", "-z", "--no-renames", "--diff-merges=first-parent", hash])
                async let numstat = store.engine.query(root, ["show", "--format=", "--numstat", "-z", "--no-renames", "--diff-merges=first-parent", hash])
                async let message = store.engine.query(root, ["show", "-s", "--format=%b", hash])
                files = CommitFileChange.parse(status: try await status, numstat: try await numstat)
                body_ = try await message.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch { files = []; body_ = error.localizedDescription }
        }
    }
}
struct CommitFileChange: Identifiable, Hashable {
    var path: String; var status: String; var stats: LineStats
    var id: String { path }
    static func == (a: Self, b: Self) -> Bool { a.path == b.path && a.status == b.status }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }
    /// `--name-status -z` yields `S\0path\0` pairs; numstat supplies line counts.
    static func parse(status: String, numstat: String) -> [CommitFileChange] {
        let stats = Dictionary(LineStats.parseNumstat(numstat).map { ($0.path, $0.stats) }, uniquingKeysWith: { a, _ in a })
        let parts = status.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        return stride(from: 0, to: parts.count - 1, by: 2).map { index in
            let code = String(parts[index].trimmingCharacters(in: .whitespacesAndNewlines).prefix(1))
            let path = parts[index + 1]
            return CommitFileChange(path: path, status: code, stats: stats[path] ?? LineStats())
        }
    }
}
private struct CommitFileRow: View {
    let file: CommitFileChange; let action: () -> Void
    @State private var hovering = false
    var kind: ChangeKind { switch file.status.prefix(1) { case "A": .added; case "D": .deleted; case "R", "C": .renamed; case "U": .conflict; default: .modified } }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                FileTypeIcon(path: file.path, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text((file.path as NSString).lastPathComponent).font(.ui(size: 11, weight: .medium)).lineLimit(1)
                    let directory = (file.path as NSString).deletingLastPathComponent
                    if !directory.isEmpty { Text(directory).font(.ui(size: 9)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
                Spacer(minLength: 4)
                ChangeKindBadge(kind: kind, compact: true)
                StatsBadge(stats: file.stats)
                Image(systemName: "chevron.right").font(.ui(size: 9, weight: .semibold)).foregroundStyle(.tertiary).opacity(hovering ? 1 : 0)
            }.padding(.horizontal, 6).padding(.vertical, 5).contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(file.path)
        .onHover { hover in withAnimation(.easeOut(duration: 0.12)) { hovering = hover } }
    }
}
struct StatsBadge: View {
    let stats: LineStats
    /// On a selected (accent) row the green/red figures become white to stay legible.
    var inverted = false
    var body: some View {
        HStack(spacing: 4) {
            if stats.binary { Text(L("binary")).foregroundStyle(.secondary) }
            else {
                // No numeric transition or tooltip: this badge sits in every changed-file row and its numbers move
                // with each write of an agent; animated digits are rasterized on the main thread.
                if let additions = stats.additions, additions > 0 { Text("+\(additions)").foregroundStyle(inverted ? Color.white : Brand.addition) }
                if let deletions = stats.deletions, deletions > 0 { Text("−\(deletions)").foregroundStyle(inverted ? Color.white.opacity(0.85) : Brand.danger) }
            }
        }.font(.ui(size: 9, weight: .semibold, design: .monospaced)).fixedSize()
        .accessibilityElement(children: .ignore).accessibilityLabel(description)
    }
    private var description: String { stats.binary ? L("binary") : String(format: L("linesChanged"), stats.additions ?? 0, stats.deletions ?? 0) }
}
private struct CommitActions: View {
    let store: WorkspaceStore; let commit: GitCommit
    @State private var branchName = ""
    @State private var naming = false
    @State private var copied = false
    var body: some View {
        let inHead = store.refs.reachableFromHead.contains(commit.hash)
        let isHead = commit.hash == store.refs.headHash
        let isMerge = commit.parents.count > 1
        let readOnly = !store.canWrite
        VStack(alignment: .leading, spacing: 6) {
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    ActionTile(id: "inspector.copyHash", icon: copied ? "checkmark" : "doc.on.doc", title: copied ? L("copiedShort") : L("copyHash"), help: L("copyHash"), highlighted: copied) {
                        store.copyToPasteboard(commit.hash)
                        withAnimation(.snappy) { copied = true }
                        Task { try? await Task.sleep(for: .seconds(1.6)); withAnimation(.easeOut) { copied = false } }
                    }
                    ActionTile(id: "inspector.branchHere", icon: "arrow.triangle.branch", title: L("branchHere"), help: readOnly ? L("actionReadOnly") : L("branchHereHelp")) { naming = true }.disabled(readOnly)
                }
                GridRow {
                    ActionTile(id: "inspector.revert", icon: "arrow.uturn.left", title: L("revert"), help: readOnly ? L("actionReadOnly") : !inHead ? L("revertNotInHead") : isMerge ? L("revertMerge") : L("revertHelp")) { store.action("revert", value: commit.hash, confirm: true) }.disabled(readOnly || !inHead || isMerge)
                    ActionTile(id: "inspector.cherryPick", icon: "arrow.right.doc.on.clipboard", title: L("cherry_pick"), help: readOnly ? L("actionReadOnly") : inHead ? L("cherryPickInHead") : L("cherryPickHelp")) { store.action("cherry_pick", value: commit.hash, confirm: true) }.disabled(readOnly || inHead)
                }
            }
            if isHead { Label(L("isHeadNote"), systemImage: "location.fill").font(.uiCaption2).foregroundStyle(.secondary) }
            else if inHead { Label(L("inHeadNote"), systemImage: "checkmark.circle").font(.uiCaption2).foregroundStyle(.secondary) }
            else { Label(L("notInHeadNote"), systemImage: "arrow.triangle.branch").font(.uiCaption2).foregroundStyle(.secondary) }
            if store.onProtectedMain { Label(L("editorProtected"), systemImage: "lock").font(.uiCaption2).foregroundStyle(Brand.warning) }
        }
        .popover(isPresented: $naming, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("branchHere")).font(.uiHeadline)
                Text("\(L("startPoint")): \(commit.shortHash)").font(.uiCaption).foregroundStyle(.secondary)
                TextField(L("branchName"), text: $branchName).textFieldStyle(.roundedBorder).frame(width: 240).onSubmit(create)
                HStack { Spacer(); Button(L("cancel")) { naming = false }; Button(L("create"), action: create).buttonStyle(.borderedProminent).disabled(branchName.trimmingCharacters(in: .whitespaces).isEmpty) }
            }.padding(14)
        }
    }
    private func create() {
        let name = branchName.trimmingCharacters(in: .whitespaces); guard !name.isEmpty else { return }
        naming = false; branchName = ""
        Task { await store.prepare("branch", arguments: "\(shellQuote(name)) \(commit.hash)") }
    }
}
/// Labeled action: icon-only chips were ambiguous and looked inert when an action did not apply.
private struct ActionTile: View {
    let id: String; let icon: String; let title: String; let help: String; var highlighted = false; let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.ui(size: 11, weight: .medium)).frame(width: 14).contentTransition(.symbolEffect(.replace))
                Text(title).font(.ui(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).frame(maxWidth: .infinity, minHeight: 28)
            .foregroundStyle(!enabled ? Color.secondary.opacity(0.5) : hovering || highlighted ? Brand.accent : .primary)
            .background(hovering && enabled ? Brand.accent.opacity(0.13) : Color.primary.opacity(enabled ? 0.06 : 0.03), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(title).accessibilityHint(help).accessibilityIdentifier(id)
        .onHover { hover in withAnimation(.easeOut(duration: 0.12)) { hovering = hover } }
    }
}
private struct InspectorField: View {
    let label: String; let value: String
    var body: some View { VStack(alignment: .leading, spacing: 5) { Text(label).font(.uiCaption2).foregroundStyle(.secondary); Text(value.isEmpty ? "—" : value).font(.ui(size: 11)).textSelection(.enabled) } }
}

/// Close control with an explicit hit area; a bare plain-style glyph was too easy to miss.
struct InspectorCloseButton: View {
    let store: WorkspaceStore
    @State private var hovering = false
    var body: some View {
        Button { withAnimation(.smooth(duration: 0.25)) { store.showInspector = false } } label: {
            Image(systemName: "xmark").font(.ui(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 26, height: 26)
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.borderless).help(L("close")).accessibilityLabel(L("close")).accessibilityIdentifier("inspector.close")
        .onHover { hover in withAnimation(.easeOut(duration: 0.12)) { hovering = hover } }
    }
}
/// Copy control that confirms in place, where the user is looking.
struct CopyIconButton: View {
    let store: WorkspaceStore; let text: String; let help: String; var id = "inspector.copyHashIcon"
    @State private var copied = false
    @State private var hovering = false
    var body: some View {
        Button {
            store.copyToPasteboard(text)
            withAnimation(.snappy) { copied = true }
            Task { try? await Task.sleep(for: .seconds(1.6)); withAnimation(.easeOut) { copied = false } }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.ui(size: 12, weight: .medium))
                .foregroundStyle(copied ? Brand.accent : hovering ? Color.primary : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 26)
                .background(hovering || copied ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.borderless).help(help).accessibilityLabel(help).accessibilityIdentifier(id)
        .onHover { hover in withAnimation(.easeOut(duration: 0.12)) { hovering = hover } }
    }
}

/// Membership badge: exclusive to main, exclusive to develop, or already copied to both.
struct SyncChip: View {
    let mark: SyncMark
    var body: some View {
        let (text, icon, color): (String, String, Color) = switch mark {
        case .onlyPrimary(let branch): (String(format: L("onlyBranch"), branch), "arrow.up.circle", Brand.info)
        case .onlyOther(let branch): (String(format: L("onlyBranch"), branch), "arrow.down.circle", Brand.warning)
        case .copied: (L("inBoth"), "checkmark.circle", .secondary)
        }
        Label(text, systemImage: icon).labelStyle(SyncChipStyle())
            .font(.ui(size: 9, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.35), style: StrokeStyle(lineWidth: 0.5, dash: mark == .copied ? [2] : [])))
            .fixedSize().help(L("syncChipHelp"))
    }
}
struct SyncChipStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { HStack(spacing: 3) { configuration.icon.font(.ui(size: 8)); configuration.title } }
}

private struct CommitContextMenu: View {
    let store: WorkspaceStore
    let commit: GitCommit
    var body: some View {
            Button(L("copyHash")) { store.copyToPasteboard(commit.hash) }
            Button(L("copySubject")) { store.copyToPasteboard(commit.subject) }
            Button(L("viewCommit")) { store.showCommit(commit.hash, title: commit.subject) }
            Button(commit.hash == store.refs.headHash ? L("compareWorking") : L("compare")) { store.compareWithHead(commit) }
            Divider()
            let inHead = store.refs.reachableFromHead.contains(commit.hash)
            Button(L("cherry_pick")) { store.action("cherry_pick", value: commit.hash, confirm: true) }.disabled(!store.canWrite || inHead)
            Button(L("revert")) { store.action("revert", value: commit.hash, confirm: true) }.disabled(!store.canWrite || !inHead || commit.parents.count > 1)
            Menu("Reset") { ForEach(["soft", "mixed", "hard"], id: \.self) { mode in Button("Reset --\(mode)…") { Task { await store.prepare("reset", arguments: "--\(mode) \(commit.hash)") } }.disabled(!store.canWrite) } }
            Button(L("organizeMenu")) { store.organizing = true }.disabled(!store.canWrite)
            Button(L("interactiveRebaseFrom")) { Task { await store.prepare("rebase", arguments: "--interactive \(commit.hash)", interactive: true) } }.disabled(!store.canWrite)
    }
}

/// Relative dates ("hace 3 sem.") are costly to format; rows share one cached string per minute of age.
@MainActor final class RelativeDateCache {
    static let shared = RelativeDateCache()
    private var cache: [Int: String] = [:]
    private var anchor = Date()
    private let formatter: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; f.dateTimeStyle = .numeric; return f }()
    func text(for date: Date) -> String {
        if Date().timeIntervalSince(anchor) > 60 { cache.removeAll(keepingCapacity: true); anchor = Date() }
        let key = Int(date.timeIntervalSince1970 / 60)
        if let value = cache[key] { return value }
        let value = formatter.localizedString(for: date, relativeTo: anchor)
        cache[key] = value
        return value
    }
}

extension ChangeKind {
    var color: Color {
        switch self { case .added: Brand.addition; case .modified: Brand.info; case .deleted: Brand.danger; case .renamed: Brand.special; case .conflict: Brand.warning }
    }
}
/// "Nuevo", "Eliminado", "Movido"… as a compact capsule (or icon only).
struct ChangeKindBadge: View {
    let kind: ChangeKind
    var compact = false
    var body: some View {
        Group {
            if compact { Image(systemName: kind.icon).font(.ui(size: 11)).foregroundStyle(kind.color) }
            else {
                Label(kind.title, systemImage: kind.icon).labelStyle(SyncChipStyle())
                    .font(.ui(size: 9, weight: .semibold)).foregroundStyle(kind.color)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(kind.color.opacity(0.13), in: Capsule())
            }
        }
        .help(kind.title).accessibilityLabel(kind.title).fixedSize()
    }
}

extension View {
    /// Animated digits only for small counts. Counters driven by an agent's writes change several times per second
    /// with thousands of files; their transitions were rasterized on the main thread and made the app stutter.
    @ViewBuilder func countTransition(_ count: Int) -> some View {
        if count < WorkspaceStore.animationLimit { contentTransition(.numericText(value: Double(count))).animation(.snappy, value: count) }
        else { contentTransition(.identity) }
    }
}
