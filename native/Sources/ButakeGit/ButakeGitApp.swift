import SwiftUI
import AppKit

@main struct ButakeGitApp: App {
    @MainActor static func apply(appearance: String) {
        NSApp.appearance = switch appearance {
        case "dark": NSAppearance(named: .darkAqua)
        case "light": NSAppearance(named: .aqua)
        default: nil
        }
    }
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var workspace = WorkspaceStore()
    /// The window's `.task` runs again each time it is reopened; app-level startup must happen once.
    @State private var launched = false
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("notchEnabled") private var notchEnabled = true
    var body: some Scene {
        Window("Butake Git", id: MainWindow.id) {
            WorkspaceView(store: workspace)
                .tint(Brand.accent)
                // Applied through AppKit: `preferredColorScheme(nil)` does not fully revert after an explicit
                // scheme, leaving views with dark text on light backgrounds when switching to "Sistema".
                .onChange(of: appearance, initial: true) { _, value in ButakeGitApp.apply(appearance: value) }
                .onChange(of: notchEnabled) { _, _ in NotchController.shared.update() }
                .frame(minWidth: 850, minHeight: 580)
                .modifier(MainWindowOpener())
                .task {
                    guard !launched else { return }
                    launched = true
                    await workspace.loadCapabilities()
                    NotchController.shared.start(store: workspace)
                    workspace.startAutoFetch()
                    let args = ProcessInfo.processInfo.arguments
                    if let index = args.firstIndex(of: "--repository"), args.indices.contains(index + 1) { await workspace.open(args[index + 1]) }
                    #if DEBUG || BUTAKE_QA
                    await workspace.runQAScript(ProcessInfo.processInfo.environment["BUTAKE_QA_ACTIONS"])
                    #endif
                }
        }
        .defaultSize(width: 1450, height: 920)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("newRepository") + "…") { workspace.creatingRepository = true }.keyboardShortcut("n")
                Button(L("openRepository"), action: workspace.chooseRepository).keyboardShortcut("o")
                Button(L("cloneRepository") + "…") { workspace.cloningRepository = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button(L("publishRepository") + "…") { workspace.publishingRepository = true }.disabled(workspace.repository?.canPublish != true)
            }
            CommandMenu("Git") {
                Button(L("refresh")) { Task { await workspace.refresh() } }.keyboardShortcut("r")
                Divider()
                Button(L("fetch")) { workspace.action("fetch") }.disabled(!workspace.canFetch)
                Button(L("pull")) { workspace.action("pull", confirm: true) }.disabled(!workspace.canPull)
                Button(L("push")) { workspace.action("push", confirm: true) }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(!workspace.canPush)
                Divider()
                Button(L("history")) { workspace.route = .history }.keyboardShortcut("1")
                Button(L("changes")) { workspace.route = .changes }.keyboardShortcut("2")
                Button(L("review")) { workspace.route = .review }.keyboardShortcut("3")
                Button(L("files")) { workspace.route = .files }.keyboardShortcut("5")
                Button(L("branches")) { workspace.route = .branches }.keyboardShortcut("4")
                Divider()
                Button(L("dictionary")) { workspace.route = .dictionary }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button(L("console")) { workspace.route = .console }.keyboardShortcut("j", modifiers: [.command])
            }
        }
        Settings { ConnectionSettingsView().frame(width: 640, height: 720).tint(Brand.accent) }
    }
}
