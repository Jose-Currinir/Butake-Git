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
    var unresolved: Bool { result.components(separatedBy: "\n").contains { $0.hasPrefix("<<<<<<< ") || $0.hasPrefix("=======") || $0.hasPrefix(">>>>>>> ") } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label(L("resolveConflictTitle"), systemImage: "arrow.triangle.merge").font(.title2.weight(.semibold)); Spacer(); if remaining > 1 { Text(String(format: L("conflictsPending"), remaining)).font(.caption).foregroundStyle(.orange) }; Text(file.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1) }
            Text(L("conflictHelp")).font(.caption).foregroundStyle(.secondary)
            if let versions {
                HSplitView {
                    ConflictPane(title: L(rebasing ? "oursRebase" : "ours"), content: versions.ours) { withAnimation(.snappy) { result = versions.ours } }
                    ConflictPane(title: L(rebasing ? "theirsRebase" : "theirs"), content: versions.theirs) { withAnimation(.snappy) { result = versions.theirs } }
                }.frame(height: 190)
                DisclosureGroup(L("conflictBase")) { ScrollView { Text(versions.base).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 100) }.font(.caption)
                HStack { Text(L("result")).font(.headline); Spacer(); Button(L("useBoth")) { result = versions.ours.hasSuffix("\n") || versions.ours.isEmpty ? versions.ours + versions.theirs : versions.ours + "\n" + versions.theirs }.controlSize(.small).accessibilityIdentifier("conflict.useBoth"); if unresolved { Label(L("remainingMarkers"), systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) } }
                TextEditor(text: $result).font(.system(size: 12, design: .monospaced)).frame(minHeight: 180).border(.quaternary).accessibilityLabel(L("result"))
            } else { Spinner(size: 18).frame(maxWidth: .infinity, minHeight: 200) }
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            HStack { Spacer(); Button(L("cancel"), role: .cancel) { dismiss() }; Button(L("saveResolution")) { Task { await save() } }.accessibilityIdentifier("conflict.save").buttonStyle(.borderedProminent).disabled(versions == nil || unresolved || saving) }
        }.padding(24).frame(width: 920, height: 680).task { await load() }
    }
    private func load() async {
        guard let root = store.repository?.root else { return }
        do { let value: ConflictVersions = try await store.engine.call(["method": "conflict", "path": root, "file": file.path]); versions = value; result = value.working } catch { self.error = error.localizedDescription }
    }
    private func save() async {
        guard let root = store.repository?.root, let versions else { return }; saving = true; defer { saving = false }
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
    let title: String; let content: String; let use: () -> Void
    var body: some View { VStack(alignment: .leading, spacing: 8) { HStack { Text(title).font(.caption.weight(.semibold)); Spacer(); Button(L("useThis"), action: use).controlSize(.small).accessibilityLabel("\(L("useThis")): \(title)") }; ScrollView([.horizontal, .vertical]) { Text(content).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }.padding(12).frame(minWidth: 250).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8)) }
}
