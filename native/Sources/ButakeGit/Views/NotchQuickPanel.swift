import SwiftUI
import AppKit

/// What the floating panel under the notch is showing.
enum NotchQuickContent: Equatable {
    case commit
    case confirm(PendingOperationSnapshot)
    case newBranch
}
/// Equatable copy of the operation the panel confirms.
struct PendingOperationSnapshot: Equatable { var action: String; var title: String; var preview: String; var detail: String?; var destructive: Bool }

/// Key-capable, non-activating panel below the notch: type a commit message or confirm a push
/// without bringing the main window forward.
@MainActor final class NotchQuickPanel {
    static let shared = NotchQuickPanel()
    private var panel: QuickPanelWindow?
    private weak var store: WorkspaceStore?
    private var monitor: Any?

    func show(_ content: NotchQuickContent, store: WorkspaceStore) {
        self.store = store
        NotchController.shared.setExpanded(false)
        let size = NSSize(width: 460, height: content == .commit ? 400 : content == .newBranch ? 190 : 240)
        let view = NotchQuickView(store: store, content: content) { [weak self] in self?.close() }
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: view)
        let panel = self.panel ?? {
            let window = QuickPanelWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isFloatingPanel = true
            window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.backgroundColor = .clear; window.isOpaque = false; window.hasShadow = true
            window.hidesOnDeactivate = false; window.isMovableByWindowBackground = true
            return window
        }()
        panel.contentView = host
        let screen = NotchGeometry.current()?.screen ?? NSScreen.main
        let top = (NotchGeometry.current()?.notch.minY ?? (screen?.visibleFrame.maxY ?? 800)) - 10
        let midX = NotchGeometry.current()?.notch.midX ?? (screen?.frame.midX ?? 600)
        panel.setFrame(NSRect(x: midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.18; panel.animator().alphaValue = 1 }
        self.panel = panel
        // Clicking anywhere else closes it, like a popover.
        if monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in Task { @MainActor in NotchQuickPanel.shared.close() } }
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in context.duration = 0.14; panel.animator().alphaValue = 0 }, completionHandler: { Task { @MainActor in panel.orderOut(nil) } })
    }
    var isVisible: Bool { panel?.isVisible == true }
}

final class QuickPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { Task { @MainActor in NotchQuickPanel.shared.close() } }
}

struct NotchQuickView: View {
    let store: WorkspaceStore
    let content: NotchQuickContent
    let close: () -> Void
    var body: some View {
        Group {
            switch content {
            case .commit: QuickCommitView(store: store, close: close)
            case let .confirm(operation): QuickConfirmView(store: store, operation: operation, close: close)
            case .newBranch: QuickNewBranchView(store: store, close: close)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { QuickPanelBackground() }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .tint(Brand.green)
    }
}
private struct QuickPanelBackground: View {
    var body: some View {
        // Same near-black as the notch, so the panel reads as its continuation.
        Rectangle().fill(.ultraThinMaterial).overlay(Color(white: 0.06).opacity(0.94))
    }
}
private struct QuickHeader: View {
    let icon: String; let title: String; let subtitle: String; var tint: Color = Brand.green
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint).frame(width: 38, height: 38).background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
    }
}

