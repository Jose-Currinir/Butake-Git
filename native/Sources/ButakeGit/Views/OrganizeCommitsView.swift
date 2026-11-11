import SwiftUI

/// Guided rewrite of unpublished commits: drag to reorder, combine, edit messages or remove.
/// No Git editor or terminal involved; a backup is stored so the change can be undone.
struct OrganizeCommitsView: View {
    @Environment(\.dismiss) private var dismiss
    let store: WorkspaceStore
    @State private var candidates: RewriteCandidates?
    @State private var items: [RewriteItem] = []
    @State private var original: [RewriteItem] = []
    @State private var selection: Set<UUID> = []
    @State private var editing: RewriteItem.ID?
    @State private var error = ""
    @State private var loading = true
    @State private var applying = false
    @State private var confirming = false

    private var changed: Bool { items.map { [$0.commits.map(\.hash).joined(), $0.message, "\($0.drop)"] } != original.map { [$0.commits.map(\.hash).joined(), $0.message, "\($0.drop)"] } }
    private var resultCount: Int { items.filter { !$0.drop }.count }
    private var combined: Int { items.filter { $0.commits.count > 1 && !$0.drop }.count }
    private var dropped: Int { items.filter(\.drop).reduce(0) { $0 + $1.commits.count } }
    private var reworded: Int { items.filter { $0.commits.count == 1 && !$0.drop && $0.changedMessage }.count }
    private var selectedItems: [RewriteItem] { items.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 1080, idealWidth: 1180, minHeight: 680, idealHeight: 760)
        .task { await load() }
        #if DEBUG || BUTAKE_QA
        .onReceive(NotificationCenter.default.publisher(for: .init("butake.qa.organize"))) { note in
            // QA-only: drive the organizer without a mouse ("combine:<hash7>,<hash7>", "apply").
            guard let command = note.object as? String else { return }
            if command.hasPrefix("combine:") {
                let wanted = Set(command.dropFirst(8).split(separator: ",").map(String.init))
                selection = Set(items.filter { $0.commits.contains { wanted.contains($0.shortHash) } }.map(\.id)); combineSelection()
            } else if command.hasPrefix("select:") {
                let wanted = Set(command.dropFirst(7).split(separator: ",").map(String.init))
                selection = Set(items.filter { $0.commits.contains { wanted.contains($0.shortHash) } }.map(\.id))
            } else if command == "apply" { Task { await apply() } }
        }
        #endif
        .alert(L("rewriteConfirmTitle"), isPresented: $confirming) {
            Button(L("cancel"), role: .cancel) {}
            Button(L("apply")) { Task { await apply() } }.keyboardShortcut(.defaultAction)
        } message: { Text(summaryText + "\n\n" + L("rewriteConfirmDetail")) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "wand.and.stars").font(.system(size: 20, weight: .semibold)).foregroundStyle(Brand.accent)
                .frame(width: 40, height: 40).background(Brand.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(L("organizeTitle")).font(.title3.weight(.semibold))
                Text(L("organizeHelp")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let candidates { Text(boundaryText(candidates)).font(.caption2).foregroundStyle(.tertiary).lineLimit(2) }
            }
            Spacer()
        }.padding(18)
    }

    @ViewBuilder private var content: some View {
        if loading { Spinner(size: 18).frame(maxWidth: .infinity, maxHeight: .infinity) }
        else if items.isEmpty {
            ContentUnavailableView(L("organizeEmpty"), systemImage: "checkmark.circle", description: Text(error.isEmpty ? L("organizeEmptyDetail") : error)).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                actionBar
                HStack(spacing: 0) {
                VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach($items) { $item in
                        OrganizeRow(item: $item, editing: editing == item.id, onEdit: { editing = editing == item.id ? nil : item.id })
                            .tag(item.id)
                            .accessibilityIdentifier("organize.item.\(item.commits.first?.shortHash ?? "")")
                    }
                    .onMove { from, to in withAnimation(.snappy) { items.move(fromOffsets: from, toOffset: to) } }
                }
                .listStyle(.inset)
                if !error.isEmpty { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).padding(10).textSelection(.enabled) }
                }
                .frame(minWidth: 420, idealWidth: 480, maxWidth: 560)
                Divider()
                // What each commit actually changes, so combining or removing is an informed decision.
                CommitPreview(store: store, hashes: previewHashes)
                    .frame(minWidth: 420, maxWidth: .infinity)
                }
            }
        }
    }
    /// Commits of the selected rows in original (oldest-first) order.
    private var previewHashes: [String] {
        let order = Dictionary(uniqueKeysWithValues: (candidates?.commits ?? []).enumerated().map { ($0.element.hash, $0.offset) })
        return selectedItems.flatMap(\.commits).map(\.hash).sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button { combineSelection() } label: { Label(L("combineSelected"), systemImage: "arrow.triangle.merge") }
                .disabled(selectedItems.count < 2).help(L("combineHelp")).accessibilityIdentifier("organize.combine")
            Button { splitSelection() } label: { Label(L("splitCommits"), systemImage: "arrow.triangle.branch") }
                .disabled(!selectedItems.contains { $0.commits.count > 1 }).accessibilityIdentifier("organize.split")
            Button { toggleDrop() } label: { Label(L("removeCommits"), systemImage: "trash") }
                .disabled(selectedItems.isEmpty).accessibilityIdentifier("organize.drop")
            Button { if let first = selectedItems.first { editing = first.id } } label: { Label(L("editMessage"), systemImage: "pencil") }
                .disabled(selectedItems.count != 1).accessibilityIdentifier("organize.edit")
            Spacer()
            Text(L("dragHint")).font(.caption2).foregroundStyle(.tertiary)
            Button(L("resetPlan")) { withAnimation(.snappy) { items = original; selection = []; editing = nil } }.disabled(!changed).accessibilityIdentifier("organize.reset")
        }
        .controlSize(.small).padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if !items.isEmpty {
                Label(summaryText, systemImage: changed ? "sparkles" : "equal.circle").font(.caption).foregroundStyle(changed ? Brand.accent : .secondary)
                    .contentTransition(.opacity).animation(.snappy, value: summaryText)
            }
            Spacer()
            Button(L("cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button { confirming = true } label: { if applying { Spinner(size: 14) } else { Text(L("apply")) } }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!changed || applying || resultCount == 0 || items.contains { !$0.drop && $0.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                .accessibilityIdentifier("organize.apply")
        }.padding(16)
    }

    private var summaryText: String {
        String(format: L("rewriteSummary"), items.reduce(0) { $0 + $1.commits.count }, resultCount) +
            [combined > 0 ? String(format: L("summaryCombined"), combined) : nil,
             dropped > 0 ? String(format: L("summaryDropped"), dropped) : nil,
             reworded > 0 ? String(format: L("summaryReworded"), reworded) : nil].compactMap { $0 }.map { " · " + $0 }.joined()
    }

    private func boundaryText(_ candidates: RewriteCandidates) -> String {
        switch candidates.boundary {
        case "upstream": L("boundaryUpstream")
        case "merge": L("boundaryMerge")
        case "root": L("boundaryRoot")
        default: L("boundaryLimit")
        }
    }

    private func load() async {
        guard let root = store.repository?.root else { return }
        loading = true; defer { loading = false }
        do {
            let value: RewriteCandidates = try await store.engine.call(["method": "rewriteCandidates", "path": root])
            candidates = value
            items = value.commits.reversed().map(RewriteItem.init(commit:))
            original = items
        } catch { self.error = error.localizedDescription }
    }

    /// Squashes the selected rows into one, placed where the newest of them was; commits keep their original order.
    private func combineSelection() {
        let chosen = items.enumerated().filter { selection.contains($0.element.id) }
        guard chosen.count >= 2, let position = chosen.first?.offset else { return }
        let order = Dictionary(uniqueKeysWithValues: (candidates?.commits ?? []).enumerated().map { ($0.element.hash, $0.offset) })
        let commits = chosen.flatMap(\.element.commits).sorted { (order[$0.hash] ?? 0) < (order[$1.hash] ?? 0) }
        let merged = RewriteItem(squashing: commits)
        withAnimation(.snappy) {
            items.removeAll { selection.contains($0.id) }
            items.insert(merged, at: min(position, items.count))
            editing = merged.id
        }
        // The list adjusts its own selection after rows are removed; select the new group afterwards.
        DispatchQueue.main.async { selection = [merged.id] }
    }

    private func splitSelection() {
        withAnimation(.snappy) {
            var result: [RewriteItem] = []
            for item in items {
                if selection.contains(item.id) && item.commits.count > 1 { result += item.commits.reversed().map(RewriteItem.init(commit:)) } else { result.append(item) }
            }
            items = result; selection = []; editing = nil
        }
    }

    private func toggleDrop() {
        let allDropped = selectedItems.allSatisfy(\.drop)
        withAnimation(.snappy) { for index in items.indices where selection.contains(items[index].id) { items[index].drop = !allDropped } }
    }

    private func apply() async {
        guard let candidates else { return }
        applying = true; defer { applying = false }
        if let failure = await store.applyRewrite(candidates: candidates, items: items) { error = failure; if store.repository?.operation == "rebase" { dismiss() } }
        else { dismiss() }
    }
}

