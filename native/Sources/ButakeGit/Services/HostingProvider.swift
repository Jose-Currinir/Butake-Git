import Foundation
import Security

/// Code hosting providers with a REST integration. Git itself works with any remote; these add PRs, checks and CI.
enum HostingProvider: String, CaseIterable, Identifiable, Codable {
    case github, bitbucket
    var id: String { rawValue }
    var title: String { self == .github ? "GitHub" : "Bitbucket Cloud" }
    var host: String { self == .github ? "github.com" : "bitbucket.org" }
    var apiBase: String { self == .github ? "https://api.github.com/" : "https://api.bitbucket.org/2.0/" }
    var apiHost: String { self == .github ? "api.github.com" : "api.bitbucket.org" }
    var keychainService: String { self == .github ? "cl.butake.git.github" : "cl.butake.git.bitbucket" }
    /// Bitbucket API tokens authenticate with the Atlassian account email; GitHub tokens stand alone.
    var needsEmail: Bool { self == .bitbucket }
    /// Page where the user creates the token.
    var tokenURL: URL {
        switch self {
        case .github: URL(string: "https://github.com/settings/personal-access-tokens/new")!
        case .bitbucket: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!
        }
    }
    var docsURL: URL {
        switch self {
        case .github: URL(string: "https://docs.github.com/es/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens")!
        case .bitbucket: URL(string: "https://support.atlassian.com/bitbucket-cloud/docs/using-api-tokens/")!
        }
    }
    /// Minimum permissions, shown verbatim so the user can tick them while creating the token.
    var permissions: [String] {
        switch self {
        case .github: ["Repository access: los repositorios que usarás", "Pull requests: Read and write", "Contents: Read-only", "Commit statuses: Read-only", "Checks: Read-only", "Actions: Read-only", "Metadata: Read-only (obligatorio)", "Administration: Read and write (sólo para publicar repos nuevos)"]
        case .bitbucket: ["read:user:bitbucket", "read:workspace:bitbucket", "read:repository:bitbucket", "admin:repository:bitbucket (sólo para publicar repos nuevos)", "read:pullrequest:bitbucket", "write:pullrequest:bitbucket", "read:pipeline:bitbucket"]
        }
    }
    func webCompareURL(_ repo: HostedRepository, branch: String) -> URL? {
        let encoded = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        switch self {
        case .github: return URL(string: "https://github.com/\(repo.owner)/\(repo.name)/compare/\(encoded)?expand=1")
        case .bitbucket: return URL(string: "https://bitbucket.org/\(repo.owner)/\(repo.name)/pull-requests/new?source=\(encoded)")
        }
    }
}

/// `owner/name` on a supported host, parsed strictly from the `origin` URL.
struct HostedRepository: Hashable {
    var provider: HostingProvider; var owner: String; var name: String
    var path: String { "\(owner)/\(name)" }
    init(remote: String) throws {
        var value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        // "https://user@bitbucket.org/…" (Bitbucket's default HTTPS clone URL): the user part is not part of the repository.
        // A password or token ("user:secret@") is still rejected: credentials do not belong in remotes.
        if value.hasPrefix("https://"), let at = value.firstIndex(of: "@"), let slash = value.dropFirst(8).firstIndex(of: "/"), at < slash,
           !value[value.index(value.startIndex, offsetBy: 8)..<at].contains(":") {
            value = "https://" + value[value.index(after: at)...]
        }
        var detected: (HostingProvider, String)?
        // Hosts are case-insensitive; SSH over 443 uses an alternate host name (ssh.github.com, altssh.bitbucket.org).
        let lowered = value.lowercased()
        for provider in HostingProvider.allCases {
            let hosts = [provider.host] + (provider == .github ? ["ssh.github.com"] : ["altssh.bitbucket.org"])
            for host in hosts {
                for prefix in ["git@\(host):", "https://\(host)/", "ssh://git@\(host)/", "ssh://git@\(host):22/", "ssh://git@\(host):443/"] where lowered.hasPrefix(prefix) {
                    detected = (provider, String(value.dropFirst(prefix.count)))
                }
            }
        }
        guard let (provider, rawPath) = detected else { throw EngineFailure(code: "remote", detail: L("unsupportedRemote")) }
        var path = rawPath
        if path.hasSuffix("/") { path = String(path.dropLast()) }
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let allowed: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy(allowed) }) else {
            throw EngineFailure(code: "remote", detail: L("unsupportedRemote"))
        }
        self.provider = provider; owner = String(parts[0]); name = String(parts[1])
    }
}
/// Kept for the existing call sites and tests: a Bitbucket-only view of `HostedRepository`.
struct BitbucketRepository: Hashable {
    var workspace: String; var slug: String
    var endpoint: String { "repositories/\(workspace)/\(slug)" }
    init(remote: String) throws {
        let repo = try HostedRepository(remote: remote)
        guard repo.provider == .bitbucket else { throw EngineFailure(code: "remote", detail: L("unsupportedRemote")) }
        workspace = repo.owner; slug = repo.name
    }
}

