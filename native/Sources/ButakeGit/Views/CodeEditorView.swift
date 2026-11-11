import SwiftUI
import AppKit

/// Native code editor: line numbers, syntax colors, current-line highlight, auto-indent and no
/// "smart" substitutions (quotes, dashes, spelling) that would corrupt source files.
struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    var path: String
    var editable = true
    var themeSignature = Brand.theme.signature

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay; scroll.borderType = .noBorder; scroll.drawsBackground = true
        scroll.backgroundColor = Brand.surfaceNS; scroll.clipsToBounds = true
        let view = CodeTextView(frame: .zero)
        view.delegate = context.coordinator
        view.isRichText = false; view.importsGraphics = false; view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false; view.isGrammarCheckingEnabled = false; view.smartInsertDeleteEnabled = false
        view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        view.font = CodeEditorStyle.font; view.textColor = Brand.textNS; view.backgroundColor = Brand.surfaceNS
        view.insertionPointColor = NSColor(Brand.accent)
        view.selectedTextAttributes = [.backgroundColor: NSColor(Brand.accent).withAlphaComponent(0.22)]
        view.textContainerInset = NSSize(width: 10, height: 12)
        view.isHorizontallyResizable = true; view.isVerticallyResizable = true
        view.minSize = .zero; view.maxSize = NSSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = NSSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.autoresizingMask = [.width]
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3; paragraph.defaultTabInterval = CodeEditorStyle.advance * 4; paragraph.tabStops = []
        view.defaultParagraphStyle = paragraph
        view.typingAttributes = [.font: CodeEditorStyle.font, .foregroundColor: Brand.textNS, .paragraphStyle: paragraph]
        scroll.documentView = view
        let ruler = CodeLineRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = view; scroll.verticalRulerView = ruler; scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        context.coordinator.textView = view
        view.string = text; view.isEditable = editable
        context.coordinator.highlight(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? CodeTextView else { return }
        context.coordinator.parent = self
        view.isEditable = editable
        if context.coordinator.themeSignature != themeSignature {
            context.coordinator.themeSignature = themeSignature
            scroll.backgroundColor = Brand.surfaceNS; view.backgroundColor = Brand.surfaceNS; view.textColor = Brand.textNS
            view.insertionPointColor = NSColor(Brand.accent)
            view.selectedTextAttributes = [.backgroundColor: NSColor(Brand.accent).withAlphaComponent(0.22)]
            context.coordinator.highlight(view); scroll.verticalRulerView?.needsDisplay = true
        }
        if view.string != text {
            let selection = view.selectedRanges
            view.string = text; context.coordinator.highlight(view)
            view.selectedRanges = selection.filter { $0.rangeValue.upperBound <= (text as NSString).length }.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : selection
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var textView: CodeTextView?
        var themeSignature = Brand.theme.signature
        private var pending: DispatchWorkItem?
        init(_ parent: CodeEditorView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? CodeTextView else { return }
            parent.text = view.string
            // Re-color shortly after typing stops; small files are colored at once.
            pending?.cancel()
            let work = DispatchWorkItem { [weak self, weak view] in if let view { self?.highlight(view) } }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + ((view.string as NSString).length < 40_000 ? 0.05 : 0.3), execute: work)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? NSTextView)?.needsDisplay = true
            (notification.object as? NSTextView)?.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
        /// Auto-indent: a new line keeps the previous line's leading whitespace.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let text = textView.string as NSString
            let caret = textView.selectedRange().location
            let lineRange = text.lineRange(for: NSRange(location: min(caret, text.length), length: 0))
            let line = text.substring(with: NSRange(location: lineRange.location, length: max(0, caret - lineRange.location)))
            var indent = String(line.prefix { $0 == " " || $0 == "\t" })
            if let last = line.trimmingCharacters(in: .whitespaces).last, "{[(:".contains(last) { indent += "    " }
            textView.insertText("\n" + indent, replacementRange: textView.selectedRange())
            return true
        }
        func highlight(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            let text = storage.string as NSString
            guard text.length < 600_000 else { return }
            let highlighter = SyntaxHighlighter(language: CodeLanguage.of(parent.path))
            storage.beginEditing()
            let full = NSRange(location: 0, length: text.length)
            storage.setAttributes([.font: CodeEditorStyle.font, .foregroundColor: Brand.textNS, .paragraphStyle: view.defaultParagraphStyle ?? .default], range: full)
            var inComment = false
            text.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
                let line = text.substring(with: range)
                for (span, color) in highlighter.spans(line, inBlockComment: &inComment) {
                    storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: range.location + span.location, length: span.length))
                }
            }
            storage.endEditing()
            view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }
}

enum CodeEditorStyle {
    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
    static let currentLine = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.035) }
}

final class CodeTextView: NSTextView {
    override var wantsDefaultClipping: Bool { true }
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        // Current line band (only while there is no multi-character selection).
        guard selectedRange().length == 0, let manager = layoutManager, let container = textContainer else { return }
        let caret = min(selectedRange().location, (string as NSString).length)
        var lineRect: NSRect
        if (string as NSString).length == 0 || caret == (string as NSString).length && string.hasSuffix("\n") {
            lineRect = manager.extraLineFragmentRect
        } else {
            let glyph = manager.glyphIndexForCharacter(at: max(0, min(caret, (string as NSString).length - 1)))
            lineRect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        _ = container
        CodeEditorStyle.currentLine.setFill()
        NSRect(x: 0, y: lineRect.minY + textContainerInset.height, width: bounds.width, height: lineRect.height).fill()
    }
}

private final class CodeLineRuler: NSRulerView {
    override var isFlipped: Bool { true }
    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) { super.init(scrollView: scrollView, orientation: orientation); ruleThickness = 54 }
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        Brand.surfaceNS.setFill(); rect.intersection(bounds).fill()
        guard let view = clientView as? NSTextView, let manager = view.layoutManager, let container = view.textContainer else { return }
        let text = view.string as NSString
        let caretLine = text.substring(to: min(view.selectedRange().location, text.length)).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let style = NSMutableParagraphStyle(); style.alignment = .right
        let normal: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style]
        let current: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
        let glyphs = manager.glyphRange(forBoundingRect: view.visibleRect, in: container)
        let firstCharacter = manager.characterIndexForGlyph(at: glyphs.location)
        var number = text.substring(to: firstCharacter).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        var lastLineStart = -1
        manager.enumerateLineFragments(forGlyphRange: glyphs) { [self] lineRect, _, _, range, _ in
            let character = manager.characterIndexForGlyph(at: range.location)
            let lineStart = text.lineRange(for: NSRange(location: character, length: 0)).location
            guard lineStart != lastLineStart else { return } // wrapped continuation
            if lastLineStart >= 0 { number += 1 }
            lastLineStart = lineStart
            let y = convert(NSPoint(x: 0, y: lineRect.minY + view.textContainerInset.height), from: view).y
            ("\(number)" as NSString).draw(in: NSRect(x: 4, y: y + 2, width: bounds.width - 16, height: lineRect.height), withAttributes: number == caretLine ? current : normal)
        }
        if text.length == 0 || text.hasSuffix("\n") {
            let extra = manager.extraLineFragmentRect
            if extra.height > 0 { let y = convert(NSPoint(x: 0, y: extra.minY + view.textContainerInset.height), from: view).y; ("\(text.length == 0 ? 1 : number + 1)" as NSString).draw(in: NSRect(x: 4, y: y + 2, width: bounds.width - 16, height: extra.height), withAttributes: normal) }
        }
    }
}
