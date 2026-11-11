import SwiftUI
import AppKit

/// New local repository: folder + name, `main` with a `.gitignore` as first commit, optional `develop`.
struct NewRepositorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: WorkspaceStore
    @State private var name = ""
    @State private var parent = CloneRepositorySheet.defaultParent
    @State private var withDevelop = true
    @State private var working = false
    @State private var error = ""
    private var target: String { (parent as NSString).appendingPathComponent(name) }
    private var isRepository: Bool { FileManager.default.fileExists(atPath: (target as NSString).appendingPathComponent(".git")) }
    private var valid: Bool { !name.isEmpty && !name.hasPrefix(".") && !name.hasPrefix("-") && !name.contains("/") && !isRepository }
    var body: some View {
        VStack(spacing: 0) {
            CreationHeader(icon: "plus.rectangle.on.folder", title: L("newRepository"), subtitle: L("newRepositorySubtitle"))
            Divider()
            Form {
                TextField(L("repositoryName"), text: $name, prompt: Text("mi-proyecto")).accessibilityIdentifier("newRepo.name")
                LabeledContent(L("cloneDestination")) {
                    HStack {
                        Text(abbreviatePath(parent)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button(L("chooseFolder")) { chooseParent() }
                    }
                }
                Toggle(L("newRepositoryDevelop"), isOn: $withDevelop).help(L("newRepositoryDevelopHelp"))
                if !name.isEmpty {
                    if isRepository { Label(String(format: L("newRepositoryExists"), name), systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.warning).font(.uiCaption) }
                    else { Text(String(format: FileManager.default.fileExists(atPath: target) ? L("newRepositoryInExisting") : L("cloneWillCreate"), abbreviatePath(target))).font(.uiCaption).foregroundStyle(.secondary) }
                }
                Text(L("newRepositoryContents")).font(.uiCaption).foregroundStyle(.secondary)
                if !error.isEmpty { Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Brand.danger).font(.uiCaption) }
            }.formStyle(.grouped).themedScroll()
            Divider()
            HStack {
                if working { Spinner(size: 14) }
                Spacer()
                Button(L("cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("create")) { Task { await create() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!valid || working).accessibilityIdentifier("newRepo.create")
            }.padding(14)
        }
        .frame(width: 560, height: 430)
        .task { if UserDefaults.standard.string(forKey: "cloneParent") == nil, let root = store.repository?.root { parent = (root as NSString).deletingLastPathComponent } }
    }
    private func chooseParent() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = L("chooseFolder"); panel.directoryURL = URL(fileURLWithPath: parent)
        if panel.runModal() == .OK, let url = panel.url { parent = url.path; UserDefaults.standard.set(parent, forKey: "cloneParent") }
    }
    private func create() async {
        working = true; error = ""; defer { working = false }
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        do {
            let path: String = try await store.engine.call(["method": "init", "path": parent, "name": name.trimmingCharacters(in: .whitespaces), "develop": withDevelop])
            dismiss(); await store.open(path)
            store.notify(String(format: L("newRepositoryDone"), name), icon: "checkmark.circle.fill")
        } catch { self.error = error.localizedDescription }
    }
}