struct ProviderCredentials: Codable { var email: String; var token: String }
/// Tokens live only in the Keychain, one item per provider.
enum ProviderVault {
    /// Read once per provider and kept in memory. The Keychain call is synchronous and can wait on a system
    /// permission prompt: views used to make it on every render, on the main thread, and froze the window.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [HostingProvider: ProviderCredentials?] = [:]
    static func load(_ provider: HostingProvider) throws -> ProviderCredentials? {
        lock.lock(); let cached = cache[provider]; lock.unlock()
        if let cached { return cached }
        let value = try read(provider)
        lock.lock(); cache[provider] = .some(value); lock.unlock()
        return value
    }
    private static func remember(_ credentials: ProviderCredentials?, for provider: HostingProvider) {
        lock.lock(); cache[provider] = .some(credentials); lock.unlock()
        Task { @MainActor in ProviderAccounts.shared.set(provider, connected: credentials != nil) }
    }
    private static func read(_ provider: HostingProvider) throws -> ProviderCredentials? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: provider.keychainService, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw EngineFailure(code: "keychain", detail: SecCopyErrorMessageString(status, nil) as String? ?? L("credentialsMissing")) }
        return try JSONDecoder().decode(ProviderCredentials.self, from: data)
    }
    static func save(_ credentials: ProviderCredentials, for provider: HostingProvider) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: provider.keychainService]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        let status: OSStatus
        if update == errSecItemNotFound {
            var insertion = query; insertion[kSecAttrAccount as String] = provider.rawValue; insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insertion as CFDictionary, nil)
        } else { status = update }
        guard status == errSecSuccess else { throw EngineFailure(code: "keychain", detail: SecCopyErrorMessageString(status, nil) as String? ?? L("credentialsMissing")) }
        remember(credentials, for: provider)
    }
    static func remove(_ provider: HostingProvider) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: provider.keychainService] as CFDictionary)
        remember(nil, for: provider)
    }
}

/// Which providers have a saved account, for views. Loaded off the main thread; views read `connected` and never
/// touch the Keychain themselves.
@MainActor @Observable final class ProviderAccounts {
    static let shared = ProviderAccounts()
    private(set) var connected: Set<HostingProvider> = []
    private(set) var loaded = false
    @ObservationIgnored private var loading: Task<Void, Never>?
    func isConnected(_ provider: HostingProvider) -> Bool { connected.contains(provider) }
    fileprivate func set(_ provider: HostingProvider, connected value: Bool) { if value { connected.insert(provider) } else { connected.remove(provider) } }
    /// Reads the Keychain once, in the background. Safe to call repeatedly; callers that need the answer await it.
    func ensureLoaded() async {
        if loaded { return }
        if loading == nil {
            loading = Task {
                let found = await Task.detached(priority: .userInitiated) { Set(HostingProvider.allCases.filter { ((try? ProviderVault.load($0)) ?? nil) != nil }) }.value
                self.connected = found; self.loaded = true
            }
        }
        await loading?.value
    }
}

// MARK: - Provider-neutral models

