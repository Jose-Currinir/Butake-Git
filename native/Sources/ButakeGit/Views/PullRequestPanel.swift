import SwiftUI
import AppKit

/// Everything a pull request needs to be merged, in one place: status, checks grouped by what
/// they require, reviews, conversation (with inline code context) and the changed files.
struct PullRequestDetail: View {
    let store: WorkspaceStore
    let pr: HostedPR
    let repo: HostedRepository
    let reload: () async -> Void
    /// QA/preview data; when set nothing is fetched from the provider.
    var fixture: PRFixture? = nil
    @State private var comments: [HostedComment] = []
    @State private var checks: [HostedCheck] = []
    @State private var reviews: [HostedReview] = []
    @State private var tab = PRTab.overview
    @State private var error = ""
    @State private var loading = false
    @State private var pendingAction: String?
    @State private var busy = false
    @State private var files: [CommitFileChange] = []
    @State private var filesNote = ""
    private let client = HostingClient()

    var body: some View {
        VStack(spacing: 0) {
            PRHeader(pr: pr, repo: repo, reviews: reviews, checks: checks, totals: totals, tab: $tab, busy: busy) { pendingAction = $0 }
            Divider()
            if !error.isEmpty { Label(error, systemImage: "exclamationmark.triangle.fill").font(.uiCaption).foregroundStyle(Brand.danger).textSelection(.enabled).padding(.horizontal, 20).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).background(Brand.danger.opacity(0.06)) }
            switch tab {
            case .overview: overview
            case .changes: PRChangesView(store: store, pr: pr, files: files, note: filesNote) { Task { await loadFiles() } }
            }
        }
        .task(id: pr.id) { await loadDetail() }
        .confirmationDialog(L(pendingAction == "merge" ? "mergePR" : "approve"), isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            Button(L(pendingAction == "merge" ? "mergePR" : "approve"), role: pendingAction == "merge" && failing > 0 ? .destructive : nil) { let action = pendingAction; pendingAction = nil; if let action { Task { await execute(action) } } }
        } message: {
            Text("#\(pr.id): \(pr.source) → \(pr.target)" + (pendingAction == "merge" && failing > 0 ? "\n\n" + String(format: L("prMergeWithFailures"), failing) : ""))
        }
    }

    private var failing: Int { checks.filter { $0.state == .failure }.count }
    private var totals: LineStats { LineStats(additions: files.compactMap(\.stats.additions).reduce(0, +), deletions: files.compactMap(\.stats.deletions).reduce(0, +)) }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ChecksCard(checks: checks, loading: loading, merged: pr.state == .merged)
                if !reviews.isEmpty { ReviewsCard(reviews: reviews) }
                PRCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) { AuthorAvatar(name: pr.author, size: 22); Text(pr.author).font(.ui(size: 12, weight: .semibold)); Text(L("prOpenedThis")).font(.uiCaption).foregroundStyle(.secondary) }
                        if pr.body.isEmpty { Text(L("prNoDescription")).font(.uiCallout).foregroundStyle(.tertiary) }
                        else { MarkdownText(pr.body) }
                    }.padding(14)
                }
                if !comments.isEmpty {
                    Text(L("prConversation")).font(.uiHeadline).padding(.top, 4)
                    ForEach(comments, id: \.listKey) { comment in
                        CommentCard(comment: comment, onReply: { quote in composer = quote }, onAgent: { copyForAgent(comment) })
                    }
                }
                CommentComposer(text: $composer, busy: busy) { Task { await sendComment() } }
            }
            .padding(20).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
    @State private var composer = ""

    private func loadDetail() async {
        error = ""; files = []; filesNote = ""
        if let fixture { comments = fixture.comments; checks = fixture.checks; reviews = fixture.reviews; files = fixture.files; return }
        loading = true; defer { loading = false }
        async let loadedComments = client.comments(repo, pr: pr.id)
        async let loadedReviews = client.reviews(repo, pr: pr.id)
        // Late answers of a pull request that is no longer shown are dropped.
        do { let value = try await loadedComments; guard !Task.isCancelled else { return }; comments = value } catch { guard !Task.isCancelled else { return }; self.error = error.localizedDescription }
        let loaded = (try? await loadedReviews) ?? []
        guard !Task.isCancelled else { return }
        reviews = loaded
        if let sha = pr.sourceSHA { let value = (try? await client.checks(repo, sha: sha)) ?? []; guard !Task.isCancelled else { return }; checks = value }
        await loadFiles()
    }
    /// Changed files come from local remote-tracking refs (no extra API calls, same for both providers).
    private func loadFiles() async {
        guard fixture == nil, let root = store.repository?.root else { return }
        let base = "origin/\(pr.target)", head = "origin/\(pr.source)"
        guard ![pr.target, pr.source].contains(where: { $0.hasPrefix("-") || $0.contains("..") }) else { return }
        do {
            async let status = store.engine.query(root, ["diff", "--name-status", "-z", "--no-renames", "\(base)...\(head)"])
            async let numstat = store.engine.query(root, ["diff", "--numstat", "--no-renames", "\(base)...\(head)"])
            let parsed = CommitFileChange.parse(status: try await status, numstat: try await numstat)
            guard !Task.isCancelled else { return }
            files = parsed; filesNote = ""
        } catch { guard !Task.isCancelled else { return }; files = []; filesNote = String(format: L("prFilesNeedFetch"), pr.source, pr.target) }
    }
    private func execute(_ action: String) async {
        busy = true; defer { busy = false }
        do { if action == "merge" { try await client.merge(repo, pr: pr.id) } else { try await client.approve(repo, pr: pr.id) }; store.notify(L(action == "merge" ? "prMergedDone" : "prApproved"), icon: "checkmark.circle.fill"); await reload() }
        catch { self.error = error.localizedDescription }
    }
    private func sendComment() async {
        busy = true; defer { busy = false }
        do { try await client.comment(repo, pr: pr.id, text: composer); composer = ""; await loadDetail() } catch { self.error = error.localizedDescription }
    }
    /// "Fix with AI": a ready-to-paste prompt with the PR, file/line and the reviewer's request.
    private func copyForAgent(_ comment: HostedComment) {
        var prompt = String(format: L("prAgentPrompt"), pr.id, pr.title, pr.source, comment.author)
        if let path = comment.path { prompt += "\n" + L("file") + ": \(path)" + (comment.line.map { ":\($0)" } ?? "") }
        prompt += "\n\n" + comment.body
        if let hunk = comment.hunk { prompt += "\n\n```diff\n\(hunk)\n```" }
        store.copyToPasteboard(prompt); store.notify(L("prAgentCopied"), icon: "sparkles")
    }
}