/// Publishes a local-only repository: creates it on GitHub/Bitbucket, adds `origin` and pushes the branches.
struct PublishRepositorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: WorkspaceStore
    @State private var provider: HostingProvider = .bitbucket
    @State private var owners: [String] = []
    @State private var owner = ""
    @State private var name = ""
    @State private var summary = ""
    @State private var isPrivate = true
    @State private var useSSH = true
    @State private var branches: Set<String> = []
    @State private var loading = false
    @State private var working = false
    @State private var confirming = false
    @State private var error = ""
    private let client = HostingClient()
    private var connected: [HostingProvider] { HostingProvider.allCases.filter(ProviderAccounts.shared.isConnected) }
    private var localBranches: [String] { store.repository?.branches.map(\.name) ?? [] }
    private var slug: String { provider == .bitbucket ? name.lowercased() : name }
    /// origin already points to this repository (a previous attempt created it): only push.
    private var resuming: Bool {
        guard let origin = store.repository?.remote, let hosted = try? HostedRepository(remote: origin) else { return false }
        return hosted.provider == provider && hosted.owner.caseInsensitiveCompare(owner) == .orderedSame && hosted.name.caseInsensitiveCompare(slug) == .orderedSame
    }
    private func urls(owner: String, name: String) -> (ssh: String, https: String) { ("git@\(provider.host):\(owner)/\(name).git", "https://\(provider.host)/\(owner)/\(name).git") }
    private var valid: Bool { !owner.isEmpty && !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } && !branches.isEmpty && !working }
    var body: some View {
        VStack(spacing: 0) {
            CreationHeader(icon: "icloud.and.arrow.up", title: L("publishRepository"), subtitle: L("publishSubtitle"))
            Divider()
            if connected.isEmpty {
                VStack(spacing: 12) {
                    EmptyState(L("publishNoAccount"), systemImage: "person.crop.circle.badge.exclamationmark", description: Text(L("publishNoAccountDetail")))
                    SettingsLink { Text(L("openAccounts")) }
                }.frame(maxHeight: .infinity)
            } else {
                Form {
                    Picker(L("publishProvider"), selection: $provider) { ForEach(connected, id: \.self) { Text($0.title).tag($0) } }
                        .onChange(of: provider) { _, value in useSSH = value == .bitbucket; Task { await loadOwners() } }
                    Picker(provider == .bitbucket ? L("publishWorkspace") : L("publishOwner"), selection: $owner) { ForEach(owners, id: \.self) { Text($0).tag($0) } }
                        .overlay(alignment: .trailing) { if loading { Spinner(size: 14).padding(.trailing, 28) } }
                    TextField(L("repositoryName"), text: $name).accessibilityIdentifier("publish.name")
                    TextField(L("description"), text: $summary, prompt: Text(L("optional")))
                    Toggle(L("publishPrivate"), isOn: $isPrivate)
                    Picker(L("publishProtocol"), selection: $useSSH) { Text("SSH").tag(true); Text("HTTPS").tag(false) }.pickerStyle(.segmented).help(L("cloneProtocolHelp"))
                    LabeledContent(L("publishBranches")) {
                        // Scrolls sideways and builds lazily: one checkbox per branch in a plain HStack grew the sheet with many branches.
                        ScrollView(.horizontal, showsIndicators: false) { LazyHStack(spacing: 10) { ForEach(localBranches, id: \.self) { branch in Toggle(branch, isOn: Binding(get: { branches.contains(branch) }, set: { if $0 { branches.insert(branch) } else { branches.remove(branch) } })).toggleStyle(.checkbox).accessibilityIdentifier("publish.branch.\(branch)") } } }.frame(height: 22)
                    }
                    if !owner.isEmpty && !name.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("publishSteps")).font(.uiCaption.weight(.semibold))
                            if resuming { Text("1. " + String(format: L("publishStepExisting"), provider.title, "\(owner)/\(slug)")) }
                            else { Text("1. " + String(format: L("publishStepCreate"), provider.title, "\(owner)/\(slug)", L(isPrivate ? "publishPrivateShort" : "publishPublicShort"))) }
                            Text("2. " + L(resuming ? "publishStepRemoteUpdate" : "publishStepRemote"))
                            Text("3. " + String(format: L("publishStepPush"), branches.sorted().joined(separator: ", ")))
                        }.font(.uiCaption).foregroundStyle(.secondary)
                    }
                    if !error.isEmpty { Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Brand.danger).font(.uiCaption).textSelection(.enabled) }
                }.formStyle(.grouped).themedScroll()
            }
            Divider()
            HStack {
                if working { Spinner(size: 14); Text(L("publishing")).font(.uiCaption).foregroundStyle(.secondary) }
                Spacer()
                Button(L("cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                // Publishing is outward-facing: click only, never Return.
                Button(L("publishAction")) { confirming = true }.buttonStyle(.borderedProminent).disabled(!valid || connected.isEmpty).accessibilityIdentifier("publish.submit")
            }.padding(14)
        }
        .frame(width: 600, height: 600)
        .confirmationDialog(String(format: L("publishConfirm"), "\(owner)/\(slug)", provider.title), isPresented: $confirming, titleVisibility: .visible) {
            Button(L("publishAction")) { Task { await publish() } }
            Button(L("cancel"), role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { Text(L(isPrivate ? "publishConfirmPrivate" : "publishConfirmPublic")) }
        .task {
            name = store.repository?.name.replacingOccurrences(of: " ", with: "-") ?? ""
            branches = Set(localBranches.filter { $0 == store.repository?.primary || $0 == "develop" || $0 == store.repository?.branch })
            await ProviderAccounts.shared.ensureLoaded()
            // Resume a half-finished publication with the same provider; otherwise prefer Bitbucket (team workspaces).
            if let origin = store.repository?.remote, let hosted = try? HostedRepository(remote: origin), connected.contains(hosted.provider) {
                provider = hosted.provider; name = hosted.name
            } else if let first = connected.first { provider = connected.contains(.bitbucket) ? .bitbucket : first }
            useSSH = provider == .bitbucket
            await loadOwners()
        }
    }
    private func loadOwners() async {
        loading = true; defer { loading = false }; error = ""
        // Workspaces already used by other repositories you opened help when the token cannot list them.
        let known = await store.knownOwners(provider)
        do { owners = try await client.owners(provider, knownOwners: known); if !owners.contains(owner) { owner = owners.first ?? "" } }
        catch { owners = []; owner = ""; self.error = error.localizedDescription }
    }
    private func publish() async {
        guard let root = store.repository?.root else { return }
        working = true; error = ""; defer { working = false }
        do {
            var url: String; var fullName = "\(owner)/\(slug)"; var replace = false
            if resuming {
                let pair = urls(owner: owner, name: slug); url = useSSH ? pair.ssh : pair.https; replace = true
            } else {
                do {
                    let created = try await client.createRepository(provider, owner: owner, name: name, isPrivate: isPrivate, summary: summary)
                    url = useSSH ? created.sshURL : created.httpsURL; fullName = created.fullName
                } catch let failure as EngineFailure where failure.code == "http422" || failure.code == "http400" {
                    // Already exists (e.g. created by an earlier attempt): continue only if the token can see it.
                    guard let existing = await client.repository(provider, owner: owner, name: name) else { throw failure }
                    url = useSSH ? existing.sshURL : existing.httpsURL; fullName = existing.fullName
                }
            }
            let pushed: [String] = try await store.engine.call(["method": "publish", "path": root, "url": url, "branches": localBranches.filter { branches.contains($0) }, "confirmed": true, "replaceOrigin": replace])
            dismiss(); await store.refresh(); await store.syncRemoteProtection()
            store.notify(String(format: L("publishDone"), fullName, pushed.joined(separator: ", ")), icon: "checkmark.icloud.fill")
        } catch { self.error = error.localizedDescription; await store.refresh() }
    }
}

private struct CreationHeader: View {
    let icon: String; let title: String; let subtitle: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.ui(size: 20, weight: .medium)).foregroundStyle(Brand.accent)
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.ui(size: 15, weight: .semibold)); Text(subtitle).font(.uiCaption).foregroundStyle(.secondary) }
            Spacer()
        }.padding(18)
    }
}
