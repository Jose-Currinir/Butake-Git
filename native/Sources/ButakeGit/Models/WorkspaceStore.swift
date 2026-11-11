import SwiftUI
import AppKit
import Observation
import QuartzCore

@MainActor @Observable final class WorkspaceStore {
    let engine = GitEngine()
    let catalog = CatalogStore()
    /// The snapshot is stored outside Observation so a files-only refresh can update it without notifying every
    /// view that reads `repository` (sidebar, toolbar, history…): during an agent's burst that re-rendered the whole
    /// window each time (~70 ms). Views that show files observe `files` and `changes` instead.
    @ObservationIgnored private var storedRepository: RepositorySnapshot?
    var repository: RepositorySnapshot? {
        get { access(keyPath: \.repository); return storedRepository }
        set {
            let changed = newValue != storedRepository
            withMutation(keyPath: \.repository) { storedRepository = newValue }
            if changed { revision &+= 1; applyDerived(newValue) }
        }
    }
    /// Changed files of the current snapshot (observed separately from `repository`).
    private(set) var files: [ChangedFile] = []
    private(set) var refs = RefIndex()
    private func applyDerived(_ snapshot: RepositorySnapshot?) {
        if files != (snapshot?.files ?? []) { files = snapshot?.files ?? [] }
        changes = snapshot.map(ChangeIndex.init) ?? ChangeIndex(); filesRevision &+= 1
        refreshChangeTree()
        let nextRefs = RefIndex(headHash: changes.headHash, reachableFromHead: changes.reachableFromHead, localBranches: changes.localBranches)
        if nextRefs != refs { refs = nextRefs }
    }
    /// True when `next` differs from the current snapshot only in its changed files.
    private func onlyFilesDiffer(_ next: RepositorySnapshot) -> Bool {
        guard var probe = storedRepository else { return false }
        probe.files = next.files
        return probe == next
    }
    /// Cached derivations of `repository`; read these from views instead of recomputing.
    private(set) var changes = ChangeIndex()
    @ObservationIgnored private var revision = 0
    /// Bumped whenever the changed files change (including file-only refreshes); keys the file-derived caches.
    @ObservationIgnored private var filesRevision = 0
    @ObservationIgnored private var statsRevision = 0
    @ObservationIgnored private var historyCache: (key: String, model: HistoryModel)?
    @ObservationIgnored private var refreshInFlight = false
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var scheduledRefresh: Task<Void, Never>?
    /// Grows while filesystem-triggered refreshes find nothing new (e.g. logs written by a dev server).
    @ObservationIgnored private var idleDelay: Duration = .milliseconds(300)
    @ObservationIgnored private var lastRefreshChanged = true
    @ObservationIgnored private var autoFetchTask: Task<Void, Never>?
    var lastFetch: Date?
    @ObservationIgnored private var statsInFlight = false
    @ObservationIgnored private var statsDirty = false
    @ObservationIgnored var watcher: RepositoryWatcher?
    /// Above this many rows, list diffs are applied without animation to keep updates instant.
    static let animationLimit = 250
    /// Branch sheets requested from anywhere (sidebar, Branches): new branch and rename.
    var creatingBranch = false
    var cloningRepository = false
    var creatingRepository = false
    var publishingRepository = false
    var renamingBranch: String?
    var route: WorkspaceRoute = .history { didSet { if route != oldValue { autoSelectFile(); if route.isChanges { lastChangesRoute = route }; refreshChangeTree() } } }
    /// Last way of viewing Changes (list or review); the sidebar item reopens it.
    @ObservationIgnored var lastChangesRoute: WorkspaceRoute = UserDefaults.standard.string(forKey: "changesView") == WorkspaceRoute.review.rawValue ? .review : .changes {
        didSet { UserDefaults.standard.set(lastChangesRoute.rawValue, forKey: "changesView") }
    }
    /// Entering Changes or Review with nothing selected opens the first relevant diff instead of an empty pane.
    func autoSelectFile() {
        guard selectedFile == nil, route == .changes || route == .review else { return }
        if route == .review, let file = files.sorted(by: { $0.path < $1.path }).first(where: { !isReviewed($0) && !$0.conflict }) { reviewSelect(file); return }
        if let file = changes.unstaged.first(where: { !$0.conflict }) { selectFile(file, staged: false) }
        else if let file = changes.staged.first { selectFile(file, staged: true) }
    }
    var busy = false
    var terminalActive = false
    var status = L("ready")
    var errorMessage: String?
    var selectedCommit: GitCommit?
    var selectedFile: ChangedFile?
    var stagedSelection = false
    var diff = ""
    var message = ""
    var search = "" { didSet { if search != oldValue { refreshChangeTree() } } }
    var showInspector = true
    var pending: PendingOperation?
    var terminalLaunch: TerminalLaunch?
    var consoleCommand = "status"
    var consoleArguments = "--short --branch"
    var consolePlan: RebasePlan?
    var capabilities: GitCapabilities?
    var recent: [String] = UserDefaults.standard.stringArray(forKey: "recentRepositories") ?? []
    var toast: Toast?
    var diffRequest: DiffRequest?
    var pullProblem: PullProblem?
    var organizing = false
    /// Reviewer state: path -> content fingerprint at the time it was marked reviewed.
    var reviewed: [String: String] = [:] { didSet { scheduleReviewSave(); updateReviewedCount() } }
    /// path -> "status|size|mtime", recomputed on every refresh so further edits by an agent reset the mark.
    private(set) var fingerprints: [String: String] = [:]
    @ObservationIgnored private var reviewSaveTask: Task<Void, Never>?
    @ObservationIgnored private var reviewLoadedRoot: String?
    @ObservationIgnored private var reviewCache: (key: String, nodes: [ChangeNode], files: [ChangedFile])?
    /// Backup of the last guided rewrite in this session, offered as "Deshacer".
    var lastRewrite: (backup: String, branch: String)?
    /// main/develop membership for history badges; loaded after each snapshot change.
    var syncMarks: [String: SyncMark] = [:]
    @ObservationIgnored private var syncMarksKey = ""
    var resolving: ChangedFile?
    var runningAction: String?
    var historyLimit = WorkspaceStore.historyPage
    var loadingHistory = false
    var fileStats: [String: LineStats] = [:]
    @ObservationIgnored private var lastStatsLoad = Date.distantPast
    /// One observable cell per file and side. Rows read their own cell instead of `fileStats`: a row depending on
    /// the whole dictionary made SwiftUI compare thousands of entries per visible row on every stats reload.
    @ObservationIgnored private var statBoxes: [String: StatBox] = [:]
    func statBox(_ file: ChangedFile, staged: Bool) -> StatBox {
        let key = LineStats.key(file.path, staged: staged)
        if let box = statBoxes[key] { return box }
        let box = StatBox(value: fileStats[key]); statBoxes[key] = box
        return box
    }
    @ObservationIgnored private var statsRetry: Task<Void, Never>?
    static let historyPage = 180
    private var toastTask: Task<Void, Never>?
    private var diffGeneration = UUID()
    private var accessing: [String: URL] = [:]
    var canWrite: Bool { !busy && !terminalActive && !onProtectedMain && repository != nil }
    /// Fast-forward pulls are allowed on protected main: they only bring the remote state, never local commits.
    var canPull: Bool { !busy && !terminalActive && repository?.hasRemote == true }
    var canFetch: Bool { !busy && !terminalActive && repository?.hasRemote == true }
    var canPush: Bool { canWrite && repository?.hasRemote == true }
    /// Tooltip for remote actions: explains why they are unavailable in a local-only repository.
    func remoteHelp(_ key: String) -> String { repository?.hasRemote == false ? L("noRemoteHelp") : L(key) }
    /// Only `main` can be protected, and only when this repository protects it.
    func isProtected(_ branch: String) -> Bool { branch == (repository?.primary ?? "main") && repository?.mainProtected == true }
    // MARK: Branches
    /// Owners/workspaces seen in the origin of recent repositories (e.g. a team workspace), for providers whose
    /// token cannot list workspaces.
    func knownOwners(_ provider: HostingProvider) async -> [String] {
        var owners: [String] = []
        for root in [repository?.root].compactMap({ $0 }) + recent where FileManager.default.fileExists(atPath: root) {
            guard let url = try? await engine.query(root, ["config", "--get", "remote.origin.url"]),
                  let hosted = try? HostedRepository(remote: url), hosted.provider == provider, !owners.contains(hosted.owner) else { continue }
            owners.append(hosted.owner)
        }
        return owners
    }
    func trackBranch(_ remote: RemoteBranch) { action("track_branch", value: remote.name) }
    func renameBranch(_ old: String, to new: String) { action("rename_branch", value: "\(old):\(new)") }
    func deleteBranch(_ name: String, force: Bool = false) {
        guard let root = repository?.root, !busy, !terminalActive else { return }
        pending = PendingOperation(title: L(force ? "forceDeleteBranch" : "deleteBranch"), root: root, action: force ? "force_delete_branch" : "delete_branch", value: name, preview: "git branch \(force ? "-D" : "-d") \(shellQuote(name))", destructive: true, detail: String(format: L(force ? "forceDeleteBranchDetail" : "deleteBranchDetail"), name))
    }
    func deleteRemoteBranch(_ remote: RemoteBranch) {
        guard let root = repository?.root, !busy, !terminalActive else { return }
        pending = PendingOperation(title: L("deleteRemoteBranch"), root: root, action: "delete_remote_branch", value: remote.name, preview: "git push \(shellQuote(remote.remote)) --delete \(shellQuote(remote.short))", destructive: true, detail: String(format: L("deleteRemoteBranchDetail"), remote.short, remote.remote))
    }
    var onProtectedMain: Bool { isProtected(repository?.branch ?? "") }
    func setMainProtection(_ value: String) {
        guard let root = repository?.root else { return }
        Task {
            do {
                let _: String = try await engine.call(["method": "setMainProtection", "path": root, "value": value, "confirmed": true])
                await refresh()
                notify(L(onProtectedMain || repository?.mainProtected == true ? "mainNowProtected" : "mainNowFree"), icon: repository?.mainProtected == true ? "lock.fill" : "lock.open.fill")
            } catch { fail(error) }
        }
    }
    var title: String { repository?.name ?? "Git" }
    var canLoadMoreHistory: Bool { (repository?.commits.count ?? 0) >= historyLimit }
    func stats(for file: ChangedFile, staged: Bool) -> LineStats? { fileStats[LineStats.key(file.path, staged: staged)] }

