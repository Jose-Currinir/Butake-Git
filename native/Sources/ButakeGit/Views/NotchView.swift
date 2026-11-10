import SwiftUI
import AppKit

/// Geometry of the camera housing on the built-in display, from the areas macOS reports beside it.
struct NotchGeometry {
    var screen: NSScreen
    var notch: NSRect
    static func current() -> NotchGeometry? {
        for screen in NSScreen.screens where screen.safeAreaInsets.top > 0 {
            guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { continue }
            let height = screen.safeAreaInsets.top
            let rect = NSRect(x: screen.frame.minX + left.maxX, y: screen.frame.maxY - height, width: right.minX - left.maxX, height: height)
            if rect.width > 40 { return NotchGeometry(screen: screen, notch: rect) }
        }
        return nil
    }
}

/// Floating, non-activating panel that grows out of the notch.
@MainActor final class NotchController {
    static let shared = NotchController()
    private var panel: NSPanel?
    private var host: NSHostingView<AnyView>?
    private weak var store: WorkspaceStore?
    let model = NotchModel()
    var lastEnabled: Bool?
    /// Hides the notch from the notch itself; Settings › General turns it back on.
    func disable(store: WorkspaceStore) {
        UserDefaults.standard.set(false, forKey: "notchEnabled")
        update()
        store.notify(L("notchHidden"), icon: "rectangle.slash")
    }
    private var observers: [NSObjectProtocol] = []

    func start(store: WorkspaceStore) {
        self.store = store
        if observers.isEmpty {
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in NotchController.shared.reposition(animated: false) }
            })
            // The setting can change from Settings even with no main window open.
            observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    let enabled = UserDefaults.standard.object(forKey: "notchEnabled") as? Bool ?? true
                    if enabled != NotchController.shared.lastEnabled { NotchController.shared.update() }
                }
            })
        }
        update()
    }

    /// Shows or hides the panel according to the setting and whether this Mac has a notch.
    func update() {
        let enabled = UserDefaults.standard.object(forKey: "notchEnabled") as? Bool ?? true
        lastEnabled = enabled
        guard enabled, let store, NotchGeometry.current() != nil else {
            if !enabled { NotchQuickPanel.shared.close(); model.expanded = false; model.panelExpanded = false }
            panel?.orderOut(nil); return
        }
        if panel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
            panel.hidesOnDeactivate = false; panel.isMovable = false
            panel.acceptsMouseMovedEvents = true
            let host = NSHostingView(rootView: AnyView(NotchView(store: store, model: model) { expanded in NotchController.shared.setExpanded(expanded) }))
            host.sizingOptions = []
            panel.contentView = host
            self.panel = panel; self.host = host
        }
        reposition(animated: false)
        panel?.orderFrontRegardless()
    }

    func setExpanded(_ expanded: Bool) {
        guard model.expanded != expanded else { return }
        collapseTask?.cancel()
        if expanded {
            // Grow the window first (transparent), then let the shape spring out of the notch.
            model.panelExpanded = true; reposition()
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { model.expanded = true }
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { model.expanded = false }
            collapseTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(380))
                guard !Task.isCancelled, !self.model.expanded else { return }
                self.model.panelExpanded = false; self.reposition()
            }
        }
    }
    private var collapseTask: Task<Void, Never>?

    /// The window covers only what can be drawn: the notch (plus wings when there is news) or the full card.
    func reposition(animated: Bool = false) {
        guard let panel, let geometry = NotchGeometry.current() else { return }
        let notch = geometry.notch
        model.notchWidth = notch.width; model.notchHeight = notch.height
        let size: NSSize = model.panelExpanded
            ? NSSize(width: NotchModel.cardWidth + 40, height: notch.height + NotchModel.cardHeight + 40)
            : NSSize(width: model.collapsedWidth, height: notch.height)
        let frame = NSRect(x: notch.midX - size.width / 2, y: geometry.screen.frame.maxY - size.height, width: size.width, height: size.height)
        panel.setFrame(frame, display: true, animate: false)
    }
}

@MainActor @Observable final class NotchModel {
    static let wing: CGFloat = 58
    static let cardWidth: CGFloat = 440
    static let cardHeight: CGFloat = 158
    var expanded = false
    var panelExpanded = false
    var collapsedWidth: CGFloat { notchWidth + (showWings ? NotchModel.wing * 2 : 0) }
    var showWings = false
    var notchWidth: CGFloat = 200
    var notchHeight: CGFloat = 32
    var pulse = 0
}

/// Content of the notch panel: wings with live indicators, and a card that springs out of the notch on hover.
struct NotchView: View {
    let store: WorkspaceStore
    let model: NotchModel
    let onHover: (Bool) -> Void
    @State private var hoverTask: Task<Void, Never>?

