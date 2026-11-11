import Foundation
import CoreServices

/// Watches a working tree with FSEvents so edits made by agents or editors appear without manual refresh.
/// Events are coalesced by FSEvents (latency) and again by `WorkspaceStore.scheduleRefresh` (debounce).
final class RepositoryWatcher {
    private var stream: FSEventStreamRef?
    /// `true` when Git state changed (index, HEAD, refs, operations); `false` for working-tree edits only.
    private let onChange: (Bool) -> Void
    private let gitDirectory: String
    /// False in linked worktrees (`.git` is a file): their Git state lives outside the watched folder.
    private let ownsGitDirectory: Bool

    init?(root: String, latency: CFTimeInterval = 0.25, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        self.gitDirectory = (root as NSString).appendingPathComponent(".git") + "/"
        var isDirectory: ObjCBool = false
        self.ownsGitDirectory = FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(".git"), isDirectory: &isDirectory) && isDirectory.boolValue
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
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    /// Working-tree changes always count; inside `.git` only state that changes what the UI shows
    /// (index, HEAD, refs, in-progress operations). Objects, logs and lock files are noise.
    func isRelevant(_ path: String) -> Bool {
        guard path.hasPrefix(gitDirectory) else { return true }
        let inner = String(path.dropFirst(gitDirectory.count))
        if inner.hasSuffix(".lock") || inner.hasPrefix("objects/") || inner.hasPrefix("logs/") || inner.hasPrefix("fsmonitor") { return false }
        return inner == "index" || inner == "HEAD" || inner.hasPrefix("refs/") || inner == "packed-refs"
            || inner.hasPrefix("MERGE_") || inner.hasPrefix("rebase-") || inner == "CHERRY_PICK_HEAD" || inner == "REVERT_HEAD"
    }

    /// Paths inside `.git`: they can move branches, history or operations, so they need a full snapshot.
    /// A linked worktree cannot tell from here, so every event counts as Git state.
    func isGitState(_ path: String) -> Bool { !ownsGitDirectory || path.hasPrefix(gitDirectory) }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
