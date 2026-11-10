import SwiftUI
import AppKit

struct DiffView: NSViewRepresentable {
    static let maxLines = 20_000
    /// Very large patches stay responsive: render the first lines and say how many were omitted.
    static func capped(_ text: String) -> String {
        var count = 0; var cut: String.Index?
        for index in text.indices where text[index] == "\n" { count += 1; if count == maxLines { cut = index; break } }
        guard let cut else { return text }
        let remaining = text[text.index(after: cut)...].reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return String(text[..<cut]) + "\n\\ " + String(format: L("diffTruncated"), remaining)
    }
    let text: String
    /// File shown, for syntax colors when the patch itself does not name it.
    var path: String? = nil
    var onHunk: ((Int) -> Void)? = nil
    var hunkTitle: String = L("hunkStage")
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.automaticallyAdjustsContentInsets = false; scroll.contentInsets = NSEdgeInsetsZero
        scroll.contentView.automaticallyAdjustsContentInsets = false; scroll.contentView.contentInsets = NSEdgeInsetsZero
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay; scroll.borderType = .noBorder
        scroll.drawsBackground = true; scroll.backgroundColor = .textBackgroundColor
        // macOS 14+ no longer clips by default: without this the ruler separator escapes the scroll view.
        scroll.clipsToBounds = true
        let editor = DiffTextView(frame: .zero)
        editor.isEditable = false; editor.isSelectable = true; editor.isRichText = false
        editor.usesFindBar = true; editor.isIncrementalSearchingEnabled = true
        editor.font = DiffStyle.font
        // The ruler overlays the document (overlay scrollers), so the text starts past it.
        editor.textContainerInset = NSSize(width: 104, height: 10)
        editor.isHorizontallyResizable = true; editor.isVerticallyResizable = true
        editor.minSize = .zero; editor.maxSize = NSSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize = NSSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = false
        editor.backgroundColor = .textBackgroundColor; editor.textColor = .textColor; editor.drawsBackground = true
        scroll.documentView = editor
        let ruler = DiffLineRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = editor; ruler.clipsToBounds = true; editor.clipsToBounds = true; scroll.verticalRulerView = ruler; scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        return scroll
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 400)
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? DiffTextView else { return }
        editor.onHunk = onHunk; editor.hunkTitle = hunkTitle
        if editor.source != text {
            editor.source = text; editor.displayLines = UnifiedDiff(DiffView.capped(text)).lines
            let rendered = DiffRenderer.render(editor.displayLines, path: path ?? DiffRenderer.firstPath(in: text))
            let attributed = rendered.text; let ranges = rendered.ranges
            editor.wordRanges = rendered.words
            let font = DiffStyle.font
            // Monospaced: width is the longest line's length times one glyph advance, no per-line text measurement.
            let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
            let longest = CGFloat(editor.displayLines.reduce(0) { max($0, ($1.text as NSString).length) }) * advance
            let width = max(scroll.contentSize.width, ceil(longest) + 220)
            editor.setFrameSize(NSSize(width: width, height: max(scroll.contentSize.height, 200)))
            editor.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            editor.lineRanges = ranges; editor.textStorage?.setAttributedString(attributed)
            editor.layoutManager?.ensureLayout(for: editor.textContainer!)
            if let manager = editor.layoutManager, let container = editor.textContainer {
                let rect = manager.usedRect(for: container)
                editor.setFrameSize(NSSize(width: width, height: max(scroll.contentSize.height, rect.height + 28)))
            }
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
            DispatchQueue.main.async { scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }
        }
        editor.needsDisplay = true; scroll.verticalRulerView?.needsDisplay = true
    }
}
/// `lineRanges` are contiguous and sorted, so the line for a character is found in O(log n).
func lineIndex(for character: Int, in ranges: [NSRange]) -> Int? {
    var low = 0, high = ranges.count - 1
    while low <= high {
        let mid = (low + high) / 2, range = ranges[mid]
        if character < range.location { high = mid - 1 } else if character >= range.location + range.length { low = mid + 1 } else { return mid }
    }
    return nil
}
private final class DiffTextView: NSTextView {
    override var wantsDefaultClipping: Bool { true }
    var hunkTitle = L("hunkStage")
    var source: String?
    var displayLines: [DiffDisplayLine] = []
    var lineRanges: [NSRange] = []
    /// Character ranges that changed inside a modified line (drawn as a stronger tint).
    var wordRanges: [(NSRange, DiffDisplayLine.Kind)] = []
    var onHunk: ((Int) -> Void)?
    override func drawBackground(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer else { return }
        let range = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        layoutManager.enumerateLineFragments(forGlyphRange: range) { [self] lineRect, _, _, glyphs, _ in
            let character = layoutManager.characterIndexForGlyph(at: glyphs.location)
            guard let index = lineIndex(for: character, in: self.lineRanges), index < displayLines.count else { return }
            guard let color = DiffStyle.background(displayLines[index].kind) else { return }
            color.setFill(); NSRect(x: 0, y: lineRect.minY + textContainerInset.height, width: bounds.width, height: lineRect.height).fill()
        }
        let visibleCharacters = layoutManager.characterRange(forGlyphRange: range, actualGlyphRange: nil)
        for (word, kind) in wordRanges where NSIntersectionRange(word, visibleCharacters).length > 0 {
            let glyphs = layoutManager.glyphRange(forCharacterRange: word, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
                (kind == .addition ? DiffStyle.addedWord : DiffStyle.removedWord).setFill()
                NSBezierPath(roundedRect: rect.offsetBy(dx: self.textContainerInset.width, dy: self.textContainerInset.height).insetBy(dx: -1, dy: 1), xRadius: 3, yRadius: 3).fill()
            }
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard onHunk != nil, let manager = layoutManager, let container = textContainer else { return menu }
        let point = convert(event.locationInWindow, from: nil)
        let glyph = manager.glyphIndex(for: NSPoint(x: point.x - textContainerInset.width, y: point.y - textContainerInset.height), in: container)
        guard glyph < manager.numberOfGlyphs else { return menu }
        let character = manager.characterIndexForGlyph(at: glyph)
        if let index = lineIndex(for: character, in: lineRanges), let hunk = displayLines[index].hunk {
            menu.addItem(.separator())
            let item = NSMenuItem(title: hunkTitle, action: #selector(applyHunk(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = hunk; menu.addItem(item)
        }
        return menu
    }
    @objc private func applyHunk(_ sender: NSMenuItem) { if let index = sender.representedObject as? Int { onHunk?(index) } }
}
private final class DiffLineRuler: NSRulerView {
    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { true }
    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) { super.init(scrollView: scrollView, orientation: orientation); ruleThickness = 92 }
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor.textBackgroundColor.setFill(); rect.intersection(bounds).fill()
        guard let editor = clientView as? DiffTextView, let manager = editor.layoutManager, let container = editor.textContainer else { return }
        let range = manager.glyphRange(forBoundingRect: editor.visibleRect, in: container)
        let style = NSMutableParagraphStyle(); style.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style]
        let markerFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        manager.enumerateLineFragments(forGlyphRange: range) { [self] lineRect, _, _, glyphs, _ in
            let character = manager.characterIndexForGlyph(at: glyphs.location)
            guard let index = lineIndex(for: character, in: editor.lineRanges), index < editor.displayLines.count else { return }
            let line = editor.displayLines[index]
            let point = convert(NSPoint(x: 0, y: lineRect.minY + editor.textContainerInset.height), from: editor)
            let row = NSRect(x: 0, y: point.y, width: bounds.width, height: lineRect.height)
            if let tint = DiffStyle.background(line.kind) { tint.setFill(); row.fill() }
            if line.kind == .addition || line.kind == .deletion {
                (line.kind == .addition ? DiffStyle.addition : DiffStyle.deletion).setFill(); NSRect(x: 0, y: row.minY, width: 3, height: row.height).fill()
                let marker = line.kind == .addition ? "+" : "−"
                (marker as NSString).draw(at: NSPoint(x: bounds.width - 18, y: row.minY + 2), withAttributes: [.font: markerFont, .foregroundColor: line.kind == .addition ? DiffStyle.addition : DiffStyle.deletion])
            }
            if let old = line.oldLine { (String(old) as NSString).draw(in: NSRect(x: 4, y: row.minY + 2.5, width: 30, height: row.height), withAttributes: attributes) }
            if let new = line.newLine { (String(new) as NSString).draw(in: NSRect(x: 38, y: row.minY + 2.5, width: 30, height: row.height), withAttributes: attributes) }
        }
        let visible = rect.intersection(bounds)
        NSColor.separatorColor.setFill(); NSRect(x: bounds.maxX - 1, y: visible.minY, width: 1, height: visible.height).fill()
    }
}
struct FileInspector: View {
    let store: WorkspaceStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(L("fileDetails")).font(.headline); Spacer(); InspectorCloseButton(store: store) }
                if let file = store.selectedFile {
                    HStack(alignment: .top, spacing: 10) {
                        FileTypeIcon(path: file.path, size: 26)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.name).font(.title3.weight(.semibold)).lineLimit(2)
                            if !file.directory.isEmpty { Text(file.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                            ChangeKindBadge(kind: file.kind).padding(.top, 2)
                        }
                    }
                    if let original = file.originalPath { Label(String(format: L("movedFrom"), original), systemImage: "arrow.right").font(.caption).foregroundStyle(.purple).lineLimit(2) }
                    Divider()
                    stateRow(L("staged"), active: file.index != " " && file.index != "?", stats: store.stats(for: file, staged: true))
                    stateRow(L("unstaged"), active: file.worktree != " " || file.index == "?", stats: store.stats(for: file, staged: false))
                    if store.isReviewed(file) { Label(L("reviewedMark"), systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(Brand.accent) }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Button { store.action(store.stagedSelection ? "unstage" : "stage", value: file.path) } label: { Label(L(store.stagedSelection ? "unstage" : "stage"), systemImage: store.stagedSelection ? "minus.circle" : "plus.circle").frame(maxWidth: .infinity, alignment: .leading) }
                            .accessibilityIdentifier("inspector.toggleStage").disabled(store.busy || store.terminalActive)
                        Button { store.copyToPasteboard(file.path) } label: { Label(L("copyPath"), systemImage: "doc.on.doc").frame(maxWidth: .infinity, alignment: .leading) }.accessibilityIdentifier("inspector.copyPath")
                        Button { if let root = store.repository?.root { NSWorkspace.shared.selectFile((root as NSString).appendingPathComponent(file.path), inFileViewerRootedAtPath: root) } } label: { Label(L("openFinder"), systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading) }
                            .disabled(file.kind == .deleted).accessibilityIdentifier("inspector.reveal")
                        if !store.stagedSelection && file.kind != .conflict {
                            Button(role: .destructive) { store.discard(file) } label: { Label(L("discardChanges"), systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity, alignment: .leading) }
                                .disabled(!store.canWrite || store.busy).accessibilityIdentifier("inspector.discard")
                        }
                    }.controlSize(.regular)
                    Text(L("diffContextMenu")).font(.caption2).foregroundStyle(.tertiary)
                } else { Text(L("chooseFile")).foregroundStyle(.secondary).font(.caption) }
            }.padding(20)
        }.background(.background)
    }
    private func stateRow(_ title: String, active: Bool, stats: LineStats?) -> some View {
        HStack {
            Image(systemName: active ? "circle.inset.filled" : "circle").font(.system(size: 9)).foregroundStyle(active ? Brand.accent : Color.secondary.opacity(0.5))
            Text(title).font(.callout)
            Spacer()
            if active, let stats { StatsBadge(stats: stats) } else if !active { Text("—").foregroundStyle(.tertiary) }
        }
    }
}

