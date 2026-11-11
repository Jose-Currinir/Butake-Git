import SwiftUI

/// Pull requests for the repository's provider (GitHub or Bitbucket), detected from `origin`.
struct PullRequestsView: View {
    let store: WorkspaceStore
    @State private var requests: [HostedPR] = []
    @State private var selected: Int?
    @State private var state: PRState = .open
    @State private var loading = false
    @State private var error = ""
    @State private var newPR = false
    private let client = HostingClient()
    private var repo: HostedRepository? { store.repository.flatMap { try? HostedRepository(remote: $0.remote) } }
    var selectedRequest: HostedPR? { requests.first { $0.id == selected } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let repo { Label("\(repo.provider.title) · \(repo.path)", systemImage: "arrow.triangle.pull").font(.uiCaption).foregroundStyle(.secondary) }
                Picker(L("pullRequests"), selection: $state) { Text(L("prOpen")).tag(PRState.open); Text(L("prMerged")).tag(PRState.merged); Text(L("prClosed")).tag(PRState.closed) }.pickerStyle(.segmented).frame(width: 300).labelsHidden()
                Spacer()
                if loading { Spinner(size: 14) }
                Button(L("newPR")) { newPR = true }.disabled(repo == nil).accessibilityIdentifier("pr.new")
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help(L("refresh")).accessibilityLabel(L("refresh"))
            }.padding(14).background(Brand.bar)
            Divider()
            if let repo, (try? ProviderVault.load(repo.provider)) ?? nil == nil {
                ConnectProviderCard(provider: repo.provider)
            } else if repo == nil {
                ContentUnavailableView { Label(L("prEmptyTitle"), systemImage: "arrow.triangle.pull") } description: { Text(L("unsupportedRemote")) } actions: { Button(L("viewRemotes")) { store.route = .remotes }.accessibilityIdentifier("pr.viewRemotes") }.frame(maxHeight: .infinity)
            } else if !error.isEmpty && requests.isEmpty {
                VStack(spacing: 14) { ContentUnavailableView(L("pullRequests"), systemImage: "exclamationmark.triangle", description: Text(error)); AccountsLink() }.frame(maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(requests, selection: $selected) { pr in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: pr.draft ? "pencil.circle" : pr.state == .merged ? "arrow.triangle.merge" : pr.state == .closed ? "xmark.circle" : "arrow.triangle.pull")
                                .foregroundStyle(pr.draft ? Color.secondary : pr.state == .merged ? Brand.special : pr.state == .closed ? Brand.danger : Brand.accent).frame(width: 16).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(pr.title).font(.ui(size: 12.5, weight: .semibold)).lineLimit(2)
                                HStack(spacing: 4) {
                                    Text("#\(pr.id) · \(pr.author)")
                                    if let updated = pr.updated { Text("· " + RelativeDateCache.shared.text(for: updated)) }
                                }.font(.uiCaption).foregroundStyle(.secondary)
                                Text("\(pr.source) → \(pr.target)").font(.ui(size: 10, design: .monospaced)).foregroundStyle(Brand.info).lineLimit(1).truncationMode(.middle)
                            }
                        }.padding(.vertical, 5).tag(pr.id).accessibilityIdentifier("pr.\(pr.id)")
                    }
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                    .overlay { if requests.isEmpty && !loading { ContentUnavailableView(L("noPRs"), systemImage: "tray") } }
                    Divider()
                    if let pr = selectedRequest, let repo { PullRequestDetail(store: store, pr: pr, repo: repo, reload: { await load() }).frame(maxWidth: .infinity) }
                    else { ContentUnavailableView(L("pullRequests"), systemImage: "arrow.triangle.pull", description: Text(L("noSelection"))).frame(maxWidth: .infinity) }
                }
            }
        }
        .task(id: "\(state.rawValue)\(store.repository?.remote ?? "")") { await load() }
        .sheet(isPresented: $newPR) { if let repo { NewPullRequestSheet(store: store, repo: repo) { await load() }.themedSheet() } }
    }
    private func load() async {
        guard let repo, ((try? ProviderVault.load(repo.provider)) ?? nil) != nil else { return }
        loading = true; defer { loading = false }; error = ""
        do { requests = try await client.pullRequests(repo, state: state); if selected == nil || !requests.contains(where: { $0.id == selected }) { selected = requests.first?.id } }
        catch { self.error = error.localizedDescription; requests = [] }
    }
}

struct CheckIcon: View {
    let state: CheckState
    var body: some View {
        let (icon, color): (String, Color) = switch state { case .success: ("checkmark.circle.fill", Brand.accent); case .failure: ("xmark.circle.fill", Brand.danger); case .pending: ("clock.fill", Brand.warning); case .neutral: ("minus.circle", .secondary) }
        Image(systemName: icon).foregroundStyle(color)
    }
}

