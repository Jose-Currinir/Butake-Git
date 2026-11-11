import SwiftUI
import AppKit

struct ToolEntry: Identifiable, Hashable {
    var id: String; var title: String; var detail: String; var extra: String = ""
    var date: Date? = nil
    var icon: String? = nil
    var tint: ToolTint = .accent
    var chip: String? = nil
    var isCurrent = false
}
enum ToolTint: Hashable { case accent, blue, orange, purple, red, secondary
    var color: Color { switch self { case .accent: Brand.accent; case .blue: Brand.info; case .orange: Brand.warning; case .purple: Brand.special; case .red: Brand.danger; case .secondary: .secondary } }
}
struct ToolForm: Identifiable { var id = UUID(); var kind: String; var title: String; var command: String }
struct RepositoryToolsView: View {
    @Bindable var store: WorkspaceStore
    @State private var entries: [ToolEntry] = []
    @State private var selected: String?
    @State private var loading = false
    @State private var form: ToolForm?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(store.route.title, systemImage: store.route.icon).font(.uiHeadline)
                Spacer()
                if loading { Spinner(size: 14) }
                toolActions
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityIdentifier("tools.refresh").accessibilityLabel(L("refresh")).help(L("refresh"))
            }.padding(16).background(Brand.bar)
            Divider()
            if entries.isEmpty && !loading { emptyState.frame(maxHeight: .infinity) }
            else {
                List(entries, selection: $selected) { entry in
                    ToolEntryRow(entry: entry, fallbackIcon: store.route.icon) { entryActions(entry) }.tag(entry.id)
                        .accessibilityIdentifier("\(store.route.rawValue).\(entry.id)")
                        .modifier(StashRowActions(enabled: store.route == .stash, apply: { Task { await store.prepare("stash", arguments: "apply \(shellQuote(entry.id))") } }, pop: { Task { await store.prepare("stash", arguments: "pop \(shellQuote(entry.id))") } }, drop: { Task { await store.prepare("stash", arguments: "drop \(shellQuote(entry.id))") } }))
                }.listStyle(.inset).themedScroll()
            }
        }.task(id: "\(store.route.rawValue)-\(store.repository?.root ?? "")-\(store.repository?.commits.first?.hash ?? "")-\(store.status)") { await reload() }
        .sheet(item: $form) { form in ToolFormSheet(store: store, form: form).themedSheet() }
    }
    @ViewBuilder private var emptyState: some View {
        let key = "empty_\(store.route.rawValue)"
        EmptyState {
            Label(L(key + "_title"), systemImage: store.route.icon)
        } description: { Text(L(key + "_detail")) } actions: {
            switch store.route {
            case .stash: Button(L("stashSave")) { store.action("stash") }.accessibilityIdentifier("tools.stashSave").disabled(!store.canWrite || store.files.isEmpty != false)
            case .tags: Button(L("newTag")) { form = ToolForm(kind: "tag", title: L("newTag"), command: "tag") }.accessibilityIdentifier("tools.newTag").disabled(!store.canWrite)
            case .remotes:
                Button(L("publishRepository") + "…") { store.publishingRepository = true }.buttonStyle(.borderedProminent).accessibilityIdentifier("remotes.publish")
                Button(L("newRemote")) { form = ToolForm(kind: "remote", title: L("newRemote"), command: "remote") }.accessibilityIdentifier("tools.newRemote").disabled(!store.canWrite)
            default: EmptyView()
            }
        }
    }
    @ViewBuilder private var toolActions: some View {
        switch store.route {
        case .worktrees: Button(L("newWorktree")) { form = ToolForm(kind: "worktree", title: L("newWorktree"), command: "worktree") }.accessibilityIdentifier("tools.newWorktree").disabled(!store.canWrite)
        case .tags: Button(L("newTag")) { form = ToolForm(kind: "tag", title: L("newTag"), command: "tag") }.accessibilityIdentifier("tools.newTag").disabled(!store.canWrite)
        case .remotes: Button(L("newRemote")) { form = ToolForm(kind: "remote", title: L("newRemote"), command: "remote") }.accessibilityIdentifier("tools.newRemote").disabled(!store.canWrite)
        case .stash: Button(L("stashSave")) { store.action("stash") }.accessibilityIdentifier("tools.stashSave").disabled(!store.canWrite || store.files.isEmpty)
        default: EmptyView()
        }
    }
    @ViewBuilder private func entryActions(_ entry: ToolEntry) -> some View {
        switch store.route {
        case .worktrees:
            Button(L("open")) { store.reopenRecent(entry.id) }.accessibilityIdentifier("tools.open").controlSize(.small)
            Menu { Button(L("openFinder")) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: entry.id) }.accessibilityIdentifier("tools.openFinder"); Button(L("delete"), role: .destructive) { Task { await store.prepare("worktree", arguments: "remove \(shellQuote(entry.id))") } }.accessibilityIdentifier("tools.delete").disabled(entry.id == store.repository?.root) } label: { Image(systemName: "ellipsis") }.accessibilityIdentifier("tools.more").accessibilityLabel(L("more")).menuStyle(.borderlessButton).fixedSize()
        case .stash:
            Menu {
                Button(L("stashApply")) { Task { await store.prepare("stash", arguments: "apply \(shellQuote(entry.id))") } }.accessibilityIdentifier("tools.stashApply")
                Button(L("stashPop")) { Task { await store.prepare("stash", arguments: "pop \(shellQuote(entry.id))") } }.accessibilityIdentifier("tools.stashPop")
                Button(L("stashDrop"), role: .destructive) { Task { await store.prepare("stash", arguments: "drop \(shellQuote(entry.id))") } }.accessibilityIdentifier("tools.stashDrop")
                Button(L("diff")) { store.showDiff(entry.id, subtitle: L("stash"), args: ["diff", "--no-ext-diff", "--no-color", "\(entry.id)^1", entry.id]) }.accessibilityIdentifier("tools.diff")
            } label: { Image(systemName: "ellipsis.circle") }.accessibilityIdentifier("tools.stashMenu").accessibilityLabel(L("more")).menuStyle(.borderlessButton).fixedSize()
        case .tags:
            Button(L("viewChanges")) { store.showCommit(entry.id, title: entry.id) }.accessibilityIdentifier("tools.viewChanges").controlSize(.small)
        case .remotes:
            Button(L("fetch")) { Task { await store.prepare("fetch", arguments: shellQuote(entry.id)) } }.accessibilityIdentifier("tools.fetch").controlSize(.small)
        case .reflog:
            Button(L("viewChanges")) { store.showCommit(entry.extra, title: entry.title) }.accessibilityIdentifier("tools.viewChanges").controlSize(.small)
        default: EmptyView()
        }
    }
    private func reload() async {
        guard let root = store.repository?.root else { return }
        loading = true; defer { loading = false }
        // Read into a local value: an answer that arrives after the section or repository changed is dropped.
        let route = store.route; var loaded: [ToolEntry] = []
        do {
            switch route {
            case .worktrees:
                let text = try await store.engine.query(root, ["worktree", "list", "--porcelain"])
                loaded = text.components(separatedBy: "\n\n").compactMap { block in
                    let lines = block.components(separatedBy: "\n")
                    guard let path = lines.first(where: { $0.hasPrefix("worktree ") })?.dropFirst(9), !path.isEmpty else { return nil }
                    let branch = lines.first(where: { $0.hasPrefix("branch ") })?.replacingOccurrences(of: "branch refs/heads/", with: "") ?? L("detachedHead")
                    let head = lines.first(where: { $0.hasPrefix("HEAD ") }).map { String($0.dropFirst(5).prefix(7)) } ?? ""
                    let current = String(path) == root
                    return ToolEntry(id: String(path), title: branch, detail: abbreviatePath(String(path)), extra: head, icon: current ? "checkmark.circle.fill" : "folder", tint: current ? .accent : .secondary, chip: current ? L("current") : nil, isCurrent: current)
                }
            case .tags:
                let text = try await store.engine.query(root, ["tag", "--list", "--sort=-creatordate", "--format=%(refname:short)%09%(objectname:short)%09%(creatordate:unix)%09%(contents:subject)"])
                loaded = text.split(separator: "\n").map { line in
                    let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                    let name = parts[0]; let subject = parts.count > 3 ? parts[3] : ""
                    return ToolEntry(id: name, title: subject.isEmpty ? name : subject, detail: name, extra: parts.count > 1 ? parts[1] : "", date: parts.count > 2 ? epoch(parts[2]) : nil, icon: "tag.fill", tint: .orange, chip: name)
                }
            case .stash:
                let text = try await store.engine.query(root, ["stash", "list", "--format=%gd%x09%h%x09%ct%x09%gs"])
                loaded = text.split(separator: "\n").map { line in
                    let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                    let (branch, message) = humanizeStash(parts.count > 3 ? parts[3] : "")
                    return ToolEntry(id: parts[0], title: message, detail: parts[0], extra: parts.count > 1 ? parts[1] : "", date: parts.count > 2 ? epoch(parts[2]) : nil, icon: "archivebox.fill", tint: .blue, chip: branch)
                }
            case .remotes:
                let text = try await store.engine.query(root, ["remote", "-v"])
                var seen: Set<String> = []
                loaded = text.split(separator: "\n").compactMap { line in
                    let parts = line.split(separator: "\t", maxSplits: 1); guard parts.count == 2, seen.insert(String(parts[0])).inserted else { return nil }
                    let address = redactURL(String(parts[1]).replacingOccurrences(of: " (fetch)", with: "").replacingOccurrences(of: " (push)", with: ""))
                    return ToolEntry(id: String(parts[0]), title: String(parts[0]), detail: abbreviatePath(address), icon: remoteIcon(address), tint: .blue, chip: remoteHost(address))
                }
            case .reflog:
                let text = try await store.engine.query(root, ["reflog", "--date=unix", "--format=%h%x09%h%x09%gd%x09%gs", "-150"])
                // Several reflog steps can share a second, so ids are positional (HEAD@{n}), never date-based.
                loaded = text.split(separator: "\n").enumerated().map { index, line in
                    let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                    let step = ReflogStep(parts.count > 3 ? parts[3] : "")
                    let stamp = parts.count > 2 ? parts[2].split(separator: "{").last.map { String($0.dropLast()) } : nil
                    return ToolEntry(id: "HEAD@{\(index)}", title: step.title, detail: step.detail, extra: parts.count > 1 ? parts[1] : "", date: stamp.flatMap(epoch), icon: step.icon, tint: step.tint, chip: step.label)
                }
            default: break
            }
            guard !Task.isCancelled, store.route == route, store.repository?.root == root else { return }
            entries = loaded
        } catch { if !Task.isCancelled { store.fail(error) } }
    }
}
/// The stash menu's actions, also reachable as accessibility actions of the row (no pointer needed).
private struct StashRowActions: ViewModifier {
    let enabled: Bool; let apply: () -> Void; let pop: () -> Void; let drop: () -> Void
    func body(content: Content) -> some View {
        if enabled { content.accessibilityAction(named: L("stashApply"), apply).accessibilityAction(named: L("stashPop"), pop).accessibilityAction(named: L("stashDrop"), drop) }
        else { content }
    }
}
private struct ToolFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: WorkspaceStore; let form: ToolForm
    @State private var name = ""
    @State private var value = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(form.title).font(.uiTitle2.weight(.semibold))
            TextField(L("name"), text: $name).accessibilityIdentifier("tools.name").textFieldStyle(.roundedBorder)
            if form.kind == "remote" { TextField(L("remoteURL"), text: $value).accessibilityIdentifier("tools.remoteURL").textFieldStyle(.roundedBorder) }
            if form.kind == "worktree" { HStack { TextField(L("path"), text: $value).accessibilityIdentifier("tools.path").textFieldStyle(.roundedBorder); Button(L("target")) { let panel = NSSavePanel(); panel.canCreateDirectories = true; panel.nameFieldStringValue = name; if panel.runModal() == .OK { value = panel.url?.path ?? "" } }.accessibilityIdentifier("tools.target") }; Text(L("worktreeHelp")).font(.uiCaption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button(L("cancel"), role: .cancel) { dismiss() }.accessibilityIdentifier("tools.cancel"); Button(L("create")) { create() }.accessibilityIdentifier("tools.create").buttonStyle(.borderedProminent).disabled(name.isEmpty || ((form.kind == "remote" || form.kind == "worktree") && value.isEmpty)) }
        }.padding(26).frame(width: 480)
    }
    private func create() {
        let arguments: String
        switch form.kind {
        case "branch": arguments = "-c \(shellQuote(name))"
        case "worktree": arguments = "add -b \(shellQuote(name)) \(shellQuote(value))"
        case "remote": arguments = "add \(shellQuote(name)) \(shellQuote(value))"
        default: arguments = shellQuote(name)
        }
        dismiss(); Task { await store.prepare(form.command, arguments: arguments) }
    }
}
func redactURL(_ text: String) -> String {
    guard let scheme = text.range(of: "://"), let at = text[scheme.upperBound...].firstIndex(of: "@") else { return text }
    return String(text[..<scheme.upperBound]) + "•••@" + String(text[text.index(after: at)...])
}

