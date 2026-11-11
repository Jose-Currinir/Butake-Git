import SwiftUI
import AppKit

/// Clone from an address or from the connected GitHub/Bitbucket accounts, into a folder you choose.
struct CloneRepositorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: WorkspaceStore
    @State private var url = ""
    @State private var name = ""
    @State private var nameEdited = false
    @State private var parent = CloneRepositorySheet.defaultParent
    @State private var useSSH = true
    @State private var accounts: [HostedRemoteRepository] = []
    @State private var loadingAccounts = false
    @State private var accountErrors: [String] = []
    @State private var query = ""
    @State private var selected: String?
    @State private var cloning = false
    @State private var error = ""
    private let client = HostingClient()

    static var defaultParent: String {
        UserDefaults.standard.string(forKey: "cloneParent") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer").path
    }
    private var connected: [HostingProvider] { HostingProvider.allCases.filter(ProviderAccounts.shared.isConnected) }
    private var filtered: [HostedRemoteRepository] { accounts.filter { query.isEmpty || $0.fullName.localizedCaseInsensitiveContains(query) } }
    private var target: String { (parent as NSString).appendingPathComponent(name) }
    private var urlLooksValid: Bool { url.hasPrefix("https://") || url.hasPrefix("ssh://") || (url.hasPrefix("git@") && url.contains(":")) }
    private var exists: Bool { !name.isEmpty && FileManager.default.fileExists(atPath: target) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.on.square").font(.ui(size: 20, weight: .medium)).foregroundStyle(Brand.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("cloneRepository")).font(.ui(size: 15, weight: .semibold))
                    Text(L("cloneSubtitle")).font(.uiCaption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(18)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("cloneAddress")).font(.ui(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    TextField("git@bitbucket.org:equipo/repositorio.git", text: $url)
                        .textFieldStyle(.roundedBorder).font(.ui(size: 12, design: .monospaced)).accessibilityIdentifier("clone.url")
                        .onChange(of: url) { _, value in selected = accounts.first { $0.sshURL == value || $0.httpsURL == value }?.id; if !nameEdited { name = Self.folderName(value) } }
                    if !url.isEmpty && !urlLooksValid { Label(L("cloneInvalidURL"), systemImage: "exclamationmark.circle").font(.uiCaption).foregroundStyle(Brand.warning) }
                }
                if !connected.isEmpty { accountsList }
                else { Label(L("cloneConnectHint"), systemImage: "person.crop.circle.badge.plus").font(.uiCaption).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("cloneDestination")).font(.ui(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Label(abbreviatePath(parent), systemImage: "folder").lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 5).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        Button(L("chooseFolder")) { chooseParent() }.accessibilityIdentifier("clone.chooseFolder")
                    }
                    HStack(spacing: 8) {
                        Text(L("cloneFolderName")).font(.uiCaption).foregroundStyle(.secondary)
                        TextField(L("cloneFolderName"), text: Binding(get: { name }, set: { name = $0; nameEdited = true })).textFieldStyle(.roundedBorder).accessibilityIdentifier("clone.name")
                    }
                    if exists { Label(String(format: L("cloneFolderExists"), name), systemImage: "exclamationmark.triangle.fill").font(.uiCaption).foregroundStyle(Brand.warning) }
                    else if !name.isEmpty { Text(String(format: L("cloneWillCreate"), abbreviatePath(target))).font(.uiCaption).foregroundStyle(.tertiary) }
                }
                if !error.isEmpty { Label(error, systemImage: "xmark.octagon.fill").font(.uiCaption).foregroundStyle(Brand.danger).textSelection(.enabled) }
            }.padding(18)
            Spacer(minLength: 0)
            Divider()
            HStack {
                if cloning { Spinner(size: 14); Text(L("cloning")).font(.uiCaption).foregroundStyle(.secondary) }
                Spacer()
                Button(L("cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(cloning)
                Button(L("cloneAction")) { Task { await clone() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!urlLooksValid || name.isEmpty || exists || cloning).accessibilityIdentifier("clone.submit")
            }.padding(14)
        }
        .frame(width: 640, height: connected.isEmpty ? 420 : 620)
        .task {
            await ProviderAccounts.shared.ensureLoaded()
            // Without a saved choice, clone next to the repository you have open (e.g. ~/Herd).
            if UserDefaults.standard.string(forKey: "cloneParent") == nil, let root = store.repository?.root { parent = (root as NSString).deletingLastPathComponent }
            if url.isEmpty, let pasted = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), pasted.count < 300, pasted.hasPrefix("git@") || (pasted.hasPrefix("https://") && pasted.hasSuffix(".git")) { url = pasted }
            await loadAccounts()
        }
    }

    private var accountsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("cloneYourRepositories")).font(.ui(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $useSSH) { Text("SSH").tag(true); Text("HTTPS").tag(false) }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help(L("cloneProtocolHelp"))
                    .onChange(of: useSSH) { _, ssh in if let repo = accounts.first(where: { $0.id == selected }) { url = ssh ? repo.sshURL : repo.httpsURL } }
            }
            TextField(L("cloneSearch"), text: $query).textFieldStyle(.roundedBorder)
            List(filtered, selection: $selected) { repo in
                HStack(spacing: 8) {
                    Image(systemName: repo.provider == .github ? "chevron.left.forwardslash.chevron.right" : "shippingbox").foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) { Text(repo.fullName).font(.ui(size: 12, weight: .medium)).lineLimit(1); if repo.isPrivate { Image(systemName: "lock.fill").font(.ui(size: 8)).foregroundStyle(.tertiary) } }
                        if !repo.summary.isEmpty { Text(repo.summary).font(.uiCaption2).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    if let updated = repo.updated { Text(RelativeDateCache.shared.text(for: updated)).font(.uiCaption2).foregroundStyle(.tertiary) }
                }.padding(.vertical, 2).tag(repo.id)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false)).themedScroll().frame(minHeight: 150)
            .overlay {
                if loadingAccounts { Spinner(size: 18) }
                else if accounts.isEmpty { Text(accountErrors.isEmpty ? L("cloneNoRepositories") : accountErrors.joined(separator: "\n")).font(.uiCaption).foregroundStyle(accountErrors.isEmpty ? Color.secondary : Brand.warning).multilineTextAlignment(.center).padding() }
            }
            .onChange(of: selected) { _, id in if let repo = accounts.first(where: { $0.id == id }) { url = useSSH ? repo.sshURL : repo.httpsURL; nameEdited = false; name = Self.folderName(url) } }
        }
    }

    static func folderName(_ url: String) -> String {
        let tail = url.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        return tail.hasSuffix(".git") ? String(tail.dropLast(4)) : tail
    }
    private func loadAccounts() async {
        guard !connected.isEmpty else { return }
        loadingAccounts = true; defer { loadingAccounts = false }
        var all: [HostedRemoteRepository] = []; accountErrors = []
        for provider in connected {
            let owners = await store.knownOwners(provider)
            do { all += try await client.repositories(provider, knownOwners: owners) }
            catch { accountErrors.append(String(format: L("cloneAccountError"), provider.title, error.localizedDescription)) }
        }
        accounts = all.sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
    }
    private func chooseParent() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = L("chooseFolder"); panel.directoryURL = URL(fileURLWithPath: parent)
        if panel.runModal() == .OK, let url = panel.url { parent = url.path; UserDefaults.standard.set(parent, forKey: "cloneParent") }
    }
    private func clone() async {
        error = ""; cloning = true; defer { cloning = false }
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        do {
            let path: String = try await store.engine.call(["method": "clone", "path": parent, "url": url.trimmingCharacters(in: .whitespacesAndNewlines), "name": name])
            UserDefaults.standard.set(parent, forKey: "cloneParent")
            dismiss()
            await store.open(path)
            store.notify(String(format: L("cloneDone"), name), icon: "checkmark.circle.fill")
        } catch { self.error = error.localizedDescription }
    }
}