private struct NewPullRequestSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: WorkspaceStore; let repo: HostedRepository; let reload: () async -> Void
    @State private var title = ""; @State private var description = ""; @State private var source = ""; @State private var target = "main"; @State private var error = ""; @State private var busy = false
    private let client = HostingClient()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(L("newPR")) · \(repo.provider.title)").font(.uiTitle2.weight(.semibold))
            TextField(L("title"), text: $title).textFieldStyle(.roundedBorder).accessibilityIdentifier("pr.title")
            HStack {
                Picker(L("sourceBranch"), selection: $source) { ForEach(store.repository?.branches ?? []) { Text($0.name).tag($0.name) } }
                Image(systemName: "arrow.right")
                Picker(L("targetBranch"), selection: $target) { ForEach(store.repository?.branches ?? []) { Text($0.name).tag($0.name) } }
            }
            TextEditor(text: $description).font(.uiBody).frame(height: 170).padding(4).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6)).accessibilityLabel(L("description"))
            Text(L("prPushHint")).font(.uiCaption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).foregroundStyle(Brand.danger).font(.uiCaption).textSelection(.enabled) }
            HStack {
                if let url = repo.provider.webCompareURL(repo, branch: source) { Link(String(format: L("openIn"), repo.provider.title), destination: url).font(.uiCaption) }
                Spacer(); Button(L("cancel"), role: .cancel) { dismiss() }
                Button(L("create")) { Task { await create() } }.buttonStyle(.borderedProminent).disabled(title.isEmpty || source.isEmpty || target.isEmpty || source == target || busy).accessibilityIdentifier("pr.create")
            }
        }.padding(24).frame(width: 620)
        .onAppear {
            source = store.repository?.branch ?? ""
            let names = store.repository?.branches.map(\.name) ?? []
            let primary = store.repository?.primary ?? "main"
            target = [source == "develop" ? primary : "develop", primary, "develop"].first { $0 != source && names.contains($0) } ?? names.first { $0 != source } ?? primary
            title = store.repository?.commits.first?.subject ?? ""
        }
    }
    private func create() async {
        busy = true; defer { busy = false }
        do { try await client.createPR(repo, title: title, body: description, source: source, target: target); await reload(); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

/// CI runs: GitHub Actions or Bitbucket Pipelines.
struct PipelinesView: View {
    let store: WorkspaceStore
    @State private var runs: [HostedRun] = []
    @State private var error = ""
    @State private var loading = false
    private let client = HostingClient()
    private var repo: HostedRepository? { store.repository.flatMap { try? HostedRepository(remote: $0.remote) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(repo?.provider == .github ? L("githubActions") : L("pipelines"), systemImage: "checkmark.seal").font(.uiHeadline)
                Spacer(); if loading { Spinner(size: 14) }
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help(L("refresh")).accessibilityLabel(L("refresh"))
            }.padding(14).background(Brand.bar)
            Divider()
            if let repo, ((try? ProviderVault.load(repo.provider)) ?? nil) == nil { ConnectProviderCard(provider: repo.provider) }
            else if repo == nil { ContentUnavailableView { Label(L("prEmptyTitle"), systemImage: "checkmark.seal") } description: { Text(L("unsupportedRemote")) } actions: { Button(L("viewRemotes")) { store.route = .remotes } }.frame(maxHeight: .infinity) }
            else if !error.isEmpty { VStack(spacing: 14) { ContentUnavailableView(L("pipelines"), systemImage: "exclamationmark.triangle", description: Text(error)); AccountsLink() }.frame(maxHeight: .infinity) }
            else {
                List(runs) { run in
                    HStack(spacing: 10) {
                        CheckIcon(state: run.state)
                        Text("#\(run.number)").monospacedDigit().foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) { Text(run.name).lineLimit(1); Text(run.ref).font(.ui(size: 10, design: .monospaced)).foregroundStyle(Brand.accent) }
                        Spacer(); Text(run.detail).font(.uiCaption).foregroundStyle(.secondary)
                        if let url = run.url { Link(destination: url) { Image(systemName: "arrow.up.right.square") } }
                    }.padding(.vertical, 6)
                }.listStyle(.inset).themedScroll()
                .overlay { if runs.isEmpty && !loading { ContentUnavailableView(L("noRuns"), systemImage: "tray") } }
            }
        }.task(id: store.repository?.remote ?? "") { await load() }
    }
    private func load() async {
        guard let repo, ((try? ProviderVault.load(repo.provider)) ?? nil) != nil else { return }
        loading = true; defer { loading = false }
        do { runs = try await client.runs(repo); error = "" } catch { self.error = error.localizedDescription }
    }
}

/// Inline call to action when the repository's provider is not connected yet.
struct ConnectProviderCard: View {
    let provider: HostingProvider
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.key").font(.ui(size: 34, weight: .light)).foregroundStyle(Brand.accent)
            Text(String(format: L("connectProvider"), provider.title)).font(.uiTitle3.weight(.semibold))
            Text(String(format: L("connectProviderDetail"), provider.title)).font(.uiCallout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack { Link(destination: provider.tokenURL) { Label(L("createToken"), systemImage: "arrow.up.right.square") }.buttonStyle(.bordered); AccountsLink(prominent: true) }
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
/// Opens Settings on the "Cuentas" tab.
struct AccountsLink: View {
    var prominent = false
    @AppStorage("settingsTab") private var settingsTab = "general"
    var body: some View {
        SettingsLink { Label(L("openAccounts"), systemImage: "person.crop.circle.badge.checkmark") }
            .simultaneousGesture(TapGesture().onEnded { settingsTab = "accounts" })
            .buttonStyle(prominent ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
            .accessibilityIdentifier("accounts.open")
    }
}
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