enum PRTab: Hashable { case overview, changes }

struct PRFixture { var comments: [HostedComment]; var checks: [HostedCheck]; var reviews: [HostedReview]; var files: [CommitFileChange] }

// MARK: - Header

private struct PRHeader: View {
    let pr: HostedPR; let repo: HostedRepository; let reviews: [HostedReview]; let checks: [HostedCheck]; let totals: LineStats
    @Binding var tab: PRTab
    let busy: Bool
    let onAction: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(pr.title).font(.ui(size: 17, weight: .semibold)).textSelection(.enabled).lineLimit(2)
                Text("#\(pr.id)").font(.ui(size: 17)).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                reviewBadge
                if let url = pr.url { Link(destination: url) { Image(systemName: "arrow.up.right.square") }.help(String(format: L("openIn"), repo.provider.title)).accessibilityLabel(String(format: L("openIn"), repo.provider.title)) }
            }
            HStack(spacing: 8) {
                PRStateChip(state: pr.state, draft: pr.draft)
                (Text(pr.author).fontWeight(.semibold) + Text(" " + L("prWantsToMerge") + " ")).font(.uiCaption).foregroundStyle(.secondary)
                BranchChip(name: pr.target)
                Text(L("prFrom")).font(.uiCaption).foregroundStyle(.secondary)
                BranchChip(name: pr.source)
                if let updated = pr.updated { Text("· " + RelativeDateCache.shared.text(for: updated)).font(.uiCaption).foregroundStyle(.tertiary) }
                Spacer()
                if pr.state == .open {
                    Button(L("approve")) { onAction("approve") }.disabled(busy).accessibilityIdentifier("pr.approve")
                    Button(L("mergePR")) { onAction("merge") }.buttonStyle(.borderedProminent).disabled(busy || pr.draft).accessibilityIdentifier("pr.merge")
                }
            }
            HStack(spacing: 4) {
                TabButton(title: L("prOverview"), selected: tab == .overview) { tab = .overview }.accessibilityIdentifier("pr.tab.overview")
                TabButton(title: L("prChanges"), selected: tab == .changes, trailing: totals.additions ?? 0 > 0 || totals.deletions ?? 0 > 0 ? AnyView(StatsBadge(stats: totals)) : nil) { tab = .changes }.accessibilityIdentifier("pr.tab.changes")
            }.padding(.top, 2)
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
    }
    @ViewBuilder private var reviewBadge: some View {
        let changes = reviews.contains { $0.verdict == .changesRequested }
        let approved = reviews.contains { $0.verdict == .approved }
        let (title, icon, color): (String, String, Color) = changes ? (L("prChangesRequested"), "exclamationmark.circle.fill", Brand.warning) : approved ? (L("prApprovedBadge"), "checkmark.circle.fill", Brand.accent) : (L("prReviewRequired"), "exclamationmark.circle", Brand.warning)
        if pr.state == .open {
            Label(title, systemImage: icon).font(.ui(size: 11, weight: .medium)).foregroundStyle(color)
                .padding(.horizontal, 9).padding(.vertical, 4).overlay(Capsule().strokeBorder(color.opacity(0.45)))
        }
    }
}