enum PRState: String, CaseIterable, Identifiable { case open, merged, closed; var id: String { rawValue } }
struct HostedPR: Identifiable, Hashable {
    var id: Int; var title: String; var body: String; var state: PRState; var author: String
    var source: String; var target: String; var sourceSHA: String?; var url: URL?
    var updated: Date? = nil; var draft = false
}
/// Conversation entry; inline review comments carry the file, line and the diff hunk they refer to.
struct HostedComment: Identifiable, Hashable {
    var id: Int; var author: String; var body: String
    var created: Date? = nil; var path: String? = nil; var line: Int? = nil; var hunk: String? = nil; var url: URL? = nil
    var bot: Bool { author.hasSuffix("[bot]") || author.lowercased().contains("bot") }
}
/// A repository the connected account can clone.
struct HostedRemoteRepository: Identifiable, Hashable {
    var provider: HostingProvider; var fullName: String; var sshURL: String; var httpsURL: String; var updated: Date?; var isPrivate: Bool; var summary: String
    var id: String { "\(provider.rawValue):\(fullName)" }
}
enum ReviewVerdict: String { case approved, changesRequested, commented }
struct HostedReview: Identifiable, Hashable { var author: String; var verdict: ReviewVerdict; var id: String { author } }
enum CheckState { case success, failure, pending, neutral }
struct HostedCheck: Identifiable, Hashable { var id: String; var name: String; var state: CheckState; var detail: String; var url: URL?; var duration: TimeInterval? = nil }
/// ISO 8601 dates from GitHub ("…Z") and Bitbucket ("….123456+00:00").
func parseProviderDate(_ text: String?) -> Date? {
    guard let text else { return nil }
    let plain = ISO8601DateFormatter(); let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = plain.date(from: text) ?? fractional.date(from: text) { return date }
    // Bitbucket may send 6 fractional digits; trim to milliseconds.
    if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
        let trimmed = String(text[..<dot]) + String(text[dot..<zone].prefix(4)) + String(text[zone...])
        return fractional.date(from: trimmed)
    }
    return nil
}
struct HostedRun: Identifiable, Hashable { var id: String; var number: Int; var name: String; var state: CheckState; var detail: String; var ref: String; var url: URL? }

// MARK: - Wire formats

private struct GHUser: Decodable { var login: String; var name: String? }
private struct GHRef: Decodable { var ref: String; var sha: String? }
private struct GHPull: Decodable {
    var number: Int; var title: String; var body: String?; var state: String; var user: GHUser; var head: GHRef; var base: GHRef
    var html_url: String?; var merged_at: String?; var updated_at: String?; var draft: Bool?
}
private struct GHComment: Decodable { var id: Int; var user: GHUser?; var body: String?; var created_at: String?; var html_url: String?; var path: String?; var line: Int?; var original_line: Int?; var diff_hunk: String? }
private struct GHReview: Decodable { var user: GHUser?; var state: String }
private struct GHCheckRuns: Decodable { var check_runs: [GHCheck]; struct GHCheck: Decodable { var id: Int; var name: String; var status: String; var conclusion: String?; var html_url: String?; var started_at: String?; var completed_at: String? } }
private struct GHRuns: Decodable { var workflow_runs: [GHRun]; struct GHRun: Decodable { var id: Int; var run_number: Int; var name: String?; var status: String?; var conclusion: String?; var head_branch: String?; var html_url: String? } }
private struct BBPage<T: Decodable>: Decodable { var values: [T]; var next: String? }
private struct BBUser: Decodable { var display_name: String? }
private struct BBLink: Decodable { var html: Href?; struct Href: Decodable { var href: String } }
private struct BBRevision: Decodable { var branch: Name; var commit: Hash?; struct Name: Decodable { var name: String }; struct Hash: Decodable { var hash: String } }
private struct BBPull: Decodable { var id: Int; var title: String; var description: String?; var state: String; var author: BBUser; var source: BBRevision; var destination: BBRevision; var links: BBLink; var updated_on: String?; var draft: Bool? }
private struct BBComment: Decodable { var id: Int; var user: BBUser?; var content: Content; var created_on: String?; var inline: Inline?; var links: BBLink?; var deleted: Bool?
    struct Content: Decodable { var raw: String? }; struct Inline: Decodable { var path: String?; var to: Int?; var from: Int? } }
private struct BBPullDetail: Decodable { var participants: [Participant]; struct Participant: Decodable { var user: BBUser?; var approved: Bool?; var state: String? } }
private struct BBStatus: Decodable { var key: String; var name: String?; var state: String; var url: String? }
private struct BBPipeline: Decodable { var uuid: String; var build_number: Int; var state: State; var target: Target?; struct State: Decodable { var name: String; var result: Result?; struct Result: Decodable { var name: String } }; struct Target: Decodable { var ref_name: String? } }
private struct Ignored: Decodable {}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // Credentials must never follow a redirect to another host. A redirect inside the provider's own API host
    // (a renamed or transferred repository answers 301) is followed, keeping the request's credentials.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest, let host = original.url?.host, request.url?.host == host, request.url?.scheme == "https" else { completionHandler(nil); return }
        var next = request
        if next.value(forHTTPHeaderField: "Authorization") == nil, let authorization = original.value(forHTTPHeaderField: "Authorization") { next.setValue(authorization, forHTTPHeaderField: "Authorization") }
        completionHandler(next)
    }
}

