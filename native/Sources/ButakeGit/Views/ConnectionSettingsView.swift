import SwiftUI

/// Settings: appearance and provider accounts (GitHub, Bitbucket).
struct ConnectionSettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"
    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label(L("general"), systemImage: "gearshape") }.tag("general")
            AccountsSettingsView().tabItem { Label(L("accounts"), systemImage: "person.crop.circle.badge.checkmark") }.tag("accounts")
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("notchEnabled") private var notchEnabled = true
    @AppStorage("autoFetch") private var autoFetch = true
    var body: some View {
        Form {
            Section(L("notchSection")) {
                Toggle(L("notchToggle"), isOn: $notchEnabled)
                    .onChange(of: notchEnabled) { _, _ in NotchController.shared.update() }
                    .accessibilityIdentifier("settings.notch")
                Toggle(L("autoFetchToggle"), isOn: $autoFetch)
                Text(L(NotchGeometry.current() == nil ? "notchUnavailable" : "notchHelp")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("appearance")) {
                Picker(L("appearance"), selection: $appearance) { Text(L("system")).tag("system"); Text(L("light")).tag("light"); Text(L("dark")).tag("dark") }.pickerStyle(.segmented)
            }
        }.formStyle(.grouped)
    }
}

/// Where to create each token, which permissions to tick, and a live connection test.
struct AccountsSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("accountsIntro")).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(HostingProvider.allCases) { ProviderAccountCard(provider: $0) }
                Label(L("accountsSecurity"), systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
    }
}

private struct ProviderAccountCard: View {
    let provider: HostingProvider
    @State private var email = ""
    @State private var token = ""
    @State private var connectedAs = ""
    @State private var status = ""
    @State private var failed = false
    @State private var testing = false
    @State private var saved = false
    private let client = HostingClient()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: provider == .github ? "chevron.left.forwardslash.chevron.right" : "shippingbox").font(.system(size: 16, weight: .semibold)).foregroundStyle(Brand.accent)
                    .frame(width: 32, height: 32).background(Brand.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.title).font(.headline)
                    Text(saved ? (connectedAs.isEmpty ? L("connected") : String(format: L("connectedAs"), connectedAs)) : L("notConnected"))
                        .font(.caption).foregroundStyle(saved ? Brand.accent : .secondary)
                }
                Spacer()
                Link(L("tokenDocs"), destination: provider.docsURL).font(.caption)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("step1")).font(.caption.weight(.semibold))
                Link(destination: provider.tokenURL) { Label(String(format: L("createTokenOn"), provider.title), systemImage: "arrow.up.right.square") }
                    .buttonStyle(.bordered).accessibilityIdentifier("accounts.\(provider.rawValue).create")
                Text(L(provider == .github ? "step2GitHub" : "step2Bitbucket")).font(.caption.weight(.semibold)).padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(provider.permissions, id: \.self) { permission in
                        Label(permission, systemImage: "checkmark.square").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                Text(L("step3")).font(.caption.weight(.semibold)).padding(.top, 4)
            }
            if provider.needsEmail { TextField(L("email"), text: $email).textContentType(.emailAddress).textFieldStyle(.roundedBorder).accessibilityIdentifier("accounts.\(provider.rawValue).email") }
            SecureField(saved ? L("tokenSavedPlaceholder") : L("apiToken"), text: $token).textFieldStyle(.roundedBorder).accessibilityIdentifier("accounts.\(provider.rawValue).token")
            HStack {
                Button { Task { await testAndSave() } } label: { if testing { ProgressView().controlSize(.small) } else { Text(L("testAndSave")) } }
                    .buttonStyle(.borderedProminent).disabled(token.isEmpty || (provider.needsEmail && email.isEmpty) || testing)
                    .accessibilityIdentifier("accounts.\(provider.rawValue).save")
                if saved { Button(L("testConnection")) { Task { await testSaved() } }.disabled(testing); Button(L("disconnect"), role: .destructive) { ProviderVault.remove(provider); saved = false; connectedAs = ""; status = ""; token = "" } }
            }
            if !status.isEmpty { Label(status, systemImage: failed ? "exclamationmark.triangle" : "checkmark.circle").font(.caption).foregroundStyle(failed ? .red : Brand.accent).textSelection(.enabled) }
        }
        .padding(16).background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(saved ? Brand.accent.opacity(0.4) : Color.secondary.opacity(0.15)))
        .onAppear { if let credentials = try? ProviderVault.load(provider) { saved = true; email = credentials.email } }
    }
    /// The token is stored only after the provider accepts it.
    private func testAndSave() async {
        testing = true; defer { testing = false }
        let credentials = ProviderCredentials(email: email.trimmingCharacters(in: .whitespaces), token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            connectedAs = try await client.verify(provider, credentials: credentials)
            try ProviderVault.save(credentials, for: provider)
            saved = true; token = ""; failed = false; status = String(format: L("connectedAs"), connectedAs)
        } catch { failed = true; status = error.localizedDescription }
    }
    private func testSaved() async {
        guard let credentials = try? ProviderVault.load(provider) else { return }
        testing = true; defer { testing = false }
        do { connectedAs = try await client.verify(provider, credentials: credentials); failed = false; status = String(format: L("connectedAs"), connectedAs) }
        catch { failed = true; status = error.localizedDescription }
    }
}