private struct TabButton: View {
    let title: String; let selected: Bool; var trailing: AnyView? = nil; let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { Text(title).font(.ui(size: 12, weight: selected ? .semibold : .regular)); trailing }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selected ? Color.primary.opacity(0.08) : hovering ? Color.primary.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct PRStateChip: View {
    let state: PRState; var draft = false
    var body: some View {
        let (title, icon, color) = style
        Label(title, systemImage: icon).font(.ui(size: 11, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 4).background(color.gradient, in: Capsule()).fixedSize()
    }
    private var style: (String, String, Color) {
        if draft { return (L("prDraft"), "pencil.circle", .secondary) }
        switch state {
        case .open: return (L("prStateOpen"), "arrow.triangle.pull", Brand.accent)
        case .merged: return (L("prStateMerged"), "arrow.triangle.merge", Brand.special)
        case .closed: return (L("prStateClosed"), "xmark.circle", Brand.danger)
        }
    }
}

private struct BranchChip: View {
    let name: String
    var body: some View {
        Text(name).font(.ui(size: 10.5, design: .monospaced)).foregroundStyle(Brand.info)
            .padding(.horizontal, 6).padding(.vertical, 2).background(Brand.info.opacity(0.1), in: RoundedRectangle(cornerRadius: 5)).lineLimit(1).truncationMode(.middle)
            .textSelection(.enabled)
    }
}

// MARK: - Cards

private struct PRCard<Content: View>: View {
    var accent: Color? = nil
    @ViewBuilder let content: Content
    var body: some View {
        content.frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
            .overlay(alignment: .leading) { if let accent { UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10).fill(accent).frame(width: 3) } }
    }
}

/// "All checks have passed" / "1 failing" with groups that say what each check needs from you.
private struct ChecksCard: View {
    let checks: [HostedCheck]; let loading: Bool; let merged: Bool
    @State private var showAll = true
    private var groups: [(key: String, icon: String, color: Color, items: [HostedCheck])] {
        [("prChecksFailing", "xmark.circle.fill", Brand.danger, checks.filter { $0.state == .failure }),
         ("prChecksRunning", "clock.fill", Brand.warning, checks.filter { $0.state == .pending }),
         ("prChecksPassed", "checkmark.circle.fill", Brand.accent, checks.filter { $0.state == .success }),
         ("prChecksSkipped", "minus.circle", Color.secondary, checks.filter { $0.state == .neutral })].filter { !$0.3.isEmpty }
    }
    private var summary: (title: String, detail: String, icon: String, color: Color) {
        let failing = checks.filter { $0.state == .failure }.count, running = checks.filter { $0.state == .pending }.count, passed = checks.filter { $0.state == .success }.count
        if loading && checks.isEmpty { return (L("prChecksLoading"), "", "hourglass", .secondary) }
        if checks.isEmpty { return (L("noChecks"), L("prNoChecksDetail"), "checkmark.seal", .secondary) }
        if failing > 0 { return (failing == 1 ? L("prChecksOneFailing") : String(format: L("prChecksSomeFailing"), failing), String(format: L("prChecksCount"), checks.count), "xmark.octagon.fill", Brand.danger) }
        if running > 0 { return (running == 1 ? L("prChecksOneRunning") : String(format: L("prChecksSomeRunning"), running), String(format: L("prChecksCount"), checks.count), "clock.fill", Brand.warning) }
        return (L("prChecksAllPassed"), String(format: L("prChecksPassedCount"), passed), "checkmark.circle.fill", Brand.accent)
    }
    var body: some View {
        let summary = summary
        PRCard(accent: summary.color == .secondary ? nil : summary.color) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: summary.icon).font(.ui(size: 22)).foregroundStyle(summary.color).symbolRenderingMode(.hierarchical)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.title).font(.ui(size: 13, weight: .semibold))
                        if !summary.detail.isEmpty { Text(summary.detail).font(.uiCaption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if !checks.isEmpty { Button(L(showAll ? "prHideChecks" : "prShowChecks")) { withAnimation(.snappy) { showAll.toggle() } }.buttonStyle(.link).font(.uiCaption).accessibilityIdentifier("pr.toggleChecks") }
                }.padding(14)
                if showAll {
                    ForEach(groups, id: \.key) { group in
                        Divider()
                        DisclosureGroup {
                            ForEach(group.items) { check in CheckRow(check: check) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: group.icon).foregroundStyle(group.color)
                                Text("\(L(group.key)) (\(group.items.count))").foregroundStyle(group.color == .secondary ? .secondary : .primary)
                            }.font(.ui(size: 11.5, weight: .medium))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .disclosureGroupStyle(ExpandedByDefault(initiallyExpanded: group.key != "prChecksSkipped"))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel(summary.title)
    }
}
private struct ExpandedByDefault: DisclosureGroupStyle {
    let initiallyExpanded: Bool
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration, initiallyExpanded: initiallyExpanded) }
    private struct Inner: View {
        let configuration: Configuration; let initiallyExpanded: Bool
        @State private var expanded: Bool?
        var body: some View {
            let open = expanded ?? initiallyExpanded
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(.snappy) { expanded = !open } } label: {
                    HStack(spacing: 6) { Image(systemName: "chevron.right").font(.ui(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(.secondary); configuration.label; Spacer() }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                if open { configuration.content.padding(.leading, 15) }
            }
        }
    }
}
private struct CheckRow: View {
    let check: HostedCheck
    var body: some View {
        HStack(spacing: 8) {
            CheckIcon(state: check.state).font(.ui(size: 12))
            Text(check.name).font(.ui(size: 12, weight: .medium)).lineLimit(1)
            Text(detail).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if let url = check.url { Link(L("prDetails"), destination: url).font(.uiCaption) }
        }.padding(.vertical, 2)
    }
    private var detail: String {
        let state = switch check.state { case .success: L("prCheckSuccess"); case .failure: L("prCheckFailure"); case .pending: L("prCheckRunning"); case .neutral: L("prCheckSkipped") }
        guard let duration = check.duration, duration > 0 else { return state }
        let formatter = DateComponentsFormatter(); formatter.unitsStyle = .abbreviated; formatter.allowedUnits = duration >= 60 ? [.minute, .second] : [.second]
        return "\(state) \(L("prIn")) \(formatter.string(from: duration) ?? "")"
    }
}
private struct ReviewsCard: View {
    let reviews: [HostedReview]
    var body: some View {
        PRCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("prReviewers")).font(.ui(size: 12, weight: .semibold))
                ForEach(reviews) { review in
                    HStack(spacing: 8) {
                        AuthorAvatar(name: review.author, size: 20)
                        Text(review.author).font(.ui(size: 12))
                        Spacer()
                        let (title, icon, color): (String, String, Color) = switch review.verdict { case .approved: (L("prApprovedBadge"), "checkmark.circle.fill", Brand.accent); case .changesRequested: (L("prChangesRequested"), "exclamationmark.circle.fill", Brand.warning); case .commented: (L("prCommented"), "text.bubble", .secondary) }
                        Label(title, systemImage: icon).font(.uiCaption).foregroundStyle(color)
                    }
                }
            }.padding(14)
        }
    }
}