    private var repo: RepositorySnapshot? { store.repository }
    private var changes: Int { store.files.count }
    private var incoming: Int { repo?.behind ?? 0 }
    private var outgoing: Int { repo?.ahead ?? 0 }
    private var hasNews: Bool { changes > 0 || incoming > 0 || outgoing > 0 || store.busy }
    private var shapeSize: CGSize {
        model.expanded ? CGSize(width: NotchModel.cardWidth, height: model.notchHeight + NotchModel.cardHeight)
                       : CGSize(width: model.collapsedWidth, height: model.notchHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: model.expanded ? 26 : 12, bottomTrailingRadius: model.expanded ? 26 : 12, style: .continuous)
                    .fill(.black)
                    .shadow(color: .black.opacity(model.expanded ? 0.32 : 0), radius: 20, y: 10)
                if model.expanded { expandedCard.transition(.opacity.combined(with: .offset(y: -8))) }
                else { wings.transition(.opacity) }
            }
            .frame(width: shapeSize.width, height: shapeSize.height)
            .contentShape(Rectangle())
            .onHover { inside in
                hoverTask?.cancel()
                hoverTask = Task { try? await Task.sleep(for: .milliseconds(inside ? 110 : 300)); if !Task.isCancelled { onHover(inside) } }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: hasNews, initial: true) { _, news in
            guard model.showWings != news else { return }
            withAnimation(.snappy) { model.showWings = news }
            if !model.panelExpanded { NotchController.shared.reposition() }
        }
        .onChange(of: incoming) { old, new in if new > old { model.pulse += 1 } }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notch")
    }

    /// Indicators to the left and right of the camera housing.
    private var wings: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                if store.busy { ProgressView().controlSize(.mini) }
                else if changes > 0 { Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(Brand.green); Text(changes, format: .number) }
            }.frame(width: NotchModel.wing)
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                if incoming > 0 { Image(systemName: "arrow.down").foregroundStyle(.orange).symbolEffect(.bounce, value: model.pulse); Text(incoming, format: .number) }
                else if outgoing > 0 { Image(systemName: "arrow.up").foregroundStyle(Brand.green); Text(outgoing, format: .number) }
            }.frame(width: NotchModel.wing)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
        .frame(height: model.notchHeight)
        .opacity(model.showWings ? 1 : 0)
    }

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                BrandMark(size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    // Switch repository from the notch.
                    Menu {
                        ForEach(store.recent, id: \.self) { path in
                            Button { store.reopenRecent(path) } label: { if path == repo?.root { Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "checkmark") } else { Text(URL(fileURLWithPath: path).lastPathComponent) } }
                        }
                        Divider()
                        Button(L("openRepository") + "…") { activate(); store.chooseRepository() }
                        Button(L("cloneRepository") + "…") { activate(); store.cloningRepository = true }
                        Button(L("newRepository") + "…") { activate(); store.creatingRepository = true }
                        if repo?.canPublish == true { Button(L("publishRepository") + "…") { activate(); store.publishingRepository = true } }
                        Divider()
                        Button(L("notchHide")) { NotchController.shared.disable(store: store) }
                        SettingsLink { Text(L("notchSettings")) }
                    } label: {
                        Text(repo?.name ?? "Butake Git").font(.system(size: 14, weight: .semibold))
                    }.menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize().help(L("notchSwitchRepository")).accessibilityIdentifier("notch.repository")
                    HStack(spacing: 6) {
                        // Switch branch from the notch.
                        Menu {
                            ForEach(repo?.branches ?? []) { branch in
                                Button { store.action("switch_branch", value: branch.name) } label: { if branch.current { Label(branch.name, systemImage: "checkmark") } else { Text(branch.name) } }.disabled(branch.current)
                            }
                            if let remotes = repo?.remoteOnly, !remotes.isEmpty {
                                Menu(L("remoteBranches")) { ForEach(remotes) { remote in Button(remote.short) { store.trackBranch(remote) } } }
                            }
                            Divider()
                            Button(L("newBranch") + "…") { NotchQuickPanel.shared.show(.newBranch, store: store) }
                        } label: {
                            Label(repo?.branch ?? L("openRepository"), systemImage: "arrow.triangle.branch")
                        }.menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize().help(L("notchSwitchBranch")).disabled(repo == nil || store.busy).accessibilityIdentifier("notch.branch")
                        Text("·").foregroundStyle(.white.opacity(0.35))
                        Text(statusText).foregroundStyle(statusColor)
                    }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                Spacer()
                NotchCircleButton(icon: "macwindow", title: L("notchOpen")) { activate() }
            }
            HStack(spacing: 0) {
                NotchStat(value: changes.formatted(), label: L("notchChanges"), tint: changes > 0 ? Brand.green : .white)
                NotchDivider()
                NotchStat(value: lineTotals, label: L("notchLines"), tint: .white)
                NotchDivider()
                NotchStat(value: incoming.formatted(), label: L("notchIncoming"), tint: incoming > 0 ? .orange : .white)
                NotchDivider()
                NotchStat(value: outgoing.formatted(), label: L("notchOutgoing"), tint: outgoing > 0 ? Brand.green : .white)
                NotchDivider()
                NotchStat(value: commitsToday.formatted(), label: L("notchToday"), tint: .white)
            }
            HStack(spacing: 18) {
                NotchCircleButton(icon: "arrow.down.to.line", title: L("notchFetch"), spinning: store.runningAction == "fetch") { store.action("fetch") }.disabled(!store.canFetch).help(store.remoteHelp("fetchHelp"))
                NotchCircleButton(icon: "arrow.down", title: L("notchPull"), highlight: incoming > 0) { confirm("pull") }.disabled(!store.canPull).help(store.remoteHelp("pullHelp")).accessibilityIdentifier("notch.pull")
                NotchCircleButton(icon: "arrow.up", title: L("notchPush"), highlight: outgoing > 0) { confirm("push") }.disabled(!store.canPush).help(store.remoteHelp("pushHelp")).accessibilityIdentifier("notch.push")
                if changes > 0 { NotchCircleButton(icon: "checkmark", title: L("notchCommit"), highlight: outgoing == 0 && incoming == 0) { NotchQuickPanel.shared.show(.commit, store: store) }.disabled(!store.canWrite).accessibilityIdentifier("notch.commit").transition(.scale.combined(with: .opacity)) }
                Spacer()
                Text(lastFetchText).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }
        }
        .foregroundStyle(.white)
        .padding(.top, model.notchHeight + 4).padding(.horizontal, 20).padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var statusText: String {
        if store.busy { return L("notchWorking") }
        if incoming > 0 { return String(format: L("notchToPull"), incoming) }
        if outgoing > 0 { return String(format: L("notchToPush"), outgoing) }
        if repo?.hasRemote == false { return L("localOnly") }
        if repo?.remote.isEmpty ?? true { return L("noUpstream") }
        return L("upToDate")
    }
    private var statusColor: Color { incoming > 0 ? .orange : outgoing > 0 ? Brand.green : .white.opacity(0.65) }
    private var lineTotals: String {
        let stats = store.fileStats.values
        let add = stats.compactMap(\.additions).reduce(0, +), del = stats.compactMap(\.deletions).reduce(0, +)
        return add + del == 0 ? "0" : "+\(add.formatted()) −\(del.formatted())"
    }
    private var commitsToday: Int {
        let start = Calendar.current.startOfDay(for: Date())
        let head = store.refs.reachableFromHead
        return (repo?.commits ?? []).filter { $0.date >= start && head.contains($0.hash) }.count
    }
    private var lastFetchText: String {
        guard let date = store.lastFetch else { return L("notchNeverFetched") }
        return String(format: L("notchFetched"), date.formatted(.relative(presentation: .named)))
    }
    /// Push/pull are confirmed in the floating panel under the notch, not in the main window.
    private func confirm(_ action: String) {
        guard let operation = store.confirmation(for: action) else { return }
        NotchQuickPanel.shared.show(.confirm(PendingOperationSnapshot(action: action, title: operation.title, preview: operation.preview, detail: operation.detail, destructive: operation.destructive)), store: store)
    }
    private func activate() {
        MainWindow.show()
        NotchController.shared.setExpanded(false)
    }
}

