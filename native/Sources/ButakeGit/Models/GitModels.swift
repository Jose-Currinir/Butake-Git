import Foundation

struct RepositorySnapshot: Codable, Equatable {
    var root: String
    var branch: String
    var files: [ChangedFile]
    var commits: [GitCommit]
    var branches: [GitBranch]
    var operation: String
    var ahead: Int
    var behind: Int
    var remote: String
    /// Engine-resolved protection: explicit choice, else the provider's rule, else not blocked.
    var mainProtected: Bool?
    /// Explicit setting: "true", "false" or "" for automatic.
    var mainProtection: String?
    /// Provider rule cached by the app: "true", "false" or "" when unknown.
    var mainProtectionRemote: String?
    /// `main`, or `master` in repositories that use it.
    var primaryBranch: String?
    var remoteBranches: [RemoteBranch]?
    /// Configured remotes; empty when the repository only exists locally.
    var remotes: [String]?
    var hasRemote: Bool { !(remotes ?? (remote.isEmpty ? [] : ["origin"])).isEmpty }
    /// Not published yet: no remote, or a remote that has received no branch (e.g. a publication that failed at the push).
    var canPublish: Bool { !hasRemote || (remoteBranches ?? []).isEmpty }
    var primary: String { primaryBranch ?? "main" }
    /// Remote branches without a local branch of the same name (the ones you can bring in).
    var remoteOnly: [RemoteBranch] { let locals = Set(branches.map(\.name)); return (remoteBranches ?? []).filter { !locals.contains($0.short) } }
    var name: String { URL(fileURLWithPath: root).lastPathComponent }
    /// Commit checked out (decorated `HEAD`), if it is among the loaded commits.
    var headHash: String? { commits.first { $0.refs == "HEAD" || $0.refs.hasPrefix("HEAD ->") || $0.refs.hasPrefix("HEAD,") }?.hash }
    /// Loaded commits already contained in HEAD, following every parent.
    var reachableFromHead: Set<String> {
        guard let head = headHash else { return [] }
        let byHash = Dictionary(commits.map { ($0.hash, $0) }, uniquingKeysWith: { a, _ in a })
        var seen: Set<String> = []; var stack = [head]
        while let hash = stack.popLast() { if seen.insert(hash).inserted, let commit = byHash[hash] { stack.append(contentsOf: commit.parents) } }
        return seen
    }
    var conflicts: [ChangedFile] { files.filter(\.conflict) }
    var staged: [ChangedFile] { files.filter { !$0.conflict && $0.index != " " && $0.index != "?" } }
    var unstaged: [ChangedFile] { files.filter { !$0.conflict && ($0.worktree != " " || $0.index == "?") } }
}
struct ChangedFile: Codable, Identifiable, Hashable {
    var path: String
    var originalPath: String?
    var index: String
    var worktree: String
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
    var conflict: Bool { [index, worktree].contains("U") || (index == "A" && worktree == "A") || (index == "D" && worktree == "D") }
    /// What happened to the file, combining index and working tree.
    var kind: ChangeKind {
        if conflict { return .conflict }
        if index == "R" || worktree == "R" || index == "C" { return .renamed }
        if index == "?" || index == "A" { return worktree == "D" ? .deleted : .added }
        if index == "D" || worktree == "D" { return .deleted }
        return .modified
    }
}
struct GitCommit: Codable, Identifiable, Hashable {
    var hash: String
    var parents: [String]
    var author: String
    var timestamp: String
    var subject: String
    var refs: String
    var id: String { hash }
    var shortHash: String { String(hash.prefix(7)) }
    var date: Date { Date(timeIntervalSince1970: Double(timestamp) ?? 0) }
}
struct GitBranch: Codable, Identifiable, Hashable {
    var name: String
    var current: Bool
    var upstream: String
    var ahead: Int? = nil
    var behind: Int? = nil
    /// The upstream branch was deleted on the remote.
    var gone: Bool? = nil
    var updated: Int? = nil
    var id: String { name }
    var date: Date? { updated.map { Date(timeIntervalSince1970: Double($0)) } }
}
struct RemoteBranch: Codable, Identifiable, Hashable {
    /// `origin/feature/x`
    var name: String
    var remote: String
    /// `feature/x`
    var short: String
    var updated: Int?
    var id: String { name }
    var date: Date? { updated.map { Date(timeIntervalSince1970: Double($0)) } }
}
/// Branch names grouped by prefix ("feature/", "hotfix/"…) with a readable label, for any repository's naming.
enum BranchNaming {
    static func prefix(_ name: String) -> String? { name.split(separator: "/", maxSplits: 1).count == 2 ? String(name.split(separator: "/")[0]) : nil }
    /// "feature/api-vehicles_status" → "api vehicles status".
    static func leaf(_ name: String) -> String {
        let last = name.split(separator: "/", maxSplits: 1).count == 2 ? String(name.split(separator: "/", maxSplits: 1)[1]) : name
        return last.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    }
    static func groupTitle(_ prefix: String) -> String {
        let key = "branchGroup_\(prefix.lowercased())"
        let text = L(key)
        return text == key ? prefix : text
    }
    static func groupIcon(_ prefix: String?) -> String {
        switch prefix?.lowercased() {
        case "feature", "feat": "sparkles"
        case "fix", "bugfix", "bug": "wrench.and.screwdriver"
        case "hotfix": "flame"
        case "release": "shippingbox"
        case "chore": "hammer"
        case "update", "upgrade": "arrow.up.circle"
        case "docs": "doc.text"
        case "test", "qa": "checkmark.seal"
        default: "arrow.triangle.branch"
        }
    }
    /// Names without a prefix come first; prefixes with the same meaning ("update/", "upgrade/") share a group.
    static func groups<T>(_ items: [T], name: (T) -> String) -> [(prefix: String?, items: [T])] {
        var buckets: [String: (prefix: String, items: [T])] = [:]; var plain: [T] = []
        for item in items {
            guard let key = prefix(name(item)) else { plain.append(item); continue }
            let title = groupTitle(key)
            if buckets[title] == nil { buckets[title] = (key, []) }
            buckets[title]!.items.append(item)
        }
        let grouped = buckets.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }.map { (prefix: Optional($0.value.prefix), items: $0.value.items) }
        return (plain.isEmpty ? [] : [(prefix: nil, items: plain)]) + grouped
    }
}
struct PreparedCommand: Codable { var command: String; var args: [String]; var preview: String }
struct CommandCapability: Codable { var name: String; var available: Bool; var library: Bool }
struct GitCapabilities: Codable { var version: String; var commands: [CommandCapability] }
struct RebaseStep: Codable, Identifiable { var hash: String; var action: String; var id: String { hash } }
struct RebaseCandidate: Codable, Identifiable { var hash: String; var subject: String; var id: String { hash } }
struct RebaseCandidates: Codable { var head: String; var base: String; var commits: [RebaseCandidate] }
struct RebasePlan: Codable { var head: String; var base: String; var steps: [RebaseStep] }
struct TerminalLaunch: Identifiable { var id = UUID(); var root: String; var command: String; var arguments: String; var plan: RebasePlan?; var agentExecutable: String? = nil }
struct GitCatalog: Codable { var schemaVersion: Int; var gitVersion: String; var commands: [GitCommandEntry] }
struct GitCommandEntry: Codable, Identifiable, Hashable {
    var name: String; var category: String; var descriptionKey: String; var experimental: Bool; var visual: String?; var documentation: String
    var id: String { name }
}
struct GlossaryEntry: Codable, Identifiable { var id: String; var term: String; var definition: String }
enum WorkspaceRoute: String, CaseIterable, Identifiable {
    case history, changes, review, files, branches, sync, worktrees, tags, stash, remotes, reflog, pullRequests, pipelines, agents, dictionary, console
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .history: "point.3.connected.trianglepath.dotted"
        case .changes: "square.and.pencil"
        case .review: "checklist"
        case .files: "folder.badge.gearshape"
        case .branches: "arrow.triangle.branch"
        case .sync: "arrow.left.arrow.right.circle"
        case .worktrees: "square.stack.3d.up"
        case .tags: "tag"
        case .stash: "archivebox"
        case .remotes: "network"
        case .reflog: "clock.arrow.circlepath"
        case .pullRequests: "arrow.triangle.pull"
        case .pipelines: "checkmark.seal"
        case .agents: "sparkles"
        case .dictionary: "book.closed"
        case .console: "terminal"
        }
    }
    var title: String { L(rawValue) }
    /// Changes and Review are the same working-tree files (same staging) shown as a list or as a review tree.
    var isChanges: Bool { self == .changes || self == .review }
}
struct PendingOperation: Identifiable {
    var id = UUID()
    var title: String
    var root: String
    var action: String?
    var value = ""
    var command: String?
    var arguments = ""
    var preview: String
    var plan: RebasePlan?
    var interactive = false
    /// Commits to copy (newest first) onto `copyTarget` with cherry-pick.
    var copyHashes: [String] = []
    var copyTarget: String?
    var destructive = false
    var detail: String?
}
/// Read-only diff rendered natively from a whitelisted `query` (show/diff).
struct DiffRequest: Identifiable { var id = UUID(); var title: String; var subtitle: String; var args: [String] }
/// Derived views of a snapshot, computed once per snapshot instead of on every render.
/// With 1 000+ changed files and thousands of commits, recomputing these in view bodies dominated frame time.
struct ChangeIndex {
    var staged: [ChangedFile] = []
    var unstaged: [ChangedFile] = []
    var conflicts: [ChangedFile] = []
    var headHash: String?
    var reachableFromHead: Set<String> = []
    var localBranches: Set<String> = []
    init() {}
    init(_ snapshot: RepositorySnapshot) {
        for file in snapshot.files {
            if file.conflict { conflicts.append(file); continue }
            if file.index != " " && file.index != "?" { staged.append(file) }
            if file.worktree != " " || file.index == "?" { unstaged.append(file) }
        }
        headHash = snapshot.headHash
        reachableFromHead = snapshot.reachableFromHead
        localBranches = Set(snapshot.branches.map(\.name))
    }
}
/// HEAD and branch membership, observed apart from the file lists so file-only refreshes don't touch History.
struct RefIndex: Equatable {
    var headHash: String?
    var reachableFromHead: Set<String> = []
    var localBranches: Set<String> = []
}
struct HistoryModel {
    var commits: [GitCommit]; var graph: CommitGraph
    var rowIndex: [String: Int] = [:]
    init(commits: [GitCommit], graph: CommitGraph) {
        self.commits = commits; self.graph = graph
        rowIndex.reserveCapacity(commits.count)
        for (index, commit) in commits.enumerated() { rowIndex[commit.hash] = index }
    }
}
struct FileStatEntry: Codable { var path: String; var staged: Bool; var additions: Int?; var deletions: Int? }
struct BranchSyncResult: Codable, Equatable {
    var left: String; var right: String
    var onlyLeft: [GitCommit]; var onlyRight: [GitCommit]
    var equivalentLeft: [GitCommit]; var equivalentRight: [GitCommit]
    var mergeBase: String?
}
struct RewriteCommit: Codable, Identifiable, Hashable {
    var hash: String; var subject: String; var message: String; var author: String; var timestamp: String
    var id: String { hash }
    var shortHash: String { String(hash.prefix(7)) }
    var date: Date { Date(timeIntervalSince1970: Double(timestamp) ?? 0) }
}
struct RewriteCandidates: Codable { var branch: String; var head: String; var base: String; var commits: [RewriteCommit]; var boundary: String }
struct RewriteResultValue: Codable { var backup: String; var head: String }
/// One resulting commit in the organizer: a single commit or several squashed together (oldest first).
struct RewriteItem: Identifiable, Equatable {
    var id = UUID()
    var commits: [RewriteCommit]
    var message: String
    var drop = false
    var originalMessage: String
    var subject: String { message.components(separatedBy: "\n").first ?? "" }
    var changedMessage: Bool { commits.count > 1 || message.trimmingCharacters(in: .whitespacesAndNewlines) != originalMessage.trimmingCharacters(in: .whitespacesAndNewlines) }
    init(commit: RewriteCommit) { commits = [commit]; message = commit.message; originalMessage = commit.message }
    init(squashing commits: [RewriteCommit]) {
        self.commits = commits
        let first = commits.first?.subject ?? ""
        let rest = commits.dropFirst().map { "- \($0.subject)" }
        message = rest.isEmpty ? first : first + "\n\n" + rest.joined(separator: "\n")
        originalMessage = ""
    }
    /// Engine step (oldest-first hashes); message only when it changes.
    var step: [String: Any] {
        var value: [String: Any] = ["hashes": commits.map(\.hash), "drop": drop]
        if !drop && changedMessage { value["message"] = message }
        return value
    }
}
enum ChangeKind: String, CaseIterable, Identifiable {
    case added, modified, deleted, renamed, conflict
    var id: String { rawValue }
    var title: String { L("kind_\(rawValue)") }
    var plural: String { L("kinds_\(rawValue)") }
    var icon: String {
        switch self { case .added: "plus.circle.fill"; case .modified: "pencil.circle.fill"; case .deleted: "minus.circle.fill"; case .renamed: "arrow.right.circle.fill"; case .conflict: "exclamationmark.triangle.fill" }
    }
}
/// Folder tree of changed files for the reviewer; single-child folders are compacted ("app/Http/Controllers").
struct ChangeNode: Identifiable, Hashable {
    var id: String
    var name: String
    var file: ChangedFile?
    var children: [ChangeNode]?
    var files: [ChangedFile]
    var additions = 0
    var deletions = 0
    var isFolder: Bool { file == nil }