// MARK: - Conversation

private struct CommentCard: View {
    let comment: HostedComment
    let onReply: (String) -> Void
    let onAgent: () -> Void
    var body: some View {
        PRCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    AuthorAvatar(name: comment.author, size: 22)
                    Text(comment.author).font(.ui(size: 12, weight: .semibold))
                    if comment.bot { Text("bot").font(.ui(size: 9, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 1).overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5))).foregroundStyle(.secondary) }
                    if let created = comment.created { Text("· " + RelativeDateCache.shared.text(for: created)).font(.uiCaption).foregroundStyle(.secondary) }
                    Spacer()
                    if let url = comment.url { Link(destination: url) { Image(systemName: "arrow.up.right.square") }.font(.uiCaption) }
                }.padding(.horizontal, 14).padding(.vertical, 10)
                if let path = comment.path {
                    Divider()
                    HStack(spacing: 6) { FileTypeIcon(path: path, size: 14); Text(path).font(.ui(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.head); if let line = comment.line { Text("L\(line)").font(.ui(size: 10, design: .monospaced)).foregroundStyle(.secondary) } }
                        .padding(.horizontal, 14).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.03))
                    if let hunk = comment.hunk { MiniDiff(text: PRSuggestion.tail(of: hunk, lines: 6)) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    MarkdownText(PRSuggestion.stripping(comment.body))
                    if let suggestion = PRSuggestion.extract(comment.body) {
                        Text(L("prSuggestedChange")).font(.uiCaption).foregroundStyle(.secondary)
                        MiniDiff(text: suggestion.diff(original: comment.hunk)).clipShape(RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08)))
                    }
                }.padding(14)
                Divider()
                HStack {
                    Button(L("prReply")) { onReply(comment.body.split(separator: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n\n") }.buttonStyle(.borderless)
                    Spacer()
                    Button { onAgent() } label: { Label(L("prFixWithAgent"), systemImage: "sparkles") }.help(L("prFixWithAgentHelp")).accessibilityIdentifier("pr.comment.agent.\(comment.id)")
                }.font(.uiCaption).controlSize(.small).padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
    }
}

/// GitHub ```suggestion blocks shown as the replacement for the commented lines.
enum PRSuggestion {
    struct Block { var lines: [String]
        func diff(original hunk: String?) -> String {
            let removed = hunk.map { PRSuggestion.tail(of: $0, lines: 1).split(separator: "\n").filter { $0.hasPrefix("+") || $0.hasPrefix(" ") }.map { "-" + $0.dropFirst() } } ?? []
            return (removed + lines.map { "+" + $0 }).joined(separator: "\n")
        }
    }
    static func extract(_ body: String) -> Block? {
        guard let start = body.range(of: "```suggestion") else { return nil }
        let rest = body[start.upperBound...].drop { $0 != "\n" }.dropFirst()
        guard let end = rest.range(of: "```") else { return nil }
        return Block(lines: rest[..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).map(String.init).dropLast(rest[..<end.lowerBound].hasSuffix("\n") ? 1 : 0).map { $0 })
    }
    static func stripping(_ body: String) -> String {
        guard let start = body.range(of: "```suggestion"), let end = body[start.upperBound...].range(of: "```") else { return body }
        return (String(body[..<start.lowerBound]) + String(body[end.upperBound...])).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Last lines of a review hunk: the code right above the comment.
    static func tail(of hunk: String, lines: Int) -> String {
        hunk.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("@@") }.suffix(lines).joined(separator: "\n")
    }
}

private struct MiniDiff: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                let color: Color = line.hasPrefix("+") ? Brand.accent : line.hasPrefix("-") ? Brand.danger : .clear
                Text(line.isEmpty ? " " : String(line)).font(.ui(size: 11, design: .monospaced))
                    .foregroundStyle(line.hasPrefix("+") || line.hasPrefix("-") ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 1.5)
                    .background(color.opacity(0.14))
            }
        }.padding(.vertical, 4).textSelection(.enabled)
    }
}