/// One client for both providers; every request goes to the provider's fixed API host.
actor HostingClient {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    private func send<T: Decodable>(_ provider: HostingProvider, _ endpoint: String, method: String = "GET", body: [String: Any]? = nil, credentials override: ProviderCredentials? = nil) async throws -> T {
        guard let credentials = try override ?? ProviderVault.load(provider) else {
            throw EngineFailure(code: "credentials", detail: String(format: L("providerNotConnected"), provider.title))
        }
        guard !endpoint.contains(".."), let url = URL(string: provider.apiBase + endpoint), url.host == provider.apiHost, url.scheme == "https" else {
            throw EngineFailure(code: "url", detail: L("networkError"))
        }
        var request = URLRequest(url: url); request.httpMethod = method
        switch provider {
        case .github:
            request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        case .bitbucket:
            request.setValue("Basic " + Data("\(credentials.email):\(credentials.token)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        request.setValue("Butake-Git", forHTTPHeaderField: "User-Agent")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { ($0["message"] as? String) ?? (($0["error"] as? [String: Any])?["message"] as? String) } ?? ""
            let key = switch status { case 401: "httpUnauthorized"; case 403: "httpForbidden"; case 404: "httpNotFound"; case 405, 409, 422: "httpRejected"; default: "networkError" }
            throw EngineFailure(code: "http\(status)", detail: String(format: L(key), provider.title) + (message.isEmpty ? "" : "\n\(message)"))
        }
        if T.self == Ignored.self || data.isEmpty { return try JSONDecoder().decode(T.self, from: Data("{}".utf8)) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Every page of a GitHub list (`per_page` in the endpoint), up to `maxPages`.
    private func githubAll<T: Decodable>(_ endpoint: String, perPage: Int = 100, maxPages: Int = 10) async throws -> [T] {
        var all: [T] = []
        for page in 1...maxPages {
            let items: [T] = try await send(.github, endpoint + (endpoint.contains("?") ? "&" : "?") + "page=\(page)")
            all += items
            if items.count < perPage { break }
        }
        return all
    }
    /// Every page of a Bitbucket list (`pagelen` in the endpoint), up to `maxPages`.
    private func bitbucketAll<T: Decodable>(_ endpoint: String, maxPages: Int = 10) async throws -> [T] {
        var all: [T] = []
        for page in 1...maxPages {
            let result: BBPage<T> = try await send(.bitbucket, endpoint + (endpoint.contains("?") ? "&" : "?") + "page=\(page)")
            all += result.values
            if result.next == nil || result.values.isEmpty { break }
        }
        return all
    }

    /// Validates credentials and returns the account's display name.
    func verify(_ provider: HostingProvider, credentials: ProviderCredentials) async throws -> String {
        switch provider {
        case .github: let user: GHUser = try await send(provider, "user", credentials: credentials); return user.name.map { "\($0) (\(user.login))" } ?? user.login
        case .bitbucket: let user: BBUser = try await send(provider, "user", credentials: credentials); return user.display_name ?? credentials.email
        }
    }

    enum ProtectionLookup: Equatable { case known(Bool), unknown, unreachable }
    /// Whether the provider blocks direct pushes to `branch`; nil when the rules cannot be read.
    func branchProtected(_ repo: HostedRepository, branch: String = "main") async -> Bool? {
        if case let .known(value) = await branchProtection(repo, branch: branch) { return value }
        return nil
    }
    /// Like `branchProtected`, telling "the token cannot read the rules" (403/404: unknown) apart from "the provider
    /// did not answer" (offline, expired token, rate limit: unreachable, the cached rule stays).
    func branchProtection(_ repo: HostedRepository, branch: String = "main") async -> ProtectionLookup {
        guard branch.allSatisfy({ $0.isLetter || $0.isNumber || "-_./".contains($0) }) else { return .unknown }
        func failure(_ error: Error) -> ProtectionLookup {
            let code = (error as? EngineFailure)?.code ?? ""
            return code == "http403" || code == "http404" ? .unknown : .unreachable
        }
        switch repo.provider {
        case .github:
            let info: GHBranch
            do { info = try await send(.github, "repos/\(repo.path)/branches/\(branch)") } catch { return failure(error) }
            if info.protected { return .known(true) }
            // Rulesets do not always set `protected`; a pull-request or update rule also blocks direct pushes.
            let rules: [GHRule]? = try? await send(.github, "repos/\(repo.path)/rules/branches/\(branch)")
            return .known(rules.map { $0.contains { ["pull_request", "update"].contains($0.type) } } ?? false)
        case .bitbucket:
            let restrictions: [BBRestriction]
            do { restrictions = try await bitbucketAll("repositories/\(repo.path)/branch-restrictions?kind=push&pagelen=100") } catch { return failure(error) }
            return .known(restrictions.contains { restriction in
                // Branching-model restrictions target the production branch (usually main).
                if restriction.branch_match_kind == "branching_model" { return restriction.branch_type == "production" }
                guard let pattern = restriction.pattern else { return false }
                return NSPredicate(format: "SELF LIKE %@", pattern).evaluate(with: branch)
            })
        }
    }

    func pullRequests(_ repo: HostedRepository, state: PRState) async throws -> [HostedPR] {
        switch repo.provider {
        case .github:
            let pulls: [GHPull] = try await send(.github, "repos/\(repo.path)/pulls?state=\(state == .open ? "open" : "closed")&per_page=50&sort=updated&direction=desc")
            return pulls.compactMap { pull in
                let merged = pull.merged_at != nil
                let mapped: PRState = pull.state == "open" ? .open : merged ? .merged : .closed
                guard mapped == state else { return nil }
                return HostedPR(id: pull.number, title: pull.title, body: pull.body ?? "", state: mapped, author: pull.user.login, source: pull.head.ref, target: pull.base.ref, sourceSHA: pull.head.sha, url: pull.html_url.flatMap(URL.init(string:)), updated: parseProviderDate(pull.updated_at), draft: pull.draft ?? false)
            }
        case .bitbucket:
            let remote = ["open": "OPEN", "merged": "MERGED", "closed": "DECLINED"][state.rawValue]!
            let page: BBPage<BBPull> = try await send(.bitbucket, "repositories/\(repo.path)/pullrequests?state=\(remote)&pagelen=50&sort=-updated_on")
            return page.values.map { pull in
                HostedPR(id: pull.id, title: pull.title, body: pull.description ?? "", state: state, author: pull.author.display_name ?? "—", source: pull.source.branch.name, target: pull.destination.branch.name, sourceSHA: pull.source.commit?.hash, url: pull.links.html.flatMap { URL(string: $0.href) }, updated: parseProviderDate(pull.updated_on), draft: pull.draft ?? false)
            }
        }
    }

    func comments(_ repo: HostedRepository, pr: Int) async throws -> [HostedComment] {
        switch repo.provider {
        case .github:
            // Conversation comments plus inline review comments (file, line and diff hunk).
            async let general: [GHComment] = githubAll("repos/\(repo.path)/issues/\(pr)/comments?per_page=100")
            async let inline: [GHComment] = githubAll("repos/\(repo.path)/pulls/\(pr)/comments?per_page=100")
            let items = try await general + ((try? await inline) ?? [])
            return items.map { HostedComment(id: $0.id, author: $0.user?.login ?? "—", body: $0.body ?? "", created: parseProviderDate($0.created_at), path: $0.path, line: $0.line ?? $0.original_line, hunk: $0.diff_hunk, url: $0.html_url.flatMap(URL.init(string:))) }
                .sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
        case .bitbucket:
            let values: [BBComment] = try await bitbucketAll("repositories/\(repo.path)/pullrequests/\(pr)/comments?pagelen=100")
            return values.filter { $0.deleted != true }.map { HostedComment(id: $0.id, author: $0.user?.display_name ?? "—", body: $0.content.raw ?? "", created: parseProviderDate($0.created_on), path: $0.inline?.path, line: $0.inline?.to ?? $0.inline?.from, url: $0.links?.html.flatMap { URL(string: $0.href) }) }
                .sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
        }
    }

    /// Repositories of the connected account, most recently updated first.
    /// `knownOwners`: workspaces already seen in local remotes, used when the token cannot list workspaces.
    func repositories(_ provider: HostingProvider, knownOwners: [String] = []) async throws -> [HostedRemoteRepository] {
        switch provider {
        case .github:
            let items: [GHRepo] = try await githubAll("user/repos?per_page=100&sort=updated")
            return items.map { HostedRemoteRepository(provider: .github, fullName: $0.full_name, sshURL: $0.ssh_url, httpsURL: $0.clone_url, updated: parseProviderDate($0.updated_at), isPrivate: $0.private, summary: $0.description ?? "") }
        case .bitbucket:
            // Cross-workspace listing was removed by Atlassian: list workspaces first, then each one's repositories.
            var owners: [String] = []
            if let values: [BBWorkspaceAccess] = try? await bitbucketAll("user/workspaces?pagelen=100") { owners = values.compactMap { $0.workspace?.slug } }
            else if let values: [BBWorkspace] = try? await bitbucketAll("workspaces?role=member&pagelen=100") { owners = values.compactMap(\.slug) }
            for owner in knownOwners where !owners.contains(owner) { owners.append(owner) }
            guard !owners.isEmpty else { throw EngineFailure(code: "no_workspaces", detail: L("bitbucketNoWorkspaces")) }
            var repos: [BBRepo] = []; var lastError: Error?
            for owner in owners where owner.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) {
                do { let values: [BBRepo] = try await bitbucketAll("repositories/\(owner)?pagelen=100&sort=-updated_on"); repos += values }
                catch { lastError = error }
            }
            if repos.isEmpty, let lastError { throw lastError }
            return repos.map { repo in
                let links = repo.links.clone ?? []
                return HostedRemoteRepository(provider: .bitbucket, fullName: repo.full_name, sshURL: links.first { $0.name == "ssh" }?.href ?? "git@bitbucket.org:\(repo.full_name).git", httpsURL: links.first { $0.name == "https" }?.href.replacingOccurrences(of: #"https://[^@]+@"#, with: "https://", options: .regularExpression) ?? "https://bitbucket.org/\(repo.full_name).git", updated: parseProviderDate(repo.updated_on), isPrivate: repo.is_private ?? true, summary: repo.description ?? "")
            }
        }
    }

    /// Where the account can create repositories: GitHub user and organizations, Bitbucket workspaces.
    func owners(_ provider: HostingProvider, knownOwners: [String] = []) async throws -> [String] {
        switch provider {
        case .github:
            let user: GHUser = try await send(.github, "user")
            let orgs: [GHOrg] = (try? await githubAll("user/orgs?per_page=100")) ?? []
            return [user.login] + orgs.map(\.login)
        case .bitbucket:
            var owners: [String] = []
            if let values: [BBWorkspaceAccess] = try? await bitbucketAll("user/workspaces?pagelen=100") { owners = values.compactMap { $0.workspace?.slug } }
            for owner in knownOwners where !owners.contains(owner) { owners.append(owner) }
            if owners.isEmpty { throw EngineFailure(code: "no_workspaces", detail: L("bitbucketNoWorkspaces")) }
            return owners
        }
    }

    /// An existing repository, or nil when it does not exist / is not visible to the token.
    func repository(_ provider: HostingProvider, owner: String, name: String) async -> HostedRemoteRepository? {
        switch provider {
        case .github:
            guard let repo: GHRepo = try? await send(.github, "repos/\(owner)/\(name)") else { return nil }
            return HostedRemoteRepository(provider: .github, fullName: repo.full_name, sshURL: repo.ssh_url, httpsURL: repo.clone_url, updated: parseProviderDate(repo.updated_at), isPrivate: repo.private, summary: repo.description ?? "")
        case .bitbucket:
            guard let repo: BBRepo = try? await send(.bitbucket, "repositories/\(owner)/\(name.lowercased())") else { return nil }
            let links = repo.links.clone ?? []
            return HostedRemoteRepository(provider: .bitbucket, fullName: repo.full_name, sshURL: links.first { $0.name == "ssh" }?.href ?? "git@bitbucket.org:\(repo.full_name).git", httpsURL: links.first { $0.name == "https" }?.href.replacingOccurrences(of: #"https://[^@]+@"#, with: "https://", options: .regularExpression) ?? "https://bitbucket.org/\(repo.full_name).git", updated: parseProviderDate(repo.updated_on), isPrivate: repo.is_private ?? true, summary: repo.description ?? "")
        }
    }

    /// Creates an empty repository (no README, so the first push is a plain fast-forward).
    func createRepository(_ provider: HostingProvider, owner: String, name: String, isPrivate: Bool, summary: String) async throws -> HostedRemoteRepository {
        let allowed: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        guard !name.isEmpty, name.allSatisfy(allowed), owner.allSatisfy(allowed) else { throw EngineFailure(code: "invalid_name", detail: L("publishInvalidName")) }
        switch provider {
        case .github:
            let me: GHUser = try await send(.github, "user")
            let endpoint = owner == me.login ? "user/repos" : "orgs/\(owner)/repos"
            let repo: GHRepo = try await send(.github, endpoint, method: "POST", body: ["name": name, "private": isPrivate, "description": summary, "auto_init": false])
            return HostedRemoteRepository(provider: .github, fullName: repo.full_name, sshURL: repo.ssh_url, httpsURL: repo.clone_url, updated: Date(), isPrivate: repo.private, summary: summary)
        case .bitbucket:
            let slug = name.lowercased()
            let repo: BBRepo = try await send(.bitbucket, "repositories/\(owner)/\(slug)", method: "POST", body: ["scm": "git", "is_private": isPrivate, "description": summary])
            let links = repo.links.clone ?? []
            return HostedRemoteRepository(provider: .bitbucket, fullName: repo.full_name, sshURL: links.first { $0.name == "ssh" }?.href ?? "git@bitbucket.org:\(repo.full_name).git", httpsURL: links.first { $0.name == "https" }?.href.replacingOccurrences(of: #"https://[^@]+@"#, with: "https://", options: .regularExpression) ?? "https://bitbucket.org/\(repo.full_name).git", updated: Date(), isPrivate: isPrivate, summary: summary)
        }
    }

    /// Latest verdict per reviewer.
    func reviews(_ repo: HostedRepository, pr: Int) async throws -> [HostedReview] {
        switch repo.provider {
        case .github:
            let items: [GHReview] = try await githubAll("repos/\(repo.path)/pulls/\(pr)/reviews?per_page=100")
            var latest: [String: ReviewVerdict] = [:]; var order: [String] = []
            for review in items {
                guard let author = review.user?.login else { continue }
                let verdict: ReviewVerdict? = switch review.state { case "APPROVED": .approved; case "CHANGES_REQUESTED": .changesRequested; case "COMMENTED": latest[author] == nil ? .commented : nil; case "DISMISSED": .commented; default: nil }
                if let verdict { if latest[author] == nil { order.append(author) }; latest[author] = verdict }
            }
            return order.map { HostedReview(author: $0, verdict: latest[$0]!) }
        case .bitbucket:
            let detail: BBPullDetail = try await send(.bitbucket, "repositories/\(repo.path)/pullrequests/\(pr)")
            return detail.participants.compactMap { participant in
                guard let name = participant.user?.display_name else { return nil }
                let verdict: ReviewVerdict = participant.approved == true || participant.state == "approved" ? .approved : participant.state == "changes_requested" ? .changesRequested : .commented
                return verdict == .commented ? nil : HostedReview(author: name, verdict: verdict)
            }
        }
    }

    func checks(_ repo: HostedRepository, sha: String) async throws -> [HostedCheck] {
        guard sha.allSatisfy(\.isHexDigit) else { return [] }
        switch repo.provider {
        case .github:
            var checkRuns: [GHCheckRuns.GHCheck] = []
            for page in 1...5 {
                let runs: GHCheckRuns = try await send(.github, "repos/\(repo.path)/commits/\(sha)/check-runs?per_page=100&page=\(page)")
                checkRuns += runs.check_runs
                if runs.check_runs.count < 100 { break }
            }
            return checkRuns.map { check in
                let state: CheckState = check.status != "completed" ? .pending : check.conclusion == "success" ? .success : ["failure", "timed_out", "cancelled", "action_required"].contains(check.conclusion ?? "") ? .failure : .neutral
                let duration = parseProviderDate(check.completed_at).flatMap { end in parseProviderDate(check.started_at).map { end.timeIntervalSince($0) } }
                return HostedCheck(id: "\(check.id)", name: check.name, state: state, detail: check.conclusion ?? check.status, url: check.html_url.flatMap(URL.init(string:)), duration: duration)
            }
        case .bitbucket:
            let statuses: [BBStatus] = try await bitbucketAll("repositories/\(repo.path)/commit/\(sha)/statuses?pagelen=100")
            return statuses.map { status in
                let state: CheckState = switch status.state { case "SUCCESSFUL": .success; case "FAILED", "STOPPED": .failure; case "INPROGRESS": .pending; default: .neutral }
                return HostedCheck(id: status.key, name: status.name ?? status.key, state: state, detail: status.state, url: status.url.flatMap(URL.init(string:)))
            }
        }
    }

    func runs(_ repo: HostedRepository) async throws -> [HostedRun] {
        switch repo.provider {
        case .github:
            let runs: GHRuns = try await send(.github, "repos/\(repo.path)/actions/runs?per_page=40")
            return runs.workflow_runs.map { run in
                let state: CheckState = run.status != "completed" ? .pending : run.conclusion == "success" ? .success : run.conclusion == "failure" ? .failure : .neutral
                return HostedRun(id: "\(run.id)", number: run.run_number, name: run.name ?? "Workflow", state: state, detail: run.conclusion ?? run.status ?? "", ref: run.head_branch ?? "—", url: run.html_url.flatMap(URL.init(string:)))
            }
        case .bitbucket:
            let page: BBPage<BBPipeline> = try await send(.bitbucket, "repositories/\(repo.path)/pipelines/?pagelen=40&sort=-created_on")
            return page.values.map { pipeline in
                let result = pipeline.state.result?.name
                let state: CheckState = result == nil ? .pending : result == "SUCCESSFUL" ? .success : result == "FAILED" ? .failure : .neutral
                return HostedRun(id: pipeline.uuid, number: pipeline.build_number, name: "Pipeline", state: state, detail: result ?? pipeline.state.name, ref: pipeline.target?.ref_name ?? "—", url: URL(string: "https://bitbucket.org/\(repo.path)/pipelines/results/\(pipeline.build_number)"))
            }
        }
    }

    func createPR(_ repo: HostedRepository, title: String, body: String, source: String, target: String) async throws {
        switch repo.provider {
        case .github: let _: Ignored = try await send(.github, "repos/\(repo.path)/pulls", method: "POST", body: ["title": title, "body": body, "head": source, "base": target])
        case .bitbucket: let _: Ignored = try await send(.bitbucket, "repositories/\(repo.path)/pullrequests", method: "POST", body: ["title": title, "description": body, "source": ["branch": ["name": source]], "destination": ["branch": ["name": target]], "close_source_branch": false])
        }
    }

    func approve(_ repo: HostedRepository, pr: Int) async throws {
        switch repo.provider {
        case .github: let _: Ignored = try await send(.github, "repos/\(repo.path)/pulls/\(pr)/reviews", method: "POST", body: ["event": "APPROVE"])
        case .bitbucket: let _: Ignored = try await send(.bitbucket, "repositories/\(repo.path)/pullrequests/\(pr)/approve", method: "POST")
        }
    }

    func merge(_ repo: HostedRepository, pr: Int) async throws {
        switch repo.provider {
        case .github: let _: Ignored = try await send(.github, "repos/\(repo.path)/pulls/\(pr)/merge", method: "PUT", body: [:])
        case .bitbucket: let _: Ignored = try await send(.bitbucket, "repositories/\(repo.path)/pullrequests/\(pr)/merge", method: "POST", body: ["close_source_branch": false])
        }
    }

    func comment(_ repo: HostedRepository, pr: Int, text: String) async throws {
        switch repo.provider {
        case .github: let _: Ignored = try await send(.github, "repos/\(repo.path)/issues/\(pr)/comments", method: "POST", body: ["body": text])
        case .bitbucket: let _: Ignored = try await send(.bitbucket, "repositories/\(repo.path)/pullrequests/\(pr)/comments", method: "POST", body: ["content": ["raw": text]])
        }
    }
}

private struct GHBranch: Decodable { var protected: Bool }
private struct GHRule: Decodable { var type: String }
private struct BBRestriction: Decodable { var kind: String; var pattern: String?; var branch_match_kind: String?; var branch_type: String? }
private struct GHRepo: Decodable { var full_name: String; var ssh_url: String; var clone_url: String; var updated_at: String?; var `private`: Bool; var description: String? }
private struct BBRepo: Decodable { var full_name: String; var updated_on: String?; var is_private: Bool?; var description: String?; var links: Links
    struct Links: Decodable { var clone: [Clone]? }; struct Clone: Decodable { var name: String; var href: String } }
private struct BBWorkspace: Decodable { var slug: String? }
private struct BBWorkspaceAccess: Decodable { var workspace: BBWorkspace? }
private struct GHOrg: Decodable { var login: String }
