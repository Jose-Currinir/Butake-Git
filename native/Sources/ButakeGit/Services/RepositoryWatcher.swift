import Foundation
import CoreServices

/// Watches a working tree with FSEvents so edits made by agents or editors appear without manual refresh.
/// Events are coalesced by FSEvents (latency) and again by `WorkspaceStore.scheduleRefresh` (debounce).
final class RepositoryWatcher {
    private var stream: FSEventStreamRef?
    /// `true` when Git state changed (index, HEAD, refs, operations); `false` for working-tree edits only.
    private let onChange: (Bool) -> Void
    /// Git directories whose state matters, most specific first. A normal repository has one (`<root>/.git/`); a
    /// linked worktree has its own (`<main>/.git/worktrees/<name>/`: HEAD, index) and the shared one (refs).
    private let gitDirectories: [String]
    /// Serial: callbacks never overlap, and `deinit` can wait for the one in flight before the object goes away.
    private let queue = DispatchQueue(label: "cl.butake.git.watcher", qos: .utility)

    init?(root: String, latency: CFTimeInterval = 0.25, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        let dotGit = (root as NSString).appendingPathComponent(".git")
        var directories = [dotGit]
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory), !isDirectory.boolValue,
           let text = try? String(contentsOfFile: dotGit, encoding: .utf8), let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
            // Linked worktree: ".git" is a file pointing at the real git dir, outside the watched folder.
            let value = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
            let gitDir = URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: root, isDirectory: true)).standardizedFileURL.path
            directories = [gitDir]
            if let common = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("commondir"), encoding: .utf8) {
                directories.append(URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: URL(fileURLWithPath: gitDir, isDirectory: true)).standardizedFileURL.path)
            }
        }
        // FSEvents reports real paths (/private/tmp…, not /tmp…); the path as given is kept too.
        var prefixes: [String] = []
        for directory in directories { for path in [URL(fileURLWithPath: directory).resolvingSymlinksInPath().path, directory] where !prefixes.contains(path + "/") { prefixes.append(path + "/") } }
        self.gitDirectories = prefixes
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let relevant = list.prefix(count).filter(watcher.isRelevant)
            if !relevant.isEmpty { watcher.onChange(relevant.contains(where: watcher.isGitState)) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        let watched = [root] + directories.filter { !$0.hasPrefix(root + "/") }
        guard let stream = FSEventStreamCreate(nil, callback, &context, watched as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Path inside a watched git directory, relative to it.
    private func gitRelative(_ path: String) -> String? {
        for directory in gitDirectories where path.hasPrefix(directory) { return String(path.dropFirst(directory.count)) }
        return nil
    }

    /// Working-tree changes always count; inside a git directory only state that changes what the UI shows
    /// (index, HEAD, refs, in-progress operations). Objects, logs and lock files are noise.
    func isRelevant(_ path: String) -> Bool {
        guard let inner = gitRelative(path) else { return true }
        if inner.hasSuffix(".lock") || inner.hasPrefix("objects/") || inner.hasPrefix("logs/") || inner.hasPrefix("fsmonitor") { return false }
        return inner == "index" || inner == "HEAD" || inner.hasPrefix("refs/") || inner == "packed-refs"
            || inner.hasPrefix("MERGE_") || inner.hasPrefix("rebase-") || inner == "CHERRY_PICK_HEAD" || inner == "REVERT_HEAD"
    }

    /// Paths inside a git directory: they can move branches, history or operations, so they need a full snapshot.
    func isGitState(_ path: String) -> Bool { gitRelative(path) != nil }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        // Invalidation does not wait for a callback that is already running with an unretained pointer to `self`.
        queue.sync {}
    }
}
