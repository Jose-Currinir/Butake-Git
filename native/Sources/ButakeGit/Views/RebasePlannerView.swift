import SwiftUI

struct RebasePlannerView: View {
    @Environment(\.dismiss) private var dismiss
    let store: WorkspaceStore
    @State private var base = ""
    @State private var candidates: RebaseCandidates?
    @State private var steps: [RebaseStep] = []
    @State private var loading = false
    @State private var error = ""
    private let actions = ["pick", "reword", "edit", "squash", "fixup", "drop"]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L("interactiveRebase"), systemImage: "arrow.triangle.branch").font(.uiTitle2.weight(.semibold))
            Text(L("rebaseHelp")).font(.uiCaption).foregroundStyle(.secondary)
            HStack { TextField(L("rebaseBase"), text: $base).accessibilityIdentifier("rebase.rebaseBase").textFieldStyle(.roundedBorder); Button(L("loadPlan")) { Task { await load() } }.accessibilityIdentifier("rebase.loadPlan").disabled(base.isEmpty || loading) }
            if loading { Spinner(size: 14) }
            if !error.isEmpty { Text(error).font(.uiCaption).foregroundStyle(Brand.danger).textSelection(.enabled) }
            List {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(.uiCaption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 22)
                        Picker(L("command"), selection: Binding(get: { step.action }, set: { value in if let position = steps.firstIndex(where: { $0.id == step.id }) { steps[position].action = value } })) { ForEach(actions, id: \.self) { action in Text(L(action)).tag(action) } }.labelsHidden().frame(width: 190).accessibilityIdentifier("rebase.step.\(index + 1).action").accessibilityLabel("\(L("command")) \(index + 1): \(subject(step.hash))")
                        VStack(alignment: .leading, spacing: 4) { Text(subject(step.hash)).font(.ui(size: 12)).lineLimit(1); Text(step.hash.prefix(7)).font(.ui(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                        Spacer()
                        Button { move(step, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0).help(L("moveUp")).accessibilityLabel(L("moveUp")).accessibilityIdentifier("rebase.step.\(index + 1).moveUp")
                        Button { move(step, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(index == steps.count - 1).help(L("moveDown")).accessibilityLabel(L("moveDown")).accessibilityIdentifier("rebase.step.\(index + 1).moveDown")
                    }.padding(.vertical, 4).opacity(step.action == "drop" ? 0.55 : 1)
                }
            }.listStyle(.inset).themedScroll().frame(minHeight: 240).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            HStack { Spacer(); Button(L("cancel"), role: .cancel) { dismiss() }.accessibilityIdentifier("rebase.cancel"); Button(L("applyPlan")) { apply() }.accessibilityIdentifier("rebase.applyPlan").buttonStyle(.borderedProminent).disabled(steps.isEmpty || loading) }
        }.padding(24).frame(width: 780, height: 550)
        .onAppear { base = store.repository?.branches.first(where: { !$0.current })?.name ?? "" }
    }
    /// Looked up by id: a captured index can be stale after the plan is reloaded with fewer steps.
    private func move(_ step: RebaseStep, by offset: Int) {
        guard let position = steps.firstIndex(where: { $0.id == step.id }), steps.indices.contains(position + offset) else { return }
        steps.swapAt(position, position + offset)
    }
    private func subject(_ hash: String) -> String { candidates?.commits.first { $0.hash == hash }?.subject ?? hash }
    private func load() async {
        guard let root = store.repository?.root else { return }
        loading = true; error = ""; defer { loading = false }
        do { let result: RebaseCandidates = try await store.engine.call(["method": "rebaseCandidates", "path": root, "base": base]); candidates = result; steps = result.commits.map { RebaseStep(hash: $0.hash, action: "pick") } }
        catch { self.error = error.localizedDescription }
    }
    private func apply() {
        guard let candidates else { return }
        let plan = RebasePlan(head: candidates.head, base: candidates.base, steps: steps)
        dismiss()
        Task { await store.prepare("rebase", arguments: "--interactive --reapply-cherry-picks --keep-empty \(candidates.base)", interactive: true, plan: plan) }
    }
}