private struct NotchStat: View {
    let value: String; let label: String; let tint: Color
    var body: some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.55).countTransition(Int(value) ?? WorkspaceStore.animationLimit)
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
private struct NotchDivider: View {
    var body: some View { Rectangle().fill(.white.opacity(0.12)).frame(width: 0.5, height: 26) }
}

/// Round control in the style of Control Center: system glass on macOS 26, material before.
private struct NotchCircleButton: View {
    let icon: String; let title: String; var highlight = false; var spinning = false; let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                    .symbolEffect(.pulse, isActive: spinning)
                    .frame(width: 34, height: 34)
                    .foregroundStyle(highlight ? .black : .white)
                    .modifier(CircleGlass(highlight: highlight, hovering: hovering && enabled))
                Text(title).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(hovering && enabled ? 1.06 : 1)
            .animation(.snappy(duration: 0.18), value: hovering)
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
        .onHover { hovering = $0 }
    }
}
private struct CircleGlass: ViewModifier {
    let highlight: Bool; let hovering: Bool
    func body(content: Content) -> some View {
        if highlight {
            content.background(Brand.green, in: Circle())
        } else if #available(macOS 26.0, *) {
            content.background(.white.opacity(hovering ? 0.16 : 0.08), in: Circle()).glassEffect(.regular.interactive(), in: Circle())
        } else {
            content.background(.white.opacity(hovering ? 0.22 : 0.12), in: Circle())
        }
    }
}