private struct OrganizeRow: View {
    @Binding var item: RewriteItem
    let editing: Bool
    let onEdit: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help(L("dragHint"))
                if item.commits.count > 1 {
                    Text(String(format: L("combinedCount"), item.commits.count)).font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Brand.accent.opacity(0.14), in: Capsule())
                }
                Text(item.subject.isEmpty ? L("noMessage") : item.subject).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .strikethrough(item.drop).foregroundStyle(item.drop ? .secondary : .primary)
                if item.changedMessage && !item.drop && item.commits.count == 1 { Image(systemName: "pencil.circle.fill").foregroundStyle(Brand.accent).help(L("messageChanged")) }
                if item.drop { Text(L("willRemove")).font(.system(size: 9, weight: .bold)).foregroundStyle(.red).padding(.horizontal, 6).padding(.vertical, 2).background(.red.opacity(0.12), in: Capsule()) }
                Spacer()
                Text(item.commits.map(\.shortHash).joined(separator: " + ")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                Button(action: onEdit) { Image(systemName: editing ? "chevron.up" : "pencil") }.buttonStyle(.borderless).help(L("editMessage")).accessibilityLabel(L("editMessage"))
            }
            if editing {
                TextEditor(text: $item.message).font(.system(size: 12)).frame(height: 90).scrollContentBackground(.hidden)
                    .padding(6).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(L("message")).accessibilityIdentifier("organize.message")
                    .transition(.opacity.combined(with: .move(edge: .top)))
                if item.commits.count > 1 {
                    Text(item.commits.map { "\($0.shortHash) \($0.subject)" }.joined(separator: "\n")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4).opacity(item.drop ? 0.6 : 1)
        .animation(.snappy, value: editing)
    }
}