enum DiffStyle {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let addition = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.33, green: 0.80, blue: 0.53, alpha: 1) : NSColor(srgbRed: 0.10, green: 0.55, blue: 0.30, alpha: 1) }
    static let deletion = NSColor.systemRed
    static let addedWord = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.25, green: 0.70, blue: 0.42, alpha: 0.34) : NSColor(srgbRed: 0.25, green: 0.72, blue: 0.40, alpha: 0.30) }
    static let removedWord = NSColor.systemRed.withAlphaComponent(0.28)
    static func background(_ kind: DiffDisplayLine.Kind) -> NSColor? {
        switch kind {
        case .addition: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.20, green: 0.55, blue: 0.32, alpha: 0.16) : NSColor(srgbRed: 0.85, green: 0.96, blue: 0.88, alpha: 1) }
        case .deletion: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.70, green: 0.20, blue: 0.20, alpha: 0.18) : NSColor(srgbRed: 1.0, green: 0.92, blue: 0.92, alpha: 1) }
        case .hunk: NSColor.systemBlue.withAlphaComponent(0.06)
        case .metadata: NSColor.labelColor.withAlphaComponent(0.06)
        default: nil
        }
    }
}

/// Builds the attributed diff: code without +/− markers (they live in the gutter), syntax colors,
/// friendly annotations and the changed part of each modified line.
enum DiffRenderer {
    static func firstPath(in text: String) -> String? {
        for line in text.split(separator: "\n", maxSplits: 40, omittingEmptySubsequences: true).prefix(40) {
            if line.hasPrefix("+++ b/") { return String(line.dropFirst(6)) }
            if line.hasPrefix("diff --git "), let range = line.range(of: " b/", options: .backwards) { return String(line[range.upperBound...]) }
        }
        return nil
    }
    static func render(_ lines: [DiffDisplayLine], path: String?) -> (text: NSAttributedString, ranges: [NSRange], words: [(NSRange, DiffDisplayLine.Kind)]) {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3.5; paragraph.lineBreakMode = .byClipping
        let base: [NSAttributedString.Key: Any] = [.font: DiffStyle.font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
        var highlighter = SyntaxHighlighter(language: CodeLanguage.of(path))
        var blockOld = false, blockNew = false
        var ranges: [NSRange] = []; ranges.reserveCapacity(lines.count)
        var bodies: [String] = []; bodies.reserveCapacity(lines.count)
        for line in lines {
            var body = line.text
            var attributes = base
            switch line.kind {
            case .addition, .deletion, .context:
                // Plain file content (untracked files) has no marker column: context without an old line number.
                if !body.isEmpty && (line.kind != .context || line.oldLine != nil) { body.removeFirst() }
            case .hunk:
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            case .annotation:
                body = friendly(body); attributes[.foregroundColor] = NSColor.secondaryLabelColor
                attributes[.font] = NSFont.systemFont(ofSize: 11.5, weight: .medium)
            case .metadata:
                attributes[.font] = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
                // Multi-file output ("▸ path"): switch language per file.
                if body.hasPrefix("▸ ") { highlighter = SyntaxHighlighter(language: CodeLanguage.of(String(body.dropFirst(2)))); blockOld = false; blockNew = false }
            }
            let start = result.length
            result.append(NSAttributedString(string: body + "\n", attributes: attributes))
            ranges.append(NSRange(location: start, length: (body as NSString).length + 1))
            bodies.append(body)
            if [.addition, .deletion, .context].contains(line.kind) {
                // Old and new sides keep separate comment state so a removed "/*" does not tint added lines.
                var state = line.kind == .deletion ? blockOld : blockNew
                for (range, color) in highlighter.spans(body, inBlockComment: &state) {
                    result.addAttribute(.foregroundColor, value: color, range: NSRange(location: start + range.location, length: range.length))
                }
                if line.kind != .addition { blockOld = state }
                if line.kind != .deletion { blockNew = state }
            }
        }
        return (result, ranges, changedWords(lines, bodies: bodies, ranges: ranges))
    }
    /// Pairs each run of removed lines with the following added lines and marks what differs between them.
    private static func changedWords(_ lines: [DiffDisplayLine], bodies: [String], ranges: [NSRange]) -> [(NSRange, DiffDisplayLine.Kind)] {
        var words: [(NSRange, DiffDisplayLine.Kind)] = []
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .deletion else { index += 1; continue }
            var removedEnd = index; while removedEnd < lines.count, lines[removedEnd].kind == .deletion { removedEnd += 1 }
            var addedEnd = removedEnd; while addedEnd < lines.count, lines[addedEnd].kind == .addition { addedEnd += 1 }
            let pairs = min(removedEnd - index, addedEnd - removedEnd)
            if pairs > 0 && pairs <= 40 {
                for offset in 0..<pairs {
                    let old = bodies[index + offset] as NSString, new = bodies[removedEnd + offset] as NSString
                    var prefix = 0; while prefix < old.length, prefix < new.length, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
                    var suffix = 0; while suffix < old.length - prefix, suffix < new.length - prefix, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
                    let oldLength = old.length - prefix - suffix, newLength = new.length - prefix - suffix
                    // Only when the lines are mostly alike; otherwise the whole line already reads as changed.
                    guard prefix + suffix >= 3, Double(prefix + suffix) / Double(max(old.length, new.length, 1)) > 0.3 else { continue }
                    if oldLength > 0 { words.append((NSRange(location: ranges[index + offset].location + prefix, length: oldLength), .deletion)) }
                    if newLength > 0 { words.append((NSRange(location: ranges[removedEnd + offset].location + prefix, length: newLength), .addition)) }
                }
            }
            index = addedEnd
        }
        return words
    }
    /// Git's technical header lines in plain Spanish.
    static func friendly(_ line: String) -> String {
        if line.hasPrefix("new file mode") { return "＋ " + L("diffNewFile") }
        if line.hasPrefix("deleted file mode") { return "－ " + L("diffDeletedFile") }
        if line.hasPrefix("rename from ") { return "↳ " + String(format: L("diffRenamedFrom"), String(line.dropFirst(12))) }
        if line.hasPrefix("rename to ") { return "↳ " + String(format: L("diffRenamedTo"), String(line.dropFirst(10))) }
        if line.hasPrefix("similarity index ") { return String(format: L("diffSimilarity"), String(line.dropFirst(17))) }
        if line.hasPrefix("Binary files") { return L("diffBinary") }
        if line.hasPrefix("\\ No newline") { return L("diffNoNewline") }
        return line
    }
}
