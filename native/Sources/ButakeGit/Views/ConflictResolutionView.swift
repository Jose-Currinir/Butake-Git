import SwiftUI
struct ConflictVersions: Codable { var base: String; var ours: String; var theirs: String; var working: String }
struct ConflictResolutionView: View {
    @Environment(\.dismiss) private var dismiss
    let store: WorkspaceStore; let file: ChangedFile
    @State private var versions: ConflictVersions?
    @State private var result = ""
    @State private var error = ""
    @State private var saving = false
    var rebasing: Bool { store.repository?.operation == "rebase" }
    var remaining: Int { store.changes.conflicts.count }
    /// Only the opening and closing markers count: a lone `=======` line is legitimate content (setext headings in
    /// Markdown or reStructuredText) and must not block saving. The engine applies the same rule.
    var unresolved: Bool { result.components(separatedBy: "\n").contains { $0.hasPrefix("<<<<<<< ") || $0.hasPrefix(">>>>>>> ") } }
    private var edited: Bool { versions.map { result != $0.working } ?? false }
    @State private var confirmingDiscard = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label(L("resolveConflictTitle"), systemImage: "arrow.triangle.merge").font(.uiTitle2.weight(.semibold)); Spacer(); if remaining > 1 { Text(String(format: L("conflictsPending"), remaining)).font(.uiCaption).foregroundStyle(Brand.warning) }; Text(file.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1) }
            Text(L("conflictHelp")).font(.uiCaption).foregroundStyle(.secondary)
            if let versions {
                HSplitView {
                    ConflictPane(title: L(rebasing ? "oursRebase" : "ours"), content: versions.ours, identifier: "conflict.useOurs") { result = versions.ours }
                    ConflictPane(title: L(rebasing ? "theirsRebase" : "theirs"), content: versions.theirs, identifier: "conflict.useTheirs") { result = versions.theirs }
                }.frame(height: 190)
                DisclosureGroup(L("conflictBase")) { ScrollView { Text(versions.base).font(.ui(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 100) }.font(.uiCaption)
                HStack { Text(L("result")).font(.uiHeadline); Spacer(); Button(L("useBoth")) { result = versions.ours.hasSuffix("\n") || versions.ours.isEmpty ? versions.ours + versions.theirs : versions.ours + "\n" + versions.theirs }.controlSize(.small).accessibilityIdentifier("conflict.useBoth"); if unresolved { Label(L("remainingMarkers"), systemImage: "exclamationmark.circle").font(.uiCaption).foregroundStyle(Brand.warning) } }
                // The code editor, not TextEditor: no smart quotes, dashes or autocorrection over source code.
                CodeEditorView(text: $result, path: file.path, editable: !saving).frame(minHeight: 180).border(.quaternary).accessibilityLabel(L("result")).accessibilityIdentifier("conflict.result")
            } else { Spinner(size: 18).frame(maxWidth: .infinity, minHeight: 200) }
            if !error.isEmpty { Text(error).foregroundStyle(Brand.danger).font(.uiCaption).textSelection(.enabled) }
            HStack { Spacer(); Button(L("cancel"), role: .cancel) { if edited { confirmingDiscard = true } else { dismiss() } }.accessibilityIdentifier("conflict.cancel").disabled(saving); Button(L("saveResolution")) { Task { await save() } }.accessibilityIdentifier("conflict.save").buttonStyle(.borderedProminent).disabled(versions == nil || unresolved || saving) }
        }.padding(24).frame(width: 920, height: 680).task { await load() }
        // A resolution being written is not thrown away by Esc or a click outside.
        .interactiveDismissDisabled(edited || saving)
        .confirmationDialog(L("discardEditorChanges"), isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button(L("closeWithoutSaving"), role: .destructive) { dismiss() }.accessibilityIdentifier("conflict.closeWithoutSaving")
            Button(L("cancel"), role: .cancel) {}.accessibilityIdentifier("conflict.keepEditing")
        }
    }
    private func load() async {
        guard let root = store.repository?.root else { return }
        do { let value: ConflictVersions = try await store.engine.call(["method": "conflict", "path": root, "file": file.path]); versions = value; result = value.working } catch { self.error = error.localizedDescription }
    }
    private func save() async {
        guard let root = store.repository?.root, let versions, !saving else { return }; saving = true; defer { saving = false }
        do {
            let _: String = try await store.engine.call(["method": "resolveConflict", "path": root, "file": file.path, "content": result, "expected": versions.working, "confirmed": true])
            store.selectedFile = nil; store.diff = ""; await store.refresh(); dismiss()
            store.notify(L("done_resolve"))
            // Chain to the next conflicted file so the user is walked through all of them.
            if let next = store.changes.conflicts.first(where: { $0.path != file.path }) { try? await Task.sleep(for: .milliseconds(450)); store.resolving = next }
        } catch { self.error = error.localizedDescription }
    }
}
private struct ConflictPane: View {
    let title: String; let content: String; let identifier: String; let use: () -> Void
    var body: some View { VStack(alignment: .leading, spacing: 8) { HStack { Text(title).font(.uiCaption.weight(.semibold)); Spacer(); Button(L("useThis"), action: use).controlSize(.small).accessibilityLabel("\(L("useThis")): \(title)").accessibilityIdentifier(identifier) }; ScrollView([.horizontal, .vertical]) { Text(content).font(.ui(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }.padding(12).frame(minWidth: 250).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8)) }
}
