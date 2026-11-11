import XCTest
@testable import ButakeGit

final class CoreTests: XCTestCase {
    private func commit(_ hash: String, _ parents: [String]) -> GitCommit { GitCommit(hash: hash, parents: parents, author: "Test", timestamp: "1781000000", subject: hash, refs: "") }
    func testGraphPreservesForkAndMergeEdges() {
        let graph = CommitGraph(commits: [commit("merge", ["left", "right"]), commit("left", ["base"]), commit("right", ["base"]), commit("base", [])])
        XCTAssertEqual(graph.width, 2)
        XCTAssertEqual(graph.rows[0].outgoing.count, 2)
        XCTAssertTrue(graph.rows[2].outgoing.contains { $0.startsAtNode && $0.from == 1 && $0.to == 0 })
        XCTAssertTrue(graph.rows[3].outgoing.isEmpty)
    }
    func testNumstatReferencesAndBranchLabels() {
        let stats = LineStats.parseNumstat("3\t1\tsrc/a b.swift\0-\t-\timg.png\0")
        XCTAssertEqual(stats.count, 2)
        XCTAssertEqual(stats[0].path, "src/a b.swift"); XCTAssertEqual(stats[0].stats.additions, 3); XCTAssertEqual(stats[0].stats.deletions, 1)
        XCTAssertTrue(stats[1].stats.binary)
        let refs = CommitReference.parse("HEAD -> develop, origin/develop, feature/x, tag: v1.0", localBranches: ["develop", "feature/x"])
        XCTAssertEqual(refs.map(\.kind), [.head, .remote, .branch, .tag])
        XCTAssertEqual(refs.last?.name, "v1.0")
        var tip = commit("merge", ["left", "right"]); tip.refs = "HEAD -> develop"
        var side = commit("right", ["base"]); side.refs = "feature"
        let labels = CommitGraph.branchLabels([tip, commit("left", ["base"]), side, commit("base", [])], localBranches: ["develop", "feature"])
        XCTAssertEqual(labels["left"], "develop"); XCTAssertEqual(labels["base"], "develop"); XCTAssertEqual(labels["right"], "feature")
        let files = CommitFileChange.parse(status: "M\0a.txt\0A\0b.txt\0", numstat: "2\t0\ta.txt\0")
        XCTAssertEqual(files.map(\.status), ["M", "A"]); XCTAssertEqual(files[0].stats.additions, 2)
    }
    func testLineLookupAndChangeIndex() {
        let ranges = (0..<1000).map { NSRange(location: $0 * 10, length: 10) }
        XCTAssertEqual(lineIndex(for: 0, in: ranges), 0)
        XCTAssertEqual(lineIndex(for: 9_995, in: ranges), 999)
        XCTAssertEqual(lineIndex(for: 4_321, in: ranges), 432)
        XCTAssertNil(lineIndex(for: 10_000, in: ranges))
        let files = [ChangedFile(path: "a", index: "M", worktree: "M"), ChangedFile(path: "b", index: "?", worktree: "?"), ChangedFile(path: "c", index: "U", worktree: "U"), ChangedFile(path: "d", index: "A", worktree: " ")]
        var head = commit("h", ["p"]); head.refs = "HEAD -> develop"
        let snapshot = RepositorySnapshot(root: "/r", branch: "develop", files: files, commits: [head, commit("p", []), commit("x", ["p"])], branches: [GitBranch(name: "develop", current: true, upstream: "")], operation: "", ahead: 0, behind: 0, remote: "")
        let index = ChangeIndex(snapshot)
        XCTAssertEqual(index.staged.map(\.path), ["a", "d"]); XCTAssertEqual(index.unstaged.map(\.path), ["a", "b"]); XCTAssertEqual(index.conflicts.map(\.path), ["c"])
        XCTAssertEqual(index.headHash, "h"); XCTAssertEqual(index.reachableFromHead, ["h", "p"])
        XCTAssertTrue(DiffView.capped(String(repeating: "x\n", count: DiffView.maxLines + 50)).contains("50"))
    }
    func testChangeTreeCompactsFoldersAndCounts() {
        let files = ["app/Http/Controllers/A.php", "app/Http/Controllers/B.php", "app/Models/User.php", "README.md"].map { ChangedFile(path: $0, index: " ", worktree: "M") }
        let tree = ChangeNode.tree(files) { _ in LineStats(additions: 2, deletions: 1) }
        XCTAssertEqual(tree.map(\.name), ["app", "README.md"])
        let app = tree[0]
        XCTAssertEqual(app.files.count, 3); XCTAssertEqual(app.additions, 6); XCTAssertEqual(app.deletions, 3)
        XCTAssertEqual(app.children?.map(\.name), ["Http/Controllers", "Models/User.php"].map { $0.components(separatedBy: "/").count > 1 && $0.hasSuffix(".php") ? "Models" : $0 })
        XCTAssertEqual(app.children?.first?.children?.map(\.name), ["A.php", "B.php"])
    }
    func testChangeKinds() {
        XCTAssertEqual(ChangedFile(path: "n", index: "?", worktree: "?").kind, .added)
        XCTAssertEqual(ChangedFile(path: "a", index: "A", worktree: " ").kind, .added)
        XCTAssertEqual(ChangedFile(path: "d", index: " ", worktree: "D").kind, .deleted)
        XCTAssertEqual(ChangedFile(path: "r", originalPath: "o", index: "R", worktree: " ").kind, .renamed)
        XCTAssertEqual(ChangedFile(path: "m", index: "M", worktree: "M").kind, .modified)
        XCTAssertEqual(ChangedFile(path: "c", index: "U", worktree: "U").kind, .conflict)
    }
    func testDiffUsesOriginalAndNewLineNumbers() {
        let diff = UnifiedDiff("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -5,2 +7,2 @@\n-old\n+new\n same\n")
        XCTAssertEqual(diff.lines[0].kind, .hunk)
        XCTAssertEqual(diff.lines[1].oldLine, 5); XCTAssertNil(diff.lines[1].newLine)
        XCTAssertEqual(diff.lines[2].newLine, 7); XCTAssertNil(diff.lines[2].oldLine)
        XCTAssertEqual(diff.lines[3].oldLine, 6); XCTAssertEqual(diff.lines[3].newLine, 8)
        XCTAssertFalse(diff.lines.contains { $0.text.hasPrefix("+++") })
    }
    func testMultiFileShowKeepsFileHeadersOutOfChanges() {
        let diff = UnifiedDiff("abc123 feat: x\n\ndiff --git a/one b/one\nindex 1..2 100644\n--- a/one\n+++ b/one\n@@ -1 +1 @@\n-a\n+b\ndiff --git a/two b/two\n--- a/two\n+++ b/two\n@@ -3 +3 @@\n-c\n+d\n")
        XCTAssertEqual(diff.lines.filter { $0.kind == .metadata }.map(\.text), ["▸ one", "▸ two"])
        XCTAssertEqual(diff.lines.filter { $0.kind == .deletion }.count, 2)
        XCTAssertEqual(diff.lines.filter { $0.kind == .addition }.count, 2)
        XCTAssertFalse(diff.lines.contains { $0.text.hasPrefix("---") || $0.text.hasPrefix("+++") })
        XCTAssertEqual(diff.lines.first?.text, "abc123 feat: x")
    }
    func testCommitHeaderMarkerResetsPreamble() {
        let diff = UnifiedDiff("\u{1}aaa feat: a\n\n---\n a.txt | 1 +\n\ndiff --git a/a.txt b/a.txt\n@@ -0,0 +1 @@\n+a\n\u{1}bbb feat: b\n\n---\n b.txt | 1 +\n\ndiff --git a/b.txt b/b.txt\n@@ -0,0 +1 @@\n+b\n")
        XCTAssertEqual(diff.lines.filter { $0.kind == .addition }.count, 2)
        XCTAssertEqual(diff.lines.filter { $0.kind == .deletion }.count, 0)
        XCTAssertTrue(diff.lines.contains { $0.kind == .metadata && $0.text == "bbb feat: b" })
        XCTAssertFalse(diff.lines.contains { $0.text.contains("b.txt | 1") && $0.newLine != nil })
    }
    func testUntrackedAndBinaryPreviewsStayVisible() {
        XCTAssertEqual(UnifiedDiff("hello\nworld").lines[1].newLine, 2)
        XCTAssertFalse(UnifiedDiff("diff --git a/a b/a\nBinary files differ\n").lines.isEmpty)
    }
    func testCatalogHasEveryDescriptionAndUniqueKeys() {
        let store = CatalogStore()
        XCTAssertEqual(store.catalog.commands.count, 152)
        XCTAssertEqual(Set(store.catalog.commands.map(\.name)).count, 152)
        for command in store.catalog.commands { XCTAssertNotNil(store.descriptions[command.descriptionKey]) }
        XCTAssertGreaterThan(store.glossary.count, 50)
        XCTAssertEqual(Set(store.glossary.map(\.id)).count, store.glossary.count)
    }
    func testProviderRemoteRejectsCredentialsAndOtherHosts() throws {
        let remote = try BitbucketRepository(remote: "git@bitbucket.org:workspace/project.git")
        XCTAssertEqual(remote.endpoint, "repositories/workspace/project")
        XCTAssertThrowsError(try BitbucketRepository(remote: "https://user:token@bitbucket.org/workspace/project.git"))
        XCTAssertThrowsError(try BitbucketRepository(remote: "https://evil.org/workspace/project.git"))
        XCTAssertThrowsError(try BitbucketRepository(remote: "https://bitbucket.org/workspace/project?secret"))
        let github = try HostedRepository(remote: "git@github.com:butake/gestion.git")
        XCTAssertEqual(github.provider, .github); XCTAssertEqual(github.path, "butake/gestion")
        XCTAssertEqual(try HostedRepository(remote: "https://github.com/butake/gestion").path, "butake/gestion")
        XCTAssertEqual(try HostedRepository(remote: "ssh://git@bitbucket.org/ws/repo.git").provider, .bitbucket)
        XCTAssertThrowsError(try HostedRepository(remote: "https://user:tok@github.com/a/b.git"))
        XCTAssertThrowsError(try HostedRepository(remote: "https://github.com/a/../b"))
        XCTAssertThrowsError(try HostedRepository(remote: "https://gitlab.com/a/b.git"))
        XCTAssertThrowsError(try BitbucketRepository(remote: "git@github.com:a/b.git"))
    }
    func testCredentialURLRedactionAndQuoting() {
        XCTAssertEqual(redactURL("https://name:secret@bitbucket.org/x/y (fetch)"), "https://•••@bitbucket.org/x/y (fetch)")
        XCTAssertEqual(shellQuote("a'b $(unsafe)"), "'a'\\''b $(unsafe)'")
    }
    func testNativeEngineProtocolAgainstTemporaryRepository() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = GitEngine(executable: root.appendingPathComponent("engine/target/debug/butake-git-engine"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let _: String = try await engine.call(["method": "run", "path": directory.path, "command": "init", "arguments": "-b develop", "confirmed": true])
        for (key, value) in [("user.name", "Test"), ("user.email", "test@example.invalid")] { let _: String = try await engine.call(["method": "run", "path": directory.path, "command": "config", "arguments": "\(key) \(shellQuote(value))", "confirmed": true]) }
        try "example\n".write(to: directory.appendingPathComponent("example.txt"), atomically: true, encoding: .utf8)
        let _: String = try await engine.call(["method": "action", "path": directory.path, "action": "stage", "value": "example.txt"])
        let snapshot: RepositorySnapshot = try await engine.call(["method": "snapshot", "path": directory.path])
        XCTAssertEqual(snapshot.branch, "develop"); XCTAssertEqual(snapshot.staged.first?.path, "example.txt")
        let file: WorkingFile = try await engine.call(["method": "readFile", "path": directory.path, "file": "example.txt"])
        XCTAssertEqual(file.branch, "develop"); XCTAssertEqual(file.content, "example\n")
        let _: String = try await engine.call(["method": "saveFile", "path": directory.path, "file": "example.txt", "content": "edited\n", "expected": file.content, "head": file.head, "branch": file.branch, "confirmed": true])
        let staged: String = try await engine.query(directory.path, ["show", ":example.txt"])
        XCTAssertEqual(staged, "example\n")
        let _: String = try await engine.call(["method": "action", "path": directory.path, "action": "commit", "value": "test: protocol", "confirmed": true])
        let _: String = try await engine.call(["method": "run", "path": directory.path, "command": "branch", "arguments": "baseline", "confirmed": true])
        let branch: BranchDetails = try await engine.call(["method": "branchDetails", "path": directory.path, "branch": "develop", "base": "baseline"])
        XCTAssertEqual(branch.total, 1); XCTAssertEqual(branch.ahead, 0); XCTAssertEqual(branch.behind, 0)
        XCTAssertEqual(branch.commits.first?.hash, branch.head)
        let capabilities: GitCapabilities = try await engine.call(["method": "capabilities"])
        XCTAssertEqual(capabilities.commands.count, 152)
        XCTAssertTrue(capabilities.commands.first { $0.name == "status" }?.available == true)
    }
    @MainActor func testFileTypesAndFriendlyHistoryText() {
        XCTAssertEqual(FileType.of("resources/views/welcome.blade.php").name, "Blade")
        XCTAssertEqual(FileType.of("app/Http/Kernel.php").label, "PHP")
        XCTAssertEqual(FileType.of("src/pages/index.astro").name, "Astro")
        XCTAssertEqual(FileType.of("scripts/run.py").name, "Python")
        XCTAssertEqual(FileType.of("src/types.d.ts").label, "DTS")
        XCTAssertEqual(FileType.of(".env.production").label, "ENV")
        XCTAssertEqual(FileType.of("package.json").label, "NPM")
        XCTAssertEqual(FileType.of("archivo.desconocido").label, "DES")
        let hosted = try? HostedRepository(remote: "https://user@bitbucket.org/equipo/app_movil.git")
        XCTAssertEqual(hosted?.provider, .bitbucket); XCTAssertEqual(hosted?.path, "equipo/app_movil")
        let icons = MaterialFileIcons.shared
        XCTAssertEqual(icons.iconName(for: "resources/views/welcome.blade.php", light: false), "laravel")
        XCTAssertEqual(icons.iconName(for: "src/pages/index.astro", light: false), "astro")
        XCTAssertEqual(icons.iconName(for: "scripts/run.py", light: false), "python")
        XCTAssertEqual(icons.iconName(for: "README.md", light: false), "readme")
        XCTAssertEqual(icons.iconName(for: ".env", light: false), "tune")
        XCTAssertEqual(icons.iconName(for: "sin-extension-rara", light: false), "file")
        XCTAssertNotNil(icons.image(for: "app/Http/Kernel.php", light: false))
        let checkout = ReflogStep("checkout: moving from develop to main")
        XCTAssertEqual(checkout.title, "develop → main")
        XCTAssertEqual(ReflogStep("reset: moving to HEAD~1").title, "HEAD~1")
        XCTAssertEqual(ReflogStep("commit (amend): arreglo").title, "arreglo")
        XCTAssertEqual(humanizeStash("On develop: probar header").0, "develop")
        XCTAssertEqual(humanizeStash("On develop: probar header").1, "probar header")
        XCTAssertEqual(humanizeStash("mensaje libre").0, nil)
    }
    func testPullRequestSuggestionsAndProviderDates() {
        let body = "Usa comparación estricta.\n\n```suggestion\n    if ($a === null) return null;\n```"
        XCTAssertEqual(PRSuggestion.extract(body)?.lines, ["    if ($a === null) return null;"])
        XCTAssertEqual(PRSuggestion.stripping(body), "Usa comparación estricta.")
        let hunk = "@@ -1,3 +1,3 @@\n a\n-b\n+if ($a == null) return null;"
        XCTAssertEqual(PRSuggestion.extract(body)?.diff(original: hunk), "-if ($a == null) return null;\n+    if ($a === null) return null;")
        XCTAssertNil(PRSuggestion.extract("sin sugerencia"))
        XCTAssertNotNil(parseProviderDate("2026-11-10T12:30:00Z"))
        XCTAssertNotNil(parseProviderDate("2026-11-10T12:30:00.123456+00:00"))
        XCTAssertNil(parseProviderDate("ayer"))
    }
    func testUpdateVersionComparison() {
        XCTAssertTrue(UpdateService.isNewer("1.0.3", than: "1.0.2"))
        XCTAssertTrue(UpdateService.isNewer("v1.1", than: "1.0.9"))
        XCTAssertTrue(UpdateService.isNewer("2.0.0", than: "1.10.0"))
        XCTAssertFalse(UpdateService.isNewer("1.0.2", than: "1.0.2"))
        XCTAssertFalse(UpdateService.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(UpdateService.isNewer("1.0.1", than: "1.0.10"))
    }
    func testUpdateReleaseParsing() throws {
        let json = """
        {"tag_name":"v1.0.3","body":"Notas","html_url":"https://github.com/Jose-Currinir/Butake-Git/releases/tag/v1.0.3","published_at":"2026-11-10T19:16:47Z",
         "assets":[{"name":"Butake-Git.dmg.sha256","browser_download_url":"https://example.com/a.sha256"},{"name":"Butake-Git.dmg","browser_download_url":"https://example.com/a.dmg"}]}
        """
        let release = try UpdateService.parse(Data(json.utf8))
        XCTAssertEqual(release.version, "1.0.3")
        XCTAssertEqual(release.dmg.absoluteString, "https://example.com/a.dmg")
        XCTAssertEqual(release.checksum?.absoluteString, "https://example.com/a.sha256")
        XCTAssertNotNil(release.published)
    }
    func testSearchQueryParsing() {
        let query = SearchQuery("tarifa @autor:Camila @file:\"Perfil con mapa\" @extension:.PHP @ext:ts")
        XCTAssertEqual(query.text, "tarifa")
        XCTAssertEqual(query.authors, ["Camila"])
        XCTAssertEqual(query.files, ["Perfil con mapa"])
        XCTAssertEqual(query.exts, ["php", "ts"])
        XCTAssertTrue(query.hasPathFilters)
        XCTAssertTrue(query.matches(author: "Camila Rojas"))
        XCTAssertFalse(query.matches(author: "Tomás Fuentes"))
        XCTAssertTrue(SearchQuery("@ext:php").matches(path: "app/Tarifa.php"))
        XCTAssertFalse(SearchQuery("@ext:php").matches(path: "app/carrito.ts"))
        XCTAssertTrue(SearchQuery("@ ").isEmpty)
        let tracked = ["app/Services/Envios/Tarifa.php", "docs/a.md", "resources/js/carrito.ts"]
        XCTAssertEqual(SearchQuery("@archivo:tarifa").matchingPaths(in: tracked), ["app/Services/Envios/Tarifa.php"])
        XCTAssertEqual(SearchQuery("@ext:.md").matchingPaths(in: tracked), ["docs/a.md"])
        XCTAssertEqual(SearchQuery("@archivo:Envios @ext:php").matchingPaths(in: tracked), ["app/Services/Envios/Tarifa.php"])
    }
}
