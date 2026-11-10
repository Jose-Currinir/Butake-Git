import SwiftUI
import AppKit
import SwiftTerm

struct GitConsoleView: View {
    @Bindable var store: WorkspaceStore
    @State private var terminal: LocalProcessTerminalView?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Label(L("console"), systemImage: "terminal").font(.title2.weight(.semibold)); Spacer(); if store.terminalActive { Button(L("stop"), role: .destructive) { terminal?.terminate() } } }
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) { Text(L("command")).font(.caption).foregroundStyle(.secondary); Picker(L("command"), selection: $store.consoleCommand) { ForEach(store.catalog.catalog.commands) { entry in Text(entry.name).tag(entry.name) } }.labelsHidden().frame(width: 180) }
                    VStack(alignment: .leading, spacing: 6) { Text(L("arguments")).font(.caption).foregroundStyle(.secondary); TextField("--short --branch", text: $store.consoleArguments).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).onSubmit { execute() } }
                    Button(L("execute"), action: execute).buttonStyle(.borderedProminent).padding(.top, 22).disabled(store.repository == nil)
                }.disabled(store.busy || store.terminalActive)
                Text(store.repository.map { abbreviatePath($0.root) } ?? L("noRepository")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(store.repository?.root ?? "")
                Text(L("argumentsHelp")).font(.caption2).foregroundStyle(.secondary)
            }.padding(20).background(.bar)
            Divider()
            if let launch = store.terminalLaunch {
                NativeTerminalView(launch: launch, onReady: { terminal = $0 }, onExit: store.terminalDidFinish).id(launch.id).padding(12).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
            } else {
                ContentUnavailableView(L("console"), systemImage: "terminal", description: Text(L("terminalHelp"))).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func execute() { Task { await store.prepare(store.consoleCommand, arguments: store.consoleArguments, interactive: true, plan: store.consolePlan) } }
}
struct NativeTerminalView: NSViewRepresentable {
    let launch: TerminalLaunch
    let onReady: (LocalProcessTerminalView) -> Void
    let onExit: (Int32?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = .textBackgroundColor; view.nativeForegroundColor = .textColor
        view.processDelegate = context.coordinator
        view.feed(text: "Butake Git · \(launch.root)\r\n$ \(launch.agentExecutable.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "git") \(launch.agentExecutable == nil ? launch.command + " " + launch.arguments : "")\r\n\r\n")
        var arguments = ["--terminal", launch.root, launch.command, launch.arguments]
        if let plan = launch.plan, let data = try? JSONEncoder().encode(plan), let text = String(data: data, encoding: .utf8) { arguments.append(text) }
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        DispatchQueue.main.async {
            onReady(view)
            view.startProcess(executable: launch.agentExecutable ?? GitEngine.executable.path, args: launch.agentExecutable == nil ? arguments : [], environment: environment, currentDirectory: launch.root)
            view.window?.makeFirstResponder(view)
        }
        return view
    }
    func updateNSView(_ view: LocalProcessTerminalView, context: Context) { view.nativeBackgroundColor = .textBackgroundColor; view.nativeForegroundColor = .textColor }
    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: Coordinator) { view.terminate() }
    @MainActor final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onExit: (Int32?) -> Void
        init(onExit: @escaping (Int32?) -> Void) { self.onExit = onExit }
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) { onExit(exitCode) }
        func processFailedToStart(source: TerminalView, error: LocalProcessError) { onExit(-1) }
    }
}