    static func tree(_ files: [ChangedFile], stats: (ChangedFile) -> LineStats?) -> [ChangeNode] {
        final class Box { var dirs: [String: Box] = [:]; var files: [ChangedFile] = [] }
        let root = Box()
        for file in files {
            var node = root
            for part in file.path.split(separator: "/").dropLast() { let key = String(part); node = node.dirs[key] ?? { let box = Box(); node.dirs[key] = box; return box }() }
            node.files.append(file)
        }
        func build(_ box: Box, prefix: String) -> [ChangeNode] {
            var result: [ChangeNode] = []
            for (name, child) in box.dirs.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
                var label = name, path = prefix + name, current = child
                while current.files.isEmpty, current.dirs.count == 1, let (next, box) = current.dirs.first { label += "/" + next; path += "/" + next; current = box }
                let children = build(current, prefix: path + "/")
                let all = children.flatMap(\.files)
                result.append(ChangeNode(id: path + "/", name: label, file: nil, children: children, files: all,
                                         additions: children.reduce(0) { $0 + $1.additions }, deletions: children.reduce(0) { $0 + $1.deletions }))
            }
            for file in box.files.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                let line = stats(file)
                result.append(ChangeNode(id: file.path, name: file.name, file: file, children: nil, files: [file], additions: line?.additions ?? 0, deletions: line?.deletions ?? 0))
            }
            return result
        }
        return build(root, prefix: "")
    }
}
/// Where a commit lives relative to main/develop, by patch content.
enum SyncMark { case onlyMain, onlyDevelop, copied }
/// Guided recovery after a pull fails; `code` comes from the engine's classification.
struct PullProblem: Identifiable { var id = UUID(); var code: String; var detail: String }
struct Toast: Identifiable, Equatable { var id = UUID(); var message: String; var icon: String; var destructive = false }
@MainActor @Observable final class StatBox {
    var value: LineStats?
    init(value: LineStats?) { self.value = value }
}
struct LineStats: Equatable {
    var additions: Int?; var deletions: Int?
    var binary: Bool { additions == nil && deletions == nil }
    static func key(_ path: String, staged: Bool) -> String { (staged ? "s:" : "u:") + path }
    /// Parses `git diff --numstat -z --no-renames`: entries `added\tdeleted\tpath\0`, `-` for binary.
    static func parseNumstat(_ text: String) -> [(path: String, stats: LineStats)] {
        text.split(separator: "\0", omittingEmptySubsequences: true).compactMap { entry in
            let fields = entry.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            return (String(fields[2]).trimmingCharacters(in: .newlines), LineStats(additions: Int(fields[0]), deletions: Int(fields[1])))
        }
    }
}
/// Splits `%D` decorations into typed references for display.
struct CommitReference: Identifiable, Hashable {
    enum Kind { case head, branch, remote, tag }
    var name: String; var kind: Kind
    var id: String { "\(kind)-\(name)" }
    static func parse(_ refs: String, localBranches: Set<String>) -> [CommitReference] {
        refs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "HEAD" }.map { item in
            if item.hasPrefix("HEAD -> ") { return CommitReference(name: String(item.dropFirst(8)), kind: .head) }
            if item.hasPrefix("tag: ") { return CommitReference(name: String(item.dropFirst(5)), kind: .tag) }
            if localBranches.contains(item) || !item.contains("/") { return CommitReference(name: item, kind: .branch) }
            return CommitReference(name: item, kind: .remote)
        }
    }
}

struct BranchDetails: Codable {
    struct Creation: Codable { var actor: String; var timestamp: Double; var event: String }
    struct Contributor: Codable, Identifiable { var name: String; var count: Int; var id: String { name } }
    struct FileChange: Codable, Identifiable { var path: String; var additions: Int?; var deletions: Int?; var id: String { path } }
    var name: String; var base: String; var head: String; var baseHead: String; var mergeBase: String?
    var total: Int; var ahead: Int; var behind: Int; var upstream: String; var tracking: [Int]?
    var creation: Creation?; var authors: [Contributor]; var commits: [GitCommit]; var files: [FileChange]
}
struct WorkingFile: Codable { var content: String; var head: String; var branch: String }
struct FileEditorTarget: Identifiable { var path: String; var id: String { path } }