private func epoch(_ text: String) -> Date? { Double(text.trimmingCharacters(in: .whitespaces)).map { Date(timeIntervalSince1970: $0) } }
/// "/Users/me/Projects/app" → "~/Projects/app".
func abbreviatePath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}
private func remoteHost(_ address: String) -> String? {
    if address.contains("github.com") { return "GitHub" }
    if address.contains("bitbucket.org") { return "Bitbucket" }
    if address.contains("gitlab") { return "GitLab" }
    return address.hasPrefix("/") || address.hasPrefix("file:") ? L("localRemote") : nil
}
private func remoteIcon(_ address: String) -> String { address.hasPrefix("/") || address.hasPrefix("file:") ? "externaldrive" : "network" }
/// "WIP on develop: 1a2b3c msg" / "On develop: msg" → (branch, friendly message).
func humanizeStash(_ subject: String) -> (String?, String) {
    for prefix in ["WIP on ", "On "] where subject.hasPrefix(prefix) {
        let rest = subject.dropFirst(prefix.count)
        guard let colon = rest.firstIndex(of: ":") else { break }
        let branch = String(rest[..<colon]); var message = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if prefix == "WIP on " { message = L("stashAuto") + " · " + (message.split(separator: " ", maxSplits: 1).last.map(String.init) ?? message) }
        return (branch, message)
    }
    return (nil, subject)
}
/// Reflog subjects ("checkout: moving from a to b", "commit (amend): msg"…) as friendly Spanish steps.
struct ReflogStep {
    var label: String; var title: String; var detail: String = ""; var icon: String; var tint: ToolTint
    init(_ subject: String) {
        let colon = subject.firstIndex(of: ":")
        let action = colon.map { String(subject[..<$0]) } ?? subject
        let rest = colon.map { subject[subject.index(after: $0)...].trimmingCharacters(in: .whitespaces) } ?? ""
        title = rest.isEmpty ? subject : rest; icon = "clock.arrow.circlepath"; tint = .secondary; label = action
        switch true {
        case action == "commit": label = L("reflog_commit"); icon = "checkmark.circle.fill"; tint = .accent
        case action == "commit (amend)": label = L("reflog_amend"); icon = "pencil.circle.fill"; tint = .blue
        case action == "commit (initial)": label = L("reflog_initial"); icon = "sparkle"; tint = .accent
        case action == "commit (merge)", action.hasPrefix("merge"): label = L("reflog_merge"); icon = "arrow.triangle.merge"; tint = .purple
            if action.hasPrefix("merge ") { detail = String(action.dropFirst(6)) }
        case action == "checkout":
            label = L("reflog_checkout"); icon = "arrow.left.arrow.right.circle.fill"; tint = .blue
            if rest.hasPrefix("moving from "), let to = rest.range(of: " to ") {
                let from = rest[rest.index(rest.startIndex, offsetBy: 12)..<to.lowerBound]
                title = "\(from) → \(rest[to.upperBound...])"
            }
        case action.hasPrefix("pull"): label = L("reflog_pull"); icon = "arrow.down.circle.fill"; tint = .blue
        case action.hasPrefix("reset"): label = L("reflog_reset"); icon = "arrow.uturn.backward.circle.fill"; tint = .orange
            if rest.hasPrefix("moving to ") { title = String(rest.dropFirst(10)) }
        case action.hasPrefix("rebase"): label = L("reflog_rebase"); icon = "arrow.triangle.pull"; tint = .purple
        case action.hasPrefix("cherry-pick"): label = L("reflog_cherry"); icon = "doc.on.doc.fill"; tint = .accent
        case action.hasPrefix("revert"): label = L("reflog_revert"); icon = "arrow.uturn.backward"; tint = .orange
        case action == "branch": label = L("reflog_branch"); icon = "arrow.triangle.branch"; tint = .accent
        default: break
        }
    }
}
private struct ToolEntryRow<Actions: View>: View {
    let entry: ToolEntry; let fallbackIcon: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: entry.icon ?? fallbackIcon).font(.ui(size: 15)).foregroundStyle(entry.tint.color).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let chip = entry.chip {
                        Text(chip).font(.ui(size: 9.5, weight: .semibold)).foregroundStyle(entry.tint.color)
                            .padding(.horizontal, 6).padding(.vertical, 1.5).background(entry.tint.color.opacity(0.12), in: Capsule()).fixedSize()
                    }
                    Text(entry.title).font(.ui(size: 12.5, weight: entry.isCurrent ? .semibold : .medium)).lineLimit(1).truncationMode(.tail)
                }
                HStack(spacing: 6) {
                    if !entry.detail.isEmpty && entry.detail != entry.chip { Text(entry.detail).lineLimit(1).truncationMode(.middle) }
                    if !entry.extra.isEmpty { Text(entry.extra).font(.ui(size: 10, design: .monospaced)).foregroundStyle(.tertiary) }
                }.font(.ui(size: 10.5)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 12)
            if let date = entry.date { Text(RelativeDateCache.shared.text(for: date)).font(.ui(size: 10.5)).foregroundStyle(.tertiary).help(date.formatted(date: .abbreviated, time: .shortened)) }
            actions()
        }
        .padding(.vertical, 6).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