    func chooseRepository() { chooseRepository(at: nil) }
    private func chooseRepository(at suggested: String?) {
        guard !busy && !terminalActive else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.title = L("openRepository"); panel.prompt = L("open")
        if let suggested { panel.directoryURL = URL(fileURLWithPath: suggested) }
        if panel.runModal() == .OK, let url = panel.url { rememberAccess(url); Task { await open(url.path) } }
    }
    func reopenRecent(_ path: String) {
        let bookmarks = UserDefaults.standard.dictionary(forKey: "repositoryBookmarks") as? [String: Data] ?? [:]
        if bookmarks[path] != nil { Task { await open(path) } }
        else { chooseRepository(at: path) }
    }
    private func rememberAccess(_ url: URL) {
        if accessing[url.path] == nil, url.startAccessingSecurityScopedResource() { accessing[url.path] = url }
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            var bookmarks = UserDefaults.standard.dictionary(forKey: "repositoryBookmarks") as? [String: Data] ?? [:]
            bookmarks[url.path] = data; UserDefaults.standard.set(bookmarks, forKey: "repositoryBookmarks")
        }
    }
    private func restoreAccess(_ path: String) {
        guard accessing[path] == nil, let data = (UserDefaults.standard.dictionary(forKey: "repositoryBookmarks") as? [String: Data])?[path] else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) { rememberAccess(url) }
    }
    /// QA builds never touch the user's recent list, even when launched without a QA script.
    static var recordsRecents: Bool {
        #if BUTAKE_QA || DEBUG
        return false
        #else
        return ProcessInfo.processInfo.environment["BUTAKE_QA_ACTIONS"] == nil
        #endif
    }
    func open(_ path: String) async {
        guard !busy && !terminalActive else { return }
        busy = true; defer { busy = false }
        restoreAccess(path)
        do {
            historyLimit = WorkspaceStore.historyPage
            let result: RepositorySnapshot = try await engine.call(["method": "open", "path": path, "limit": historyLimit])
            repository = result
            startWatching(result.root)
            selectedFile = nil; selectedCommit = result.commits.first; diff = ""; message = ""
            // QA runs share this app's preferences; they must not alter the user's recent list.
            if WorkspaceStore.recordsRecents {
                recent.removeAll { $0 == result.root }; recent.insert(result.root, at: 0); recent = Array(recent.prefix(12))
                UserDefaults.standard.set(recent, forKey: "recentRepositories")
            }
            status = L("repositoryOpened")
            fileStats = [:]; statBoxes.removeAll(); requestStats(); syncMarksKey = ""; loadSyncMarks()
            reviewLoadedRoot = nil; await updateFingerprints()
            Task { await syncRemoteProtection() }
        } catch { fail(error) }
    }
    /// Reads whether the provider really blocks direct pushes to main and caches it for the engine.
    /// Without a token (or permission to read the rules) the state stays unknown and main is not blocked.
    func syncRemoteProtection() async {
        guard let snapshot = repository, let hosted = try? HostedRepository(remote: snapshot.remote),
              (try? ProviderVault.load(hosted.provider)) ?? nil != nil else { return }
        let protected = await HostingClient().branchProtected(hosted, branch: snapshot.primary)
        let value = protected.map { $0 ? "true" : "false" } ?? "unknown"
        let current = snapshot.mainProtectionRemote ?? ""
        guard repository?.root == snapshot.root, value != (current.isEmpty ? "unknown" : current) else { return }
        _ = try? await engine.call(["method": "setRemoteProtection", "path": snapshot.root, "value": value]) as String
        await refresh()
    }
    /// Coalesced refresh: concurrent callers share one in-flight snapshot plus at most one follow-up.
    func refresh() async {
        guard repository != nil, !terminalActive else { return }
        if refreshInFlight { refreshQueued = true; return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        repeat {
            refreshQueued = false
            await refreshOnce()
        } while refreshQueued
    }
    /// Debounced refresh for bursts of filesystem events (e.g. an agent rewriting hundreds of files).
    func scheduleRefresh() {
        guard scheduledRefresh == nil else { return } // coalesce: one pending refresh at a time
        let delay = idleDelay
        scheduledRefresh = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.scheduledRefresh = nil
            guard !Task.isCancelled, !self.busy, !self.terminalActive else { return }
            self.statsDirty = true
            await self.refresh()
            // Back off while events keep arriving without visible changes; reset as soon as something changes.
            // While changes keep coming, the pace scales with the list: re-rendering thousands of rows costs ~70 ms,
            // so a huge working tree refreshes every 1–2 s instead of several times per second (no visible lag).
            let files = self.files.count
            let active: Duration = .milliseconds(max(300, min(2_000, files * 2 / 5)))
            self.idleDelay = self.lastRefreshChanged ? active : min(self.idleDelay * 2, .seconds(4))
        }
    }
    /// Background fetch so the notch can announce incoming commits. Read-only on the working tree.
    func startAutoFetch() {
        autoFetchTask?.cancel()
        autoFetchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard let self, !Task.isCancelled else { return }
                let enabled = UserDefaults.standard.object(forKey: "autoFetch") as? Bool ?? true
                guard enabled, let root = self.repository?.root, !self.busy, !self.terminalActive, !(self.repository?.remote.isEmpty ?? true) else { continue }
                if (try? await self.engine.call(["method": "action", "path": root, "action": "fetch", "value": ""]) as String) != nil { self.lastFetch = Date() }
                await self.refresh()
                await self.syncRemoteProtection()
            }
        }
    }
    private func refreshOnce() async {
        guard let root = repository?.root else { return }
        do {
            let result: RepositorySnapshot = try await engine.call(["method": "snapshot", "path": root, "limit": historyLimit])
            #if DEBUG || BUTAKE_QA
            NSLog("BUTAKE_QA refresh files=%d changed=%d", result.files.count, result != repository ? 1 : 0)
            #endif
            lastRefreshChanged = result != repository
            if result != repository {
                let previousFiles = repository?.files
                let small = result.files.count < WorkspaceStore.animationLimit && files.count < WorkspaceStore.animationLimit
                if onlyFilesDiffer(result) {
                    storedRepository = result
                    if small { withAnimation(.snappy(duration: 0.28)) { applyDerived(result) } } else { applyDerived(result) }
                } else if small { withAnimation(.snappy(duration: 0.28)) { repository = result } } else { repository = result }
                if previousFiles != result.files { statsDirty = true }
            }
            requestStats()
            loadSyncMarks()
            await updateFingerprints()
            if let selection = selectedFile {
                if let current = result.files.first(where: { $0.path == selection.path }) {
                    let hasStaged = current.index != " " && current.index != "?"
                    let hasUnstaged = current.worktree != " " || current.index == "?"
                    let group = stagedSelection ? hasStaged : !hasUnstaged && hasStaged
                    // Reload in place: keeping the old diff until the new one arrives avoids flicker on every refresh.
                    loadDiff(current, staged: group, keepCurrent: current.path == selection.path)
                } else { selectedFile = nil; diff = "" }
            }
            if let selected = selectedCommit, selected.hash != result.commits.first(where: { $0.hash == selected.hash })?.hash { selectedCommit = result.commits.first }
        } catch { fail(error) }
    }
    /// Line stats are the slowest read (a full numstat), so they load after the list and only when dirty.
    func requestStats() {
        guard statsDirty || fileStats.isEmpty, !statsInFlight, let root = repository?.root, !files.isEmpty else { if files.isEmpty == true && !fileStats.isEmpty { fileStats = [:]; for box in statBoxes.values { box.value = nil } }; return }
        // While an agent keeps writing, line stats reload at most every 1.5 s: each load re-renders every visible row.
        let wait = 1.5 - Date().timeIntervalSince(lastStatsLoad)
        if wait > 0, !fileStats.isEmpty {
            guard statsRetry == nil else { return }
            statsRetry = Task { [weak self] in try? await Task.sleep(for: .seconds(wait)); self?.statsRetry = nil; self?.requestStats() }
            return
        }
        lastStatsLoad = Date()
        statsInFlight = true; statsDirty = false
        Task {
            defer { statsInFlight = false; if statsDirty { requestStats() } }
            guard let entries: [FileStatEntry] = try? await engine.call(["method": "stats", "path": root]) else { return }
            var result: [String: LineStats] = [:]
            result.reserveCapacity(entries.count)
            for entry in entries { result[LineStats.key(entry.path, staged: entry.staged)] = LineStats(additions: entry.additions, deletions: entry.deletions) }
            if result != fileStats {
                fileStats = result; statsRevision &+= 1; refreshChangeTree()
                for (key, box) in statBoxes where box.value != result[key] { box.value = result[key] }
            }
        }
    }
    @ObservationIgnored private var changesFilterCache: (key: String, staged: [ChangedFile], unstaged: [ChangedFile])?
    /// Path filter for the Changes panels, memoized per snapshot and query.
    func filteredChanges(staged: Bool) -> [ChangedFile] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return staged ? changes.staged : changes.unstaged }
        let key = "\(filesRevision)|\(query)"
        if changesFilterCache?.key != key {
            changesFilterCache = (key, changes.staged.filter { $0.path.localizedCaseInsensitiveContains(query) }, changes.unstaged.filter { $0.path.localizedCaseInsensitiveContains(query) })
        }
        return staged ? changesFilterCache!.staged : changesFilterCache!.unstaged
    }
    // MARK: Reviewer
    /// Changes when the file's status or line counts change, so further edits by an agent reset "reviewed".
    func fingerprint(_ file: ChangedFile) -> String { fingerprints[file.path] ?? "\(file.index)\(file.worktree)" }
    /// Size and modification time of each changed file, read off the main thread.
    func updateFingerprints() async {
        guard let repo = repository else { return }
        let root = URL(fileURLWithPath: repo.root), files = repo.files
        let computed = await Task.detached(priority: .utility) { () -> [String: String] in
            var result: [String: String] = [:]; result.reserveCapacity(files.count)
            for file in files {
                let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(file.path).path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
                let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                result[file.path] = "\(file.index)\(file.worktree)|\(size)|\(Int64(modified * 1000))"
            }
            return result
        }.value
        if computed != fingerprints { fingerprints = computed }
        updateReviewedCount()
        loadReviewIfNeeded()
    }
    /// Marks live in the repository's git dir: never committed, removed with the repository, shared by sessions.
    private func reviewFile(_ root: String) -> URL? {
        let dotGit = URL(fileURLWithPath: root).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit.appendingPathComponent("butake-review.json") }
        // Worktree: ".git" is a file pointing at the real git dir.
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8), let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let path = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
        let gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: root).appendingPathComponent(path)
        return gitDir.appendingPathComponent("butake-review.json")
    }
    private func loadReviewIfNeeded() {
        guard let root = repository?.root, reviewLoadedRoot != root else { return }
        reviewLoadedRoot = root
        let current = Set(files.map(\.path))
        var loaded: [String: String] = [:]
        if let url = reviewFile(root), let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            loaded = stored.filter { current.contains($0.key) } // marks for files that are no longer changed are moot
        }
        reviewSaveTask?.cancel()
        reviewed = loaded
        reviewSaveTask?.cancel()
    }
    private func scheduleReviewSave() {
        guard let root = reviewLoadedRoot, root == repository?.root, let url = reviewFile(root) else { return }
        reviewSaveTask?.cancel()
        let snapshot = reviewed
        reviewSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            if snapshot.isEmpty { try? FileManager.default.removeItem(at: url) }
            else if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }
    func isReviewed(_ file: ChangedFile) -> Bool { reviewed[file.path] == fingerprint(file) }
    func setReviewed(_ files: [ChangedFile], _ value: Bool) {
        withAnimation(.snappy(duration: 0.2)) { for file in files { reviewed[file.path] = value ? fingerprint(file) : nil } }
    }
    /// Stored, not computed: the sidebar badge read it on every render, scanning thousands of files each time
    /// an agent touched one. Recomputed only when files, fingerprints or marks change.
    private(set) var reviewedCount = 0
    func updateReviewedCount() {
        let count = files.reduce(0) { $0 + (isReviewed($1) ? 1 : 0) }
        if count != reviewedCount { reviewedCount = count }
    }
    /// Combined line stats (staged + unstaged) for one file.
    func totalStats(_ file: ChangedFile) -> LineStats? {
        let a = stats(for: file, staged: false), b = stats(for: file, staged: true)
        if a == nil && b == nil { return nil }
        return LineStats(additions: (a?.additions ?? 0) + (b?.additions ?? 0), deletions: (a?.deletions ?? 0) + (b?.deletions ?? 0))
    }
    /// Changes › Carpetas. Built in the background: sorting and grouping thousands of paths on the main thread froze
    /// the window ~170–350 ms on every stage or refresh. The view keeps showing the previous tree until the new one lands.
    private(set) var changeTree = ChangeTree()
    @ObservationIgnored private var changeTreeKey = ""
    @ObservationIgnored private var changeTreeGeneration = 0
    func refreshChangeTree() {
        guard route == .review || !changeTree.nodes.isEmpty else { return }
        let query = search.trimmingCharacters(in: .whitespaces)
        let key = "\(filesRevision)|\(statsRevision)|\(query)"
        guard key != changeTreeKey else { return }
        changeTreeKey = key; changeTreeGeneration &+= 1
        let generation = changeTreeGeneration, files = self.files, stats = fileStats
        Task.detached(priority: .userInitiated) { [weak self] in
            let filtered = query.isEmpty ? files : files.filter { $0.path.localizedCaseInsensitiveContains(query) }
            let nodes = ChangeNode.tree(filtered) { file in
                let a = stats[LineStats.key(file.path, staged: false)], b = stats[LineStats.key(file.path, staged: true)]
                if a == nil && b == nil { return nil }
                return LineStats(additions: (a?.additions ?? 0) + (b?.additions ?? 0), deletions: (a?.deletions ?? 0) + (b?.deletions ?? 0))
            }
            let sorted = filtered.map { ($0.path.lowercased(), $0) }.sorted { $0.0 < $1.0 }.map(\.1)
            await MainActor.run { [weak self] in
                guard let self, generation == self.changeTreeGeneration else { return }
                self.changeTree = ChangeTree(nodes: nodes, files: sorted, revision: generation)
            }
        }
    }
    /// Filtered tree, memoized per snapshot, stats and filters.
    func reviewTree(query: String, extensionFilter: String?, kindFilter: ChangeKind? = nil, hideReviewed: Bool) -> (nodes: [ChangeNode], files: [ChangedFile]) {
        let key = "\(filesRevision)|\(statsRevision)|\(query)|\(extensionFilter ?? "*")|\(kindFilter?.rawValue ?? "*")|\(hideReviewed)|\(hideReviewed ? reviewed.count : 0)"
        if let cache = reviewCache, cache.key == key { return (cache.nodes, cache.files) }
        let needle = query.trimmingCharacters(in: .whitespaces)
        let files = files.filter { file in
            (needle.isEmpty || file.path.localizedCaseInsensitiveContains(needle))
                && (extensionFilter == nil || (file.path as NSString).pathExtension.lowercased() == extensionFilter)
                && (kindFilter == nil || file.kind == kindFilter)
                && (!hideReviewed || !isReviewed(file))
        }
        let nodes = ChangeNode.tree(files) { self.totalStats($0) }
        reviewCache = (key, nodes, files.map { ($0.path.lowercased(), $0) }.sorted { $0.0 < $1.0 }.map(\.1))
        return (nodes, reviewCache!.files)
    }
    /// Count per change kind and overall line totals, for the reviewer summary.
    var changeSummary: (kinds: [(kind: ChangeKind, count: Int)], additions: Int, deletions: Int) {
        var counts: [ChangeKind: Int] = [:]
        for file in files { counts[file.kind, default: 0] += 1 }
        let stats = fileStats.values
        return (ChangeKind.allCases.compactMap { kind in counts[kind].map { (kind, $0) } },
                stats.compactMap(\.additions).reduce(0, +), stats.compactMap(\.deletions).reduce(0, +))
    }
    /// Most frequent extensions among changed files, for the filter chips.
    var changeExtensions: [(ext: String, count: Int)] {
        var counts: [String: Int] = [:]
        for file in files { let ext = (file.path as NSString).pathExtension.lowercased(); if !ext.isEmpty { counts[ext, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(7).map { ($0.key, $0.value) }
    }
    /// Shows the most relevant diff: unstaged changes first, staged otherwise.
    func reviewSelect(_ file: ChangedFile) {
        let hasUnstaged = file.worktree != " " || file.index == "?"
        selectFile(file, staged: !hasUnstaged)
    }
    func historyModel(search: String, scope: Set<String>?) -> HistoryModel {
        let key = "\(revision)|\(search)|\(scope.map { "\($0.count)-\($0.hashValue)" } ?? "all")"
        if let cache = historyCache, cache.key == key { return cache.model }
        let query = search.trimmingCharacters(in: .whitespaces)
        let commits = (repository?.commits ?? []).filter { commit in
            (scope == nil || scope!.contains(commit.hash)) && (query.isEmpty || "\(commit.subject) \(commit.author) \(commit.hash) \(commit.refs)".localizedCaseInsensitiveContains(query))
        }
        let model = HistoryModel(commits: commits, graph: CommitGraph(commits: commits, localBranches: refs.localBranches))
        historyCache = (key, model)
        return model
    }
    func startWatching(_ root: String) {
        watcher = RepositoryWatcher(root: root) { [weak self] in Task { @MainActor in self?.scheduleRefresh() } }
    }
    func loadMoreHistory() {
        guard repository != nil, !loadingHistory, canLoadMoreHistory else { return }
        loadingHistory = true; historyLimit += WorkspaceStore.historyPage
        Task { await refresh(); loadingHistory = false }
    }
    func notify(_ message: String, icon: String = "checkmark.circle.fill", destructive: Bool = false) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { toast = Toast(message: message, icon: icon, destructive: destructive) }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
        }
    }
    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        notify(L("copied"), icon: "doc.on.doc.fill")
    }
    /// Runs a pull variant the user picked in the assistant (the choice itself is the confirmation).
    func pull(_ action: String) {
        guard let root = repository?.root else { return }
        pullProblem = nil
        Task { await perform(PendingOperation(title: L(action), root: root, action: action, preview: action)) }
    }
    func copyCommits(_ commits: [GitCommit], to target: String) {
        guard let root = repository?.root, !commits.isEmpty, !busy, !terminalActive else { return }
        let list = commits.map { "\($0.shortHash) \($0.subject)" }.joined(separator: "\n")
        pending = PendingOperation(title: String(format: L("copyTo"), target), root: root, preview: "git switch \(target)\ngit cherry-pick -x \(commits.reversed().map(\.shortHash).joined(separator: " "))\ngit switch \(repository?.branch ?? "")\n\n\(list)", copyHashes: commits.map(\.hash), copyTarget: target, detail: String(format: L("copyDetail"), commits.count, target))
    }
    /// Loads main/develop membership marks (by patch content) for the history badges.
    func loadSyncMarks() {
        guard let repo = repository, Set(repo.branches.map(\.name)).isSuperset(of: [repo.primary, "develop"]) else { if !syncMarks.isEmpty { syncMarks = [:] }; return }
        let key = repo.branches.map { $0.name }.joined() + (repo.commits.first?.hash ?? "") + "\(repo.commits.count)"
        guard key != syncMarksKey else { return }
        syncMarksKey = key
        Task {
            guard let sync: BranchSyncResult = try? await engine.call(["method": "branchSync", "path": repo.root, "left": repo.primary, "right": "develop"]) else { return }
            var marks: [String: SyncMark] = [:]
            for commit in sync.onlyLeft { marks[commit.hash] = .onlyMain }
            for commit in sync.onlyRight { marks[commit.hash] = .onlyDevelop }
            for commit in sync.equivalentLeft + sync.equivalentRight { marks[commit.hash] = .copied }
            syncMarks = marks
        }
    }
    func applyRewrite(candidates: RewriteCandidates, items: [RewriteItem]) async -> String? {
        guard let root = repository?.root, !busy, !terminalActive else { return nil }
        busy = true; runningAction = "rewrite"
        defer { busy = false; runningAction = nil }
        let plan: [String: Any] = ["head": candidates.head, "base": candidates.base, "steps": items.reversed().map(\.step)]
        do {
            let result: RewriteResultValue = try await engine.call(["method": "rewriteApply", "path": root, "plan": plan, "confirmed": true])
            withAnimation(.snappy) { lastRewrite = (result.backup, candidates.branch) }
            notify(L("rewriteDone"), icon: "wand.and.stars")
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            await refresh(); return nil
        } catch let failure as EngineFailure where failure.code == "rewrite_conflicts" {
            lastRewrite = (failure.detail.components(separatedBy: "Respaldo: ").last ?? "", candidates.branch)
            await refresh(); resolveNextConflict(); return failure.detail
        } catch {
            await refresh(); return error.localizedDescription
        }
    }
    func undoRewrite() {
        guard let root = repository?.root, let last = lastRewrite, !busy, !terminalActive else { return }
        Task {
            busy = true; defer { busy = false }
            do {
                if repository?.operation == "rebase" { let _: String = try await engine.call(["method": "action", "path": root, "action": "rebase_abort", "confirmed": true]) }
                let _: String = try await engine.call(["method": "rewriteUndo", "path": root, "backup": last.backup, "confirmed": true])
                withAnimation(.snappy) { lastRewrite = nil }
                notify(L("rewriteUndone"), icon: "arrow.uturn.backward.circle.fill")
            } catch { fail(error) }
            await refresh()
        }
    }
    func resolveNextConflict() {
        route = .changes
        if let file = changes.conflicts.first { resolving = file }
    }
    func abortOperation() {
        guard let operation = repository?.operation, !operation.isEmpty else { return }
        if operation == "rebase" { action("rebase_abort", confirm: true) } else { Task { await prepare(operation, arguments: "--abort") } }
    }
    func showDiff(_ title: String, subtitle: String = "", args: [String]) { diffRequest = DiffRequest(title: title, subtitle: subtitle, args: args) }
    func compareWithHead(_ commit: GitCommit) {
        // HEAD against itself is always empty; for the checked-out commit compare against the working tree instead.
        if commit.hash == refs.headHash {
            showDiff(L("compareWorking"), subtitle: "\(commit.shortHash) (HEAD) → \(L("workingTree"))", args: ["diff", "--no-ext-diff", "--no-textconv", "--no-color", commit.hash])
        } else {
            showDiff(L("compare"), subtitle: "\(commit.shortHash) → HEAD · \(commit.subject)", args: ["diff", "--no-ext-diff", "--no-textconv", "--no-color", commit.hash, "HEAD"])
        }
    }
    func showCommit(_ reference: String, title: String) {
        showDiff(title, subtitle: reference, args: ["show", "--no-ext-diff", "--no-textconv", "--no-color", "--diff-merges=first-parent", "--format=%x01%h %s%n%an · %ad%n%n%b", reference])
    }
    func selectCommit(hash: String) {
        if let commit = repository?.commits.first(where: { $0.hash.hasPrefix(hash) }) { route = .history; withAnimation(.snappy) { selectedCommit = commit } }
        else { notify(L("commitNotLoaded"), icon: "info.circle.fill") }
    }
    func discard(_ file: ChangedFile) {
        guard let root = repository?.root, !busy && !terminalActive else { return }
        let preview = file.index == "?" ? "git clean --force -- \(shellQuote(file.path))" : "git restore --worktree -- \(shellQuote(file.path))"
        pending = PendingOperation(title: L("discard"), root: root, action: "discard", value: file.path, preview: preview, destructive: true, detail: L(file.index == "?" ? "discardUntrackedDetail" : "discardDetail"))
    }
    /// The confirmation shown for an action, shared by the main window and the notch panel.
    func confirmation(for action: String, value: String = "") -> PendingOperation? {
        guard let root = repository?.root else { return nil }
        var operation = PendingOperation(title: L(action), root: root, action: action, value: value, preview: "git \(action.replacingOccurrences(of: "_", with: " ")) \(value)")
        // Unprotected main is allowed, but a direct push to it deserves a visible warning.
        if action == "push" && repository?.branch == repository?.primary { operation.destructive = true; operation.detail = L("pushToMainWarning") }
        if action == "push", let branch = repository?.branch { operation.preview = "git push · \(branch)" + (repository?.ahead ?? 0 > 0 ? " (\(repository!.ahead) commits)" : "") }
        if action == "pull", let branch = repository?.branch { operation.preview = "git pull --ff-only · \(branch)" + (repository?.behind ?? 0 > 0 ? " (\(repository!.behind) commits)" : "") }
        return operation
    }
    func action(_ action: String, value: String = "", confirm: Bool = false) {
        guard let root = repository?.root, !busy && !terminalActive else { return }
        if !confirm, action == "stage" || action == "unstage", let file = files.first(where: { $0.path == value }) {
            Task { await stageNow([file], staged: action == "unstage") }; return
        }
        if confirm {
            pending = confirmation(for: action, value: value)
        } else {
            Task { await perform(PendingOperation(title: L(action), root: root, action: action, value: value, preview: action)) }
        }
    }
    func perform(_ operation: PendingOperation) async {
        guard !busy && !terminalActive else { return }
        await stagingChain?.value  // never run another Git command on top of a pending stage
        if operation.interactive {
            consoleCommand = operation.command ?? "status"; consoleArguments = operation.arguments; consolePlan = operation.plan
            terminalLaunch = TerminalLaunch(root: operation.root, command: consoleCommand, arguments: consoleArguments, plan: consolePlan)
            terminalActive = true; route = .console; status = L("terminalRunning"); return
        }
        busy = true; runningAction = operation.action ?? operation.command
        defer { busy = false; runningAction = nil }
        if let target = operation.copyTarget {
            do {
                let count: Int = try await engine.call(["method": "copyCommits", "path": operation.root, "target": target, "hashes": operation.copyHashes, "confirmed": true])
                status = L("operationComplete")
                notify(String(format: L("copiedCommits"), count, target), icon: "arrow.right.doc.on.clipboard")
            } catch let failure as EngineFailure where failure.code == "copy_conflicts" {
                status = L("needsDecision"); errorMessage = failure.detail
                await refresh(); resolveNextConflict(); return
            } catch { fail(error) }
            await refresh(); return
        }
        do {
            var parameters: [String: Any] = ["path": operation.root, "confirmed": true]
            if let action = operation.action { parameters.merge(["method": "action", "action": action, "value": operation.value]) { _, b in b } }
            else { parameters.merge(["method": "run", "command": operation.command ?? "status", "arguments": operation.arguments]) { _, b in b } }
            let _: String = try await engine.call(parameters)
            if operation.action == "fetch" || operation.action?.hasPrefix("pull") == true { lastFetch = Date() }
            if operation.action == "commit" { message = ""; NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
            if operation.action == "discard", selectedFile?.path == operation.value { selectedFile = nil; diff = "" }
            status = L("operationComplete")
            notify(WorkspaceStore.successMessage(operation), icon: operation.destructive ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill")
        } catch let failure as EngineFailure where failure.code == "branch_not_merged" {
            // Unique commits would be lost: ask again, explicitly, for the forced deletion.
            busy = false; deleteBranch(operation.value, force: true); errorMessage = nil; return
        } catch let failure as EngineFailure where failure.code.hasPrefix("pull_") {
            status = L("needsDecision")
            pullProblem = PullProblem(code: failure.code, detail: failure.detail)
        } catch { fail(error) }
        await refresh()
    }
    func prepare(_ command: String, arguments: String = "", interactive: Bool = false, plan: RebasePlan? = nil) async {
        guard let root = repository?.root, !busy && !terminalActive else { return }
        do {
            let prepared: PreparedCommand = try await engine.call(["method": "prepare", "path": root, "command": command, "arguments": arguments])
            if let plan {
                let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))
                let _: String = try await engine.call(["method": "validateRebase", "path": root, "plan": value])
            }
            pending = PendingOperation(title: L("executeCommand"), root: root, command: command, arguments: arguments, preview: prepared.preview, plan: plan, interactive: interactive)
        } catch { fail(error) }
    }
    func terminalDidFinish(_ code: Int32?) {
        terminalActive = false; status = code == 0 ? L("operationComplete") : "\(L("exitCode")): \(code ?? -1)"
        if code == 0 { notify(L("operationComplete")) } else { notify(status, icon: "exclamationmark.triangle.fill", destructive: true) }
        Task { await refresh() }
    }
    func selectFile(_ file: ChangedFile, staged: Bool) { loadDiff(file, staged: staged, keepCurrent: false) }
    private func loadDiff(_ file: ChangedFile, staged: Bool, keepCurrent: Bool) {
        guard let root = repository?.root else { return }
        if selectedFile != file { selectedFile = file }
        if stagedSelection != staged { stagedSelection = staged }
        let generation = UUID(); diffGeneration = generation
        // Clear only if the new diff is slow to arrive: an instant swap avoids a blank flash between files.
        if !keepCurrent {
            Task { [weak self] in try? await Task.sleep(for: .milliseconds(150)); if let self, self.diffGeneration == generation, self.selectedFile?.path == file.path { self.diff = "" } }
        }
        Task {
            do {
                let value: String = try await engine.call(["method": "diff", "path": root, "file": file.path, "staged": staged])
                if generation == diffGeneration && diff != value { diff = value }
            } catch { if generation == diffGeneration { fail(error) } }
        }
    }
    func stageFiles(_ files: [ChangedFile], staged: Bool) {
        guard repository != nil, !busy && !terminalActive else { return }
        Task { await stageNow(files, staged: staged) }
    }
    /// Staging is quick and frequent (every checkbox): it never flips `busy`, which disabled the sidebar and toolbar
    /// and re-rendered the whole window (a visible white flash on big repositories). Operations run in order, so fast
    /// clicks are queued instead of dropped, and other Git actions wait for them through `stagingInFlight`.
    @ObservationIgnored private var stagingChain: Task<Void, Never>?
    @ObservationIgnored private(set) var stagingInFlight = false
    private func enqueueStaging(_ work: @escaping @MainActor () async -> Void) async {
        let previous = stagingChain
        let task = Task { @MainActor in
            await previous?.value
            stagingInFlight = true
            await work()
            stagingInFlight = false
        }
        stagingChain = task
        await task.value
    }
    func stageNow(_ files: [ChangedFile], staged: Bool) async {
        guard let root = repository?.root, !busy && !terminalActive, !files.isEmpty else { return }
        await enqueueStaging { [self] in
            do {
                // One engine call and one Git process for the whole batch.
                let count: Int = try await engine.call(["method": "stagePaths", "path": root, "paths": files.map(\.path), "staged": staged])
                status = L("operationComplete")
                if count > 1 { notify(String(format: L(staged ? "unstagedCount" : "stagedCount"), count)) }
            } catch { fail(error) }
            await refresh()
        }
    }
    func stageHunk(_ index: Int) {
        guard let root = repository?.root, let file = selectedFile, !busy && !terminalActive else { return }
        let staged = stagedSelection
        Task {
            await enqueueStaging { [self] in
                do {
                    let _: String = try await engine.call(["method": "stageHunk", "path": root, "file": file.path, "staged": staged, "index": index])
                    status = L("operationComplete")
                } catch { fail(error) }
                await refresh()
            }
        }
    }
    func loadCapabilities() async {
        do { capabilities = try await engine.call(["method": "capabilities"]) }
        catch { fail(error) }
    }
    func openPR() {
        // GitHub or Bitbucket compare page for the current branch; falls back to the engine for other remotes.
        if let repo = repository, let hosted = try? HostedRepository(remote: repo.remote), let url = hosted.provider.webCompareURL(hosted, branch: repo.branch) { NSWorkspace.shared.open(url); return }
        guard let root = repository?.root else { return }
        Task {
            do { let address: String = try await engine.call(["method": "pullRequestUrl", "path": root]); if let url = URL(string: address) { NSWorkspace.shared.open(url) } }
            catch { fail(error) }
        }
    }
    func fail(_ error: Error) { errorMessage = error.localizedDescription; status = L("operationFailed") }
    static func successMessage(_ operation: PendingOperation) -> String {
        guard let action = operation.action else { return L("operationComplete") }
        let key = "done_\(action)"; let text = L(key)
        return text == key ? L("operationComplete") : text
    }
    func inspect(_ command: String, arguments: String = "") { consoleCommand = command; consoleArguments = arguments; consolePlan = nil; route = .console }

    #if DEBUG || BUTAKE_QA
    /// QA-only: replays inspector button actions on a temporary repository so presentation can be checked without driving the mouse.
    func runQAScript(_ script: String?) async {
        guard let script, let commit = repository?.commits.first else { return }
        for step in script.split(separator: ",") {
            try? await Task.sleep(for: .seconds(1.5))
            NSLog("BUTAKE_QA step=%@ pending=%d diff=%d busy=%d", String(step), pending == nil ? 0 : 1, diffRequest == nil ? 0 : 1, busy ? 1 : 0)
            switch step {
            case "inspector": route = .history; selectedCommit = commit; showInspector = true
            case "compare": compareWithHead(commit)
            case "show": showCommit(commit.hash, title: commit.subject)
            case "revert": action("revert", value: commit.hash, confirm: true)
            case "close": pending = nil; diffRequest = nil; creatingRepository = false; publishingRepository = false; cloningRepository = false
            case "pull", "pull_merge", "pull_rebase", "pull_autostash": if let root = repository?.root { await perform(PendingOperation(title: String(step), root: root, action: String(step), preview: String(step))) }
            case "closeAssistant": pullProblem = nil
            case "loadAll": historyLimit = 5_000; await refresh()
            case "sync": route = .sync
            case "review": route = .review
            case "reviewCount": NSLog("BUTAKE_QA reviewed=%d of=%d", reviewedCount, files.count)
            case let pick where pick.hasPrefix("reviewPick:"):
                if let file = files.first(where: { $0.path == String(pick.dropFirst(11)) }) { reviewSelect(file) }
            case let mark where mark.hasPrefix("reviewMark:"):
                let prefix = String(mark.dropFirst(11)); setReviewed(files.filter { $0.path.hasPrefix(prefix) }, true)
            case "tags": route = .tags
            case "pullRequests": route = .pullRequests
            case let render where render.hasPrefix("renderNotch:"):
                // Offscreen render of the notch card in both states (QA on Macs without a visible notch).
                NSLog("BUTAKE_QA notch geometry=%@", NotchGeometry.current().map { NSStringFromRect($0.notch) } ?? "none")
                for expanded in [false, true] {
                    let model = NotchModel(); model.expanded = expanded; model.showWings = true; model.notchWidth = 200; model.notchHeight = 32
                    let size = expanded ? NSSize(width: 480, height: 230) : NSSize(width: model.collapsedWidth, height: 32); model.panelExpanded = expanded
                    let host = NSHostingView(rootView: NotchView(store: self, model: model) { _ in }.frame(width: size.width, height: size.height))
                    host.frame = NSRect(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
                    try? await Task.sleep(for: .milliseconds(500))
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep); try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(render.dropFirst(12)) + (expanded ? "-open.png" : "-closed.png"))) }
                }
            case let render where render.hasPrefix("renderAccounts:"):
                let host = NSHostingView(rootView: AccountsSettingsView().frame(width: 640, height: 900).tint(Brand.accent))
                host.frame = NSRect(x: 0, y: 0, width: 640, height: 900); host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(600))
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep); try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(render.dropFirst(15)))) }
            case let render where render.hasPrefix("renderPR:"):
                // Offscreen render of the PR panel with sample data (no provider token needed).
                let repo = try! HostedRepository(remote: "git@github.com:butake/tienda-online.git")
                let pr = HostedPR(id: 128, title: "feat(envios): tarifa por región y peso", body: "Calcula el envío según la **región** y los kilos del pedido.\n\n- Regiones sin recargo: RM y V\n- Pruebas de borde para peso cero", state: .open, author: "tomasfuentes", source: "feature/envios", target: "develop", sourceSHA: "abc123", url: URL(string: "https://github.com/butake/tienda-online/pull/128"), updated: Date().addingTimeInterval(-3_600 * 3))
                let hunk = "@@ -8,6 +8,10 @@ class Tarifa\n     public function calcular(string $region, float $kilos): int\n     {\n-        $extra = $region === 'RM' ? 0 : 1500;\n+        $extra = in_array($region, ['RM', 'V'], true) ? 0 : 1800;\n+        if ($kilos == 0) return self::BASE;"
                let fixture = PRFixture(
                    comments: [
                        HostedComment(id: 1, author: "camilarojas", body: "Se ve bien. Falta cubrir el caso de peso cero.", created: Date().addingTimeInterval(-7_200)),
                        HostedComment(id: 2, author: "code-quality[bot]", body: "Usa comparación estricta y un error claro en vez de retornar la base.\n\n```suggestion\n        if ($kilos <= 0) throw new \\InvalidArgumentException('El peso debe ser positivo.');\n```", created: Date().addingTimeInterval(-3_000), path: "app/Services/Envios/Tarifa.php", line: 12, hunk: hunk)],
                    checks: [HostedCheck(id: "1", name: "Build", state: .success, detail: "success", url: URL(string: "https://example.com"), duration: 42), HostedCheck(id: "2", name: "Pruebas", state: .failure, detail: "failure", url: URL(string: "https://example.com"), duration: 312), HostedCheck(id: "3", name: "Análisis de seguridad", state: .pending, detail: "in_progress", url: nil), HostedCheck(id: "4", name: "Deploy de vista previa", state: .success, detail: "success", url: nil, duration: 72)],
                    reviews: [HostedReview(author: "camilarojas", verdict: .changesRequested), HostedReview(author: "diegomunoz", verdict: .approved)],
                    files: [CommitFileChange(path: "app/Services/Envios/Tarifa.php", status: "M", stats: LineStats(additions: 9, deletions: 2)), CommitFileChange(path: "tests/Unit/TarifaTest.php", status: "A", stats: LineStats(additions: 31, deletions: 0)), CommitFileChange(path: "config/tienda.json", status: "M", stats: LineStats(additions: 1, deletions: 0))])
                let parts = String(render.dropFirst(9)).split(separator: "|").map(String.init)
                let host = NSHostingView(rootView: PullRequestDetail(store: self, pr: pr, repo: repo, reload: {}, fixture: fixture).frame(width: 980, height: 1250).background(Color(nsColor: .windowBackgroundColor)).tint(Brand.accent))
                host.appearance = NSAppearance(named: parts.count > 1 && parts[1] == "dark" ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 980, height: 1250); host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(900))
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep); try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[0])) }
            case let render where render.hasPrefix("renderEditor:"):
                // renderEditor:<file>|<out.png>|<tab>[|dark]: offscreen file editor (QA).
                let parts = String(render.dropFirst(13)).split(separator: "|").map(String.init)
                guard parts.count >= 3 else { break }
                let host = NSHostingView(rootView: FileEditorView(store: self, path: parts[0], initialTab: Int(parts[2]) ?? 0).frame(width: 980, height: 700).tint(Brand.accent))
                host.appearance = NSAppearance(named: parts.count > 3 && parts[3] == "dark" ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 980, height: 700); host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(1500)); host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep); try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1])) }
            case let render where render.hasPrefix("renderQuick:"):
                // renderQuick:<commit|push|branch>|<out.png>: offscreen notch panel (QA).
                let parts = String(render.dropFirst(12)).split(separator: "|").map(String.init)
                guard parts.count == 2 else { break }
                let content: NotchQuickContent = parts[0] == "commit" ? .commit : parts[0] == "branch" ? .newBranch : confirmation(for: "push").map { .confirm(PendingOperationSnapshot(action: "push", title: $0.title, preview: $0.preview, detail: $0.detail, destructive: $0.destructive)) } ?? .commit
                let size = NSSize(width: 460, height: content == .commit ? 400 : content == .newBranch ? 190 : 240)
                let host = NSHostingView(rootView: NotchQuickView(store: self, content: content) {}.frame(width: size.width, height: size.height).padding(30).background(Color(white: 0.85)))
                host.frame = NSRect(x: 0, y: 0, width: size.width + 60, height: size.height + 60); host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(700))
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep); try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1])) }
            case "accounts":
                UserDefaults.standard.set("accounts", forKey: "settingsTab")
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            case let shot where shot.hasPrefix("shotset:"):
                try? await Task.sleep(for: .seconds(1))
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width < 800 && $0.frame.height > 400 }), let view = window.contentView?.superview ?? window.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(shot.dropFirst(8))))
                }
            case "organize": organizing = true
            case let command where command.hasPrefix("org:"): NotificationCenter.default.post(name: .init("butake.qa.organize"), object: String(command.dropFirst(4)).replacingOccurrences(of: "+", with: ","))
            case "undoRewrite": undoRewrite()
            case "dark", "light", "system": UserDefaults.standard.set(String(step), forKey: "appearance")
            case let shot where shot.hasPrefix("shot:"):
                // In-app snapshot, independent of Spaces; the window is made key so the toolbar renders active.
                NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0.isVisible && $0.frame.width > 800 }?.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(1))
                if let main = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 800 }), case let window = main.attachedSheet ?? main, let view = window.contentView?.superview ?? window.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(shot.dropFirst(5))))
                }
            case "history": route = .history
            case "clone": cloningRepository = true
            case "newRepository": creatingRepository = true
            case "publish": publishingRepository = true
            case "notchOff", "notchOn": UserDefaults.standard.set(step == "notchOn", forKey: "notchEnabled")
            case "newBranch": creatingBranch = true
            case let file where file.hasPrefix("fileDiff:"):
                // fileDiff:<path> or fileDiff:<rev>|<path>
                let spec = String(file.dropFirst(9)).split(separator: "|").map(String.init)
                let (rev, path) = spec.count == 2 ? (spec[0], spec[1]) : ("HEAD", spec[0])
                let subject = repository?.commits.first { $0.hash.hasPrefix(rev) || rev == "HEAD" }?.subject ?? rev
                showDiff(path, subtitle: subject, args: ["show", "--format=", "--no-ext-diff", "--no-color", rev, "--", path])
            case "windowed": if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 800 }), window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil); try? await Task.sleep(for: .seconds(2)) }
            case "fullscreen": NSApp.windows.first { $0.isVisible && $0.frame.width > 800 }?.toggleFullScreen(nil); try? await Task.sleep(for: .seconds(2))
            case let name where name.hasPrefix("route:"): if let target = WorkspaceRoute(rawValue: String(name.dropFirst(6))) { route = target }
            case "changes": route = .changes
            case "noInspector": showInspector = false
            case "switchbench", "refreshbench", "switchlight":
                let benchmark = ScrollBenchmark(); let isSwitch = step != "refreshbench"
                let pair: (WorkspaceRoute, WorkspaceRoute) = step == "switchlight" ? (.tags, .stash) : (.changes, .history)
                let task = Task { @MainActor in
                    for index in 0..<6 {
                        try? await Task.sleep(for: .milliseconds(450))
                        if isSwitch { route = index % 2 == 0 ? pair.0 : pair.1; NSLog("BUTAKE_QA switch at=%.3f to=%@", CACurrentMediaTime(), route.rawValue) } else { statsDirty = true; await refresh() }
                    }
                }
                await withCheckedContinuation { continuation in benchmark.run(label: String(step), frames: 400, pointsPerFrame: 0) { continuation.resume() } }
                task.cancel()
            case "checkUpdate": await UpdateService.shared.check(userInitiated: true); NSLog("BUTAKE_QA update phase=%@ latest=%@ available=%d", "\(UpdateService.shared.phase)", UpdateService.shared.latest?.version ?? "-", UpdateService.shared.updateAvailable ? 1 : 0)
            case "installUpdate": await UpdateService.shared.install(); NSLog("BUTAKE_QA update phase=%@", "\(UpdateService.shared.phase)")
            case "busyflip":
                // Reproduces what every Git operation does to the window: busy on, short work, busy off.
                for _ in 0..<3 { busy = true; try? await Task.sleep(for: .milliseconds(250)); busy = false; try? await Task.sleep(for: .milliseconds(700)) }
            case let name where name.hasPrefix("togglebench:"):
                // Frame monitor while a tree checkbox is pressed repeatedly (stage / unstage a folder).
                let id = String(name.dropFirst(12)); let benchmark = ScrollBenchmark()
                let presser = Task { @MainActor in for _ in 0..<4 { try? await Task.sleep(for: .milliseconds(900)); NotificationCenter.default.post(name: .init("butake.qa.treeToggle"), object: id) } }
                await withCheckedContinuation { continuation in benchmark.run(label: "toggle", frames: 330, pointsPerFrame: 0) { continuation.resume() } }
                presser.cancel()
            case let name where name.hasPrefix("tree:"): NotificationCenter.default.post(name: .init("butake.qa.treeToggle"), object: String(name.dropFirst(5)))
            case "idle":
                // Frame monitor without scrolling: measures hitches caused by background work (agent writes, refreshes).
                let benchmark = ScrollBenchmark()
                await withCheckedContinuation { continuation in benchmark.run(label: "idle-\(route.rawValue)", frames: 720, pointsPerFrame: 0) { continuation.resume() } }
            case "selectFiles":
                // Walks the first changed files like a reviewer pressing ↓, loading each diff.
                let benchmark = ScrollBenchmark(); let files = Array(changes.unstaged.prefix(12))
                let walker = Task { @MainActor in for file in files { try? await Task.sleep(for: .milliseconds(350)); selectFile(file, staged: false) } }
                await withCheckedContinuation { continuation in benchmark.run(label: "selectFiles", frames: 300, pointsPerFrame: 0) { continuation.resume() } }
                walker.cancel()
            case "scroll":
                let benchmark = ScrollBenchmark()
                await withCheckedContinuation { continuation in benchmark.run(label: route.rawValue) { continuation.resume() } }
            case "bench":
                let clock = ContinuousClock()
                let refresh = await clock.measure { statsDirty = true; await refresh() }
                let stageAll = await clock.measure { await stageNow(changes.unstaged, staged: false) }
                let staged = changes.staged.count
                let unstageAll = await clock.measure { await stageNow(changes.staged, staged: true) }
                let graph = clock.measure { historyCache = nil; _ = historyModel(search: "", scope: nil) }
                NSLog("BUTAKE_QA bench files=%d refresh=%@ stageAll=%@ (staged=%d) unstageAll=%@ graph=%@", files.count, "\(refresh)", "\(stageAll)", staged, "\(unstageAll)", "\(graph)")
            case "resolve": resolveNextConflict()
            default: break
            }
            try? await Task.sleep(for: .seconds(1))
            NSLog("BUTAKE_QA after=%@ pending=%d diff=%d pullProblem=%@ operation=%@ conflicts=%d resolving=%@", String(step), pending == nil ? 0 : 1, diffRequest == nil ? 0 : 1, pullProblem?.code ?? "-", repository?.operation ?? "-", changes.conflicts.count, resolving?.path ?? "-")
        }
    }
    #endif
}
