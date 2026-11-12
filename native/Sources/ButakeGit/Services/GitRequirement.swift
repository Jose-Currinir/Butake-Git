import AppKit
import Foundation

/// Butake Git runs the real `git`. On a Mac without Apple's command line tools `/usr/bin/git` is only a
/// stub that fails, so before anything else the app looks for a working Git (Apple's tools, or Homebrew's)
/// and, when there is none, offers Apple's official installer and continues by itself once it finishes.
@MainActor @Observable final class GitRequirement {
    static let shared = GitRequirement()
    enum State: Equatable { case checking, ready(String), missing, installing }
    private(set) var state: State = .checking
    var ready: Bool { if case .ready = state { return true } else { return false } }
    var showingSheet: Bool {
        get { state == .missing || state == .installing }
        set { }
    }

    /// Looks for Git; a Homebrew copy is put first on PATH so the engine (a child process) uses it.
    func check() async {
        if case .ready = state { return }
        let found = await Task.detached { GitRequirement.locate() }.value
        if let found {
            let folder = (found as NSString).deletingLastPathComponent
            let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            if folder != "/usr/bin", !path.split(separator: ":").contains(Substring(folder)) { setenv("PATH", folder + ":" + path, 1) }
            state = .ready(found)
        } else if state != .installing {
            state = .missing
        }
    }

    /// Suspends until Git works; while it is missing the sheet stays up and Git is looked for every few seconds.
    func waitUntilReady() async {
        await check()
        while !ready {
            try? await Task.sleep(for: .seconds(4))
            await check()
        }
    }

    /// Apple's own installer for the command line tools (Git included); it shows its own dialog.
    func installAppleTools() {
        state = .installing
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/xcode-select"), arguments: ["--install"])
    }

    nonisolated static func locate() -> String? {
        #if DEBUG || BUTAKE_QA
        if ProcessInfo.processInfo.environment["BUTAKE_FAKE_NO_GIT"] != nil { return nil }
        #endif
        // /usr/bin/git only works when xcode-select points at installed tools; calling the stub otherwise would
        // pop up Apple's installer by surprise.
        if run("/usr/bin/xcode-select", ["-p"]), run("/usr/bin/git", ["--version"]) { return "/usr/bin/git" }
        for candidate in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where FileManager.default.isExecutableFile(atPath: candidate) {
            if run(candidate, ["--version"]) { return candidate }
        }
        return nil
    }
    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