/// Read-only diff of one or more commits (`git show`), reused by the organizer and other pickers.
struct CommitPreview: View {
    let store: WorkspaceStore
    let hashes: [String]
    @State private var text = ""
    @State private var loading = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(Brand.accent)
                Text(hashes.isEmpty ? L("previewTitle") : String(format: L("previewCount"), hashes.count)).font(.system(size: 12, weight: .semibold))
                Spacer()
                if loading { Spinner(size: 14) }
                if !text.isEmpty { Button { store.copyToPasteboard(text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help(L("copyDiff")).accessibilityLabel(L("copyDiff")) }
            }.padding(.horizontal, 14).frame(height: 38).background(.bar)
            Divider()
            if hashes.isEmpty {
                ContentUnavailableView(L("previewTitle"), systemImage: "cursorarrow.click", description: Text(L("previewHint"))).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiffView(text: text.isEmpty ? " " : text).accessibilityIdentifier("organize.preview")
            }
        }
        .task(id: hashes) {
            guard !hashes.isEmpty, let root = store.repository?.root else { text = ""; return }
            loading = true; defer { loading = false }
            try? await Task.sleep(for: .milliseconds(80)) // coalesce fast selection changes
            guard !Task.isCancelled else { return }
            let args = ["show", "--no-ext-diff", "--no-textconv", "--no-color", "--stat", "--patch", "--format=%x01%h %s%n%an · %ad%n%n%b"] + hashes.prefix(20)
            text = (try? await store.engine.query(root, Array(args))) ?? ""
        }
    }
}