/// Commit without opening the window: pick the type, write the message, include everything if nothing is staged.
private struct QuickCommitView: View {
    let store: WorkspaceStore; let close: () -> Void
    @State private var message = ""
    @State private var includeAll = true
    @State private var working = false
    @State private var error = ""
    @FocusState private var focused: Bool
    private var repo: RepositorySnapshot? { store.repository }
    private var staged: [ChangedFile] { store.changes.staged }
    private var unstaged: [ChangedFile] { store.changes.unstaged.filter { !$0.conflict } }
    private var files: [ChangedFile] { includeAll ? (repo?.files ?? []).filter { !$0.conflict } : staged }
    private var canCommit: Bool { !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !files.isEmpty && !working && store.canWrite }
    private var onPrimary: Bool { repo?.branch == repo?.primary }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            QuickHeader(icon: "checkmark.circle", title: L("quickCommitTitle"), subtitle: "\(repo?.name ?? "") · \(repo?.branch ?? "")")
            if !staged.isEmpty && !unstaged.isEmpty {
                Picker("", selection: $includeAll) {
                    Text(String(format: L("quickOnlyStaged"), staged.count)).tag(false)
                    Text(String(format: L("quickAllChanges"), (repo?.files ?? []).count)).tag(true)
                }.pickerStyle(.segmented).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(files.prefix(5)) { file in
                    HStack(spacing: 7) {
                        FileTypeIcon(path: file.path, size: 14)
                        Text(file.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        Text(file.directory).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                        Spacer()
                        ChangeKindBadge(kind: file.kind, compact: true)
                    }
                }
                if files.count > 5 { Text(String(format: L("quickMoreFiles"), files.count - 5)).font(.system(size: 10.5)).foregroundStyle(.secondary) }
                if files.isEmpty { Text(L("commitNothing")).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Menu {
                        ForEach(CommitType.all, id: \.prefix) { type in Button { applyType(type.prefix) } label: { Label("\(type.prefix) · \(L("ctype_" + type.prefix))", systemImage: type.icon) } }
                    } label: { Label(L("commitType"), systemImage: "tag").font(.system(size: 11)) }.menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                    Text("\(message.components(separatedBy: "\n").first?.count ?? 0)/72").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                }
                ZStack(alignment: .topLeading) {
                    if message.isEmpty { Text(L("messagePlaceholder")).font(.system(size: 12.5)).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 8).allowsHitTesting(false) }
                    TextEditor(text: $message).font(.system(size: 12.5)).scrollContentBackground(.hidden).focused($focused).padding(4)
                        .accessibilityIdentifier("quick.commitMessage")
                }
                .frame(height: 74).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? Brand.green.opacity(0.7) : .white.opacity(0.1)))
            }
            if onPrimary { Label(L("quickPrimaryWarning"), systemImage: "exclamationmark.triangle.fill").font(.system(size: 10.5)).foregroundStyle(.orange) }
            if !error.isEmpty { Label(error, systemImage: "xmark.octagon.fill").font(.system(size: 11)).foregroundStyle(.red).lineLimit(3) }
            Spacer(minLength: 0)
            HStack {
                Button(L("cancel")) { close() }.keyboardShortcut(.cancelAction)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                if repo?.hasRemote == true { Button(L("quickCommitPush")) { Task { await commit(push: true) } }.disabled(!canCommit).accessibilityIdentifier("quick.commitPush") }
                Button(L("commit")) { Task { await commit(push: false) } }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command).disabled(!canCommit).accessibilityIdentifier("quick.commit")
            }.controlSize(.large)
        }
        // With something already staged, commit only that by default; otherwise include everything.
        .onAppear { includeAll = staged.isEmpty; message = store.message; DispatchQueue.main.async { focused = true } }
    }
    private func applyType(_ prefix: String) {
        var lines = message.components(separatedBy: "\n"); var first = lines.first ?? ""
        if let current = CommitType.all.first(where: { first.hasPrefix($0.prefix + ":") || first.hasPrefix($0.prefix + "(") }) { first.removeFirst(current.prefix.count) } else { first = ": " + first }
        lines[0] = prefix + first; message = lines.joined(separator: "\n"); focused = true
    }
    private func commit(push: Bool) async {
        guard let root = repo?.root else { return }
        working = true; error = ""; defer { working = false }
        if includeAll && !unstaged.isEmpty { await store.stageNow(unstaged, staged: false) }
        store.message = message; store.errorMessage = nil
        await store.perform(PendingOperation(title: L("commit"), root: root, action: "commit", value: message, preview: "git commit"))
        if let failure = store.errorMessage, !failure.isEmpty { error = failure; store.errorMessage = nil; return }
        if push { await store.perform(PendingOperation(title: L("push"), root: root, action: "push", preview: "git push")) }
        if store.pullProblem != nil { bringMainWindow() }
        close()
    }
}

/// Confirms push/pull (and similar) from the notch with the same preview and warnings as the main window.
private struct QuickConfirmView: View {
    let store: WorkspaceStore; let operation: PendingOperationSnapshot; let close: () -> Void
    @State private var working = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            QuickHeader(icon: icon, title: operation.title, subtitle: "\(store.repository?.name ?? "") · \(store.repository?.branch ?? "")", tint: operation.destructive ? .orange : Brand.green)
            Text(operation.preview).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            if let detail = operation.detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(operation.destructive ? .orange : .secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
            HStack {
                Button(L("cancel")) { close() }.keyboardShortcut(.cancelAction)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(operation.title) { Task { await run() } }.buttonStyle(.borderedProminent).tint(operation.destructive ? .orange : Brand.green).keyboardShortcut(operation.action == "push" ? nil : .defaultAction).disabled(working).accessibilityIdentifier("quick.confirm")
            }.controlSize(.large)
        }
    }
    private var icon: String { operation.action == "push" ? "arrow.up.circle" : operation.action.hasPrefix("pull") ? "arrow.down.circle" : "questionmark.circle" }
    private func run() async {
        guard let root = store.repository?.root else { return }
        working = true; defer { working = false }
        store.errorMessage = nil
        await store.perform(PendingOperation(title: operation.title, root: root, action: operation.action, preview: operation.preview, destructive: operation.destructive, detail: operation.detail))
        // Pull problems (divergence, conflicts) need the assistant in the main window.
        if store.pullProblem != nil || (store.errorMessage.map { !$0.isEmpty } ?? false) { bringMainWindow() }
        close()
    }
}

private struct QuickNewBranchView: View {
    let store: WorkspaceStore; let close: () -> Void
    @State private var name = ""
    @FocusState private var focused: Bool
    private var valid: Bool { let n = name.trimmingCharacters(in: .whitespaces); return !n.isEmpty && !n.contains(" ") && !n.hasPrefix("-") && !n.contains("..") && !(store.repository?.branches.contains { $0.name == n } ?? false) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            QuickHeader(icon: "arrow.triangle.branch", title: L("newBranch"), subtitle: String(format: L("quickBranchFrom"), store.repository?.branch ?? "HEAD"))
            TextField("feature/nombre-del-cambio", text: $name).textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced)).focused($focused).onSubmit { create() }.accessibilityIdentifier("quick.branchName")
            Spacer(minLength: 0)
            HStack {
                Button(L("cancel")) { close() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("create")) { create() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!valid)
            }.controlSize(.large)
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
    private func create() { guard valid else { return }; store.action("create_branch", value: name.trimmingCharacters(in: .whitespaces)); close() }
}

@MainActor private func bringMainWindow() {
    MainWindow.show()
}
