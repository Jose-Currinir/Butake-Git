import SwiftUI

struct InstalledAgent: Identifiable { var name: String; var path: String; var id: String { path } }
struct AgentsView: View {
    let store: WorkspaceStore
    @State private var worktrees: [String] = []
    @State private var selection = ""
    @State private var agents: [InstalledAgent] = []
    @State private var selectedAgent: InstalledAgent?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top, spacing: 18) { Image(systemName: "sparkles").font(.system(size: 32)).foregroundStyle(Brand.accent).frame(width: 68, height: 68).background(Brand.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 16)); VStack(alignment: .leading, spacing: 9) { Text(L("agentTitle")).font(.system(size: 27, weight: .semibold)); Text(L("agentDetail")).font(.title3).foregroundStyle(.secondary) } }
                Text(L("agentScope")).font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("selectWorktree")).font(.headline)
                    Picker(L("worktrees"), selection: $selection) { ForEach(worktrees, id: \.self) { path in Text(URL(fileURLWithPath: path).lastPathComponent + " · " + path).tag(path) } }.labelsHidden()
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                if agents.isEmpty { ContentUnavailableView(L("agents"), systemImage: "sparkles", description: Text(L("noAgents"))) }
                ForEach(agents) { agent in HStack(spacing: 16) { Image(systemName: "terminal").font(.title2).foregroundStyle(Brand.accent); VStack(alignment: .leading, spacing: 5) { Text(agent.name).font(.headline); Text(agent.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }; Spacer(); Button(L("agentOpen")) { selectedAgent = agent }.disabled(selection.isEmpty || store.terminalActive || store.busy) }.padding(20).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12)) }
            }.padding(30).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }.task { await load() }
        .confirmationDialog(L("agentOpen"), isPresented: Binding(get: { selectedAgent != nil }, set: { if !$0 { selectedAgent = nil } }), titleVisibility: .visible) {
            Button(L("confirm")) { if let agent = selectedAgent { launch(agent) }; selectedAgent = nil }
        } message: { Text("\(selectedAgent?.name ?? "")\n\(selection)") }
    }
    private func load() async {
        guard let root = store.repository?.root else { return }
        do { let text = try await store.engine.query(root, ["worktree", "list", "--porcelain"]); worktrees = text.components(separatedBy: "\n").filter { $0.hasPrefix("worktree ") }.map { String($0.dropFirst(9)) }; selection = worktrees.first ?? root } catch { store.fail(error) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").components(separatedBy: ":") + ["/opt/homebrew/bin", home + "/.local/bin"]
        agents = [("Codex CLI", "codex"), ("Claude Code", "claude"), ("Gemini CLI", "gemini"), ("OpenCode", "opencode")].compactMap { name, executable in guard let directory = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0 + "/" + executable) }) else { return nil }; return InstalledAgent(name: name, path: directory + "/" + executable) }
    }
    private func launch(_ agent: InstalledAgent) { store.terminalLaunch = TerminalLaunch(root: selection, command: "status", arguments: "", plan: nil, agentExecutable: agent.path); store.terminalActive = true; store.route = .console; store.status = agent.name }
}
