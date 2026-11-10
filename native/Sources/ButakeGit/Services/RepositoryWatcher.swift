import Foundation
import CoreServices

/// Watches a working tree with FSEvents so edits made by agents or editors appear without manual refresh.
/// Events are coalesced by FSEvents (latency) and again by `WorkspaceStore.scheduleRefresh` (debounce).
final class RepositoryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private let gitDirectory: String

    init?(root: String, latency: CFTimeInterval = 0.25, onChange: @escaping () -> Void) {
        self.onChange = onChange
        self.gitDirectory = (root as NSString).appendingPathComponent(".git") + "/"
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            if list.prefix(count).contains(where: watcher.isRelevant) { watcher.onChange() }
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

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