private struct CommentComposer: View {
    @Binding var text: String
    let busy: Bool
    let send: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        PRCard {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty { Text(L("prAddComment")).font(.ui(size: 12)).foregroundStyle(.tertiary).padding(.horizontal, 15).padding(.vertical, 12).allowsHitTesting(false) }
                    TextEditor(text: $text).font(.ui(size: 12)).scrollContentBackground(.hidden).focused($focused).padding(10).frame(minHeight: 80)
                        .accessibilityLabel(L("comment")).accessibilityIdentifier("pr.commentText")
                }
                Divider()
                HStack {
                    Text(L("prMarkdownHint")).font(.uiCaption2).foregroundStyle(.tertiary)
                    Spacer()
                    Button(L("sendComment"), action: send).buttonStyle(.borderedProminent).controlSize(.small).keyboardShortcut(.return, modifiers: .command)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy).accessibilityIdentifier("pr.sendComment")
                }.padding(10)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? Brand.accent.opacity(0.6) : .clear, lineWidth: 1.5))
    }
}

/// Inline Markdown (bold, code, links) keeping line breaks.
private struct MarkdownText: View {
    let source: String
    init(_ source: String) { self.source = source }
    var body: some View {
        let attributed = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        Text(attributed).font(.ui(size: 12.5)).lineSpacing(2).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Changes

private struct PRChangesView: View {
    let store: WorkspaceStore; let pr: HostedPR; let files: [CommitFileChange]; let note: String; let retry: () -> Void
    @State private var selected: String?
    @State private var diff = ""
    @State private var loadingDiff = false
    var body: some View {
        if files.isEmpty {
            EmptyState {
                Label(L(note.isEmpty ? "prNoFiles" : "prFilesUnavailable"), systemImage: "doc.text.magnifyingglass")
            } description: { Text(note.isEmpty ? L("prNoFilesDetail") : note) } actions: {
                if !note.isEmpty { Button(L("fetch")) { store.action("fetch"); Task { try? await Task.sleep(for: .seconds(2)); retry() } } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                List(files, selection: $selected) { file in
                    HStack(spacing: 8) {
                        FileTypeIcon(path: file.path, size: 15)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((file.path as NSString).lastPathComponent).font(.ui(size: 12, weight: .medium)).lineLimit(1)
                            let folder = (file.path as NSString).deletingLastPathComponent
                            if !folder.isEmpty { Text(folder).font(.ui(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                        }
                        Spacer(minLength: 4)
                        StatsBadge(stats: file.stats)
                    }.padding(.vertical, 2).tag(file.path).help(file.path)
                }
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 380)
                Group {
                    if selected == nil { EmptyState(L("diff"), systemImage: "doc.text", description: Text(L("chooseFile"))) }
                    else if loadingDiff { Spinner(size: 18).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else if diff.isEmpty { EmptyState(L("prNoFiles"), systemImage: "doc.text.magnifyingglass") }
                    else { DiffView(text: diff, path: selected) }
                }.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
            .task(id: selected) { await loadDiff() }
            .onAppear { if selected == nil { selected = files.first?.path } }
            // A reload can drop the selected file: fall back to the first one instead of waiting forever.
            .onChange(of: files) { _, files in if let path = selected, !files.contains(where: { $0.path == path }) { selected = files.first?.path } }
        }
    }
    private func loadDiff() async {
        guard let path = selected, let root = store.repository?.root else { return }
        diff = ""; loadingDiff = true
        let value = (try? await store.engine.query(root, ["diff", "--no-ext-diff", "--no-color", "origin/\(pr.target)...origin/\(pr.source)", "--", path])) ?? L("operationFailed")
        guard !Task.isCancelled else { return }
        diff = value; loadingDiff = false
    }
}

private extension HostedComment {
    /// General and inline comments come from different id spaces (GitHub), so the id alone can repeat in a list.
    var listKey: String { "\(path == nil ? "general" : "inline")-\(id)" }
}
