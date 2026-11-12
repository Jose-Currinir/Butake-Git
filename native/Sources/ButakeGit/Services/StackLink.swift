import AppKit
import Foundation

/// Butake Stack, the ecosystem's local server. A repository that Stack serves as a site opens there
/// with `butakestack://site/<id>`; one that is not yet a site is offered with `butakestack://open?path=`.
/// Stack's site records are read, never written, and only for their `id` and `path`.
@MainActor enum StackLink {
    static let bundleID = "cl.butake.stack.native"
    static var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

    private struct Site: Decodable { let id: String; let path: String }
    /// The Stack site whose folder is this repository's root, if any.
    nonisolated static func site(for root: String) -> String? {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Butake Stack/projects", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        let wanted = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        for file in files where file.pathExtension == "json" {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
                  let data = try? Data(contentsOf: file),
                  let site = try? JSONDecoder().decode(Site.self, from: data) else { continue }
            if URL(fileURLWithPath: site.path).resolvingSymlinksInPath().path == wanted { return site.id }
        }
        return nil
    }
    static func openSite(_ id: String) {
        var components = URLComponents()
        components.scheme = "butakestack"; components.host = "site"; components.path = "/" + id
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
    static func add(_ root: String) {
        var components = URLComponents()
        components.scheme = "butakestack"; components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: root)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}

/// Requests from other apps to open a repository: `butakegit://open?path=…` or a folder handed to the
/// app. Requests that arrive before the window is ready wait until the workspace exists.
@MainActor enum ExternalOpen {
    static var workspace: WorkspaceStore? {
        didSet { let queued = pending; pending = []; queued.forEach(open) }
    }
    private static var pending: [String] = []

    static func handle(_ urls: [URL]) {
        for url in urls {
            if url.scheme == "butakegit" {
                guard url.host == "open",
                      let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value
                else { continue }
                open(path)
            } else if url.isFileURL {
                open(url.path)
            }
        }
    }
    /// Only an existing absolute folder is accepted; the workspace then validates it as a repository.
    private static func open(_ path: String) {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: standard, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        guard let workspace else { pending.append(standard); return }
        MainWindow.show()
        Task { await workspace.open(standard) }
    }
}
