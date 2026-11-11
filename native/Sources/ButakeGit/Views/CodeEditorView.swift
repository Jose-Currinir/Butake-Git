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
        // Large files: lay out what is on screen, not the whole document, after every coloring pass.
        view.layoutManager?.allowsNonContiguousLayout = true
        view.textStorage?.delegate = context.coordinator
        view.string = text; view.isEditable = editable
        context.coordinator.synced = text
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
        // `synced` is the last text exchanged with the binding: while it is the same storage this check is O(1),
        // instead of comparing the whole document against the text view on every SwiftUI update.
        if context.coordinator.synced != text {
            context.coordinator.synced = text
            guard view.string != text else { return }
            let selection = view.selectedRanges
            view.string = text; view.lineStarts = nil; context.coordinator.highlight(view)
            // Undo steps recorded for the previous text would be applied over the new one (corruption or a range exception).
            view.undoManager?.removeAllActions()
            let length = (text as NSString).length
            let valid = selection.filter { $0.rangeValue.upperBound <= length }
            view.selectedRanges = valid.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : valid
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: CodeEditorView
        weak var textView: CodeTextView?
        var themeSignature = Brand.theme.signature
        private var pending: DispatchWorkItem?
        /// Last text sent to or received from the binding (see `updateNSView`).
        var synced = ""
        /// Whether each line ends inside a block comment (index = line). With it an edit re-colors only its own lines,
        /// and the lines below only while their comment state actually changes, instead of the whole document.
        private var lineEndStates: [Bool] = []
        /// False until a full pass has finished (and beyond the size limit): edits then fall back to a full pass.
        private var statesValid = false
        /// Bumped by every full pass and by edits that invalidate one in flight.
        private var generation = 0
        /// Characters edited since the last coloring, in current coordinates.
        private var edited: Range<Int>?
        /// Our own attribute changes also reach the storage delegate.
        private var applying = false
        static let sizeLimit = 600_000
        /// A full pass has finished and edits are being colored incrementally.
        var isColored: Bool { statesValid }
        init(_ parent: CodeEditorView) { self.parent = parent }

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters), !applying else { return }
            var lower = editedRange.location, upper = editedRange.location + editedRange.length
            if let previous = edited {
                let shifted = previous.upperBound >= editedRange.location ? previous.upperBound + delta : previous.upperBound
                lower = min(lower, previous.lowerBound); upper = max(upper, shifted)
            }
            edited = lower..<max(lower, upper)
        }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? CodeTextView else { return }
            view.lineStarts = nil
            // Native storage: later comparisons against it (unsaved-changes check) are a plain memory compare.
            var value = view.string; value.makeContiguousUTF8()
            synced = value; parent.text = value
            // While an input method is composing, its marked-text attributes must stay: color once it commits.
            guard !view.hasMarkedText() else { return }
            if let range = edited, statesValid, recolor(view, edited: range) { edited = nil; return }
            // No valid line states (a full pass is still running or was never possible): full pass once typing pauses.
            generation &+= 1; statesValid = false
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
            // Keep the file's own line ending: a bare "\n" inside a CRLF file would mix both styles.
            let newline = text.range(of: "\r\n", options: .literal).location != NSNotFound ? "\r\n" : "\n"
            textView.insertText(newline + indent, replacementRange: textView.selectedRange())
            return true
        }

        // MARK: Coloring

        private func baseAttributes(_ view: NSTextView) -> [NSAttributedString.Key: Any] {
            [.font: CodeEditorStyle.font, .foregroundColor: Brand.textNS, .paragraphStyle: view.defaultParagraphStyle ?? .default]
        }
        /// Resets and colors one line (lines are split on "\n", like `CodeTextView.lineStarts`); `state` is the
        /// block-comment state entering the line and leaves as the state after it.
        private func color(_ line: Int, starts: [Int], text: NSString, storage: NSTextStorage, base: [NSAttributedString.Key: Any], highlighter: SyntaxHighlighter, state: inout Bool) {
            let start = starts[line], end = line + 1 < starts.count ? starts[line + 1] : text.length
            guard end > start else { return }
            storage.setAttributes(base, range: NSRange(location: start, length: end - start))
            var contentEnd = end
            if contentEnd > start, text.character(at: contentEnd - 1) == 0x0A { contentEnd -= 1 }
            if contentEnd > start, text.character(at: contentEnd - 1) == 0x0D { contentEnd -= 1 }
            guard contentEnd > start else { return }
            for (span, value) in highlighter.spans(text.substring(with: NSRange(location: start, length: contentEnd - start)), inBlockComment: &state) {
                storage.addAttribute(.foregroundColor, value: value, range: NSRange(location: start + span.location, length: span.length))
            }
        }
        private static func lineIndex(_ starts: [Int], at location: Int) -> Int {
            var low = 0, high = starts.count - 1
            while low < high { let mid = (low + high + 1) / 2; if starts[mid] <= location { low = mid } else { high = mid - 1 } }
            return low
        }
        /// Re-colors the edited lines and whatever follows while its comment state changes. Returns false when the
        /// cached states cannot answer (the caller then runs a full pass).
        private func recolor(_ view: CodeTextView, edited: Range<Int>) -> Bool {
            guard let storage = view.textStorage else { return false }
            let text = storage.string as NSString, length = text.length
            guard length < Coordinator.sizeLimit else { statesValid = false; return true }
            let starts = view.lineStartOffsets()
            let first = Coordinator.lineIndex(starts, at: min(edited.lowerBound, length)), last = Coordinator.lineIndex(starts, at: min(edited.upperBound, length))
            // Lines the edit replaced, in the old numbering.
            let oldLast = last - (starts.count - lineEndStates.count)
            guard oldLast >= first, oldLast < lineEndStates.count, last - first < 3_000 else { return false }
            let oldExit = lineEndStates[oldLast]
            var state = first > 0 ? lineEndStates[first - 1] : false
            let base = baseAttributes(view), highlighter = SyntaxHighlighter(language: CodeLanguage.of(parent.path))
            var fresh: [Bool] = []; fresh.reserveCapacity(last - first + 1)
            applying = true; storage.beginEditing()
            for line in first...last { color(line, starts: starts, text: text, storage: storage, base: base, highlighter: highlighter, state: &state); fresh.append(state) }
            lineEndStates.replaceSubrange(first...oldLast, with: fresh)
            var complete = true
            if state != oldExit {
                // The edit opened or closed a block comment: the lines below change until the old state is met again.
                var line = last + 1
                while line < starts.count {
                    if line - last > 3_000 { complete = false; break }
                    let cached = lineEndStates[line]
                    color(line, starts: starts, text: text, storage: storage, base: base, highlighter: highlighter, state: &state)
                    lineEndStates[line] = state; line += 1
                    if state == cached { break }
                }
            }
            storage.endEditing(); applying = false
            view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            // A comment change that reaches far down: finish with a sliced full pass instead of stalling this keystroke.
            if !complete { highlight(view) }
            return true
        }
        /// Full pass: first load, theme change and programmatic text replacement. Runs in slices of a few
        /// milliseconds so a large file never blocks the main thread while it is colored.
        func highlight(_ view: NSTextView) {
            pending?.cancel(); generation &+= 1; edited = nil; statesValid = false
            guard let view = view as? CodeTextView, let storage = view.textStorage else { return }
            let length = (storage.string as NSString).length
            guard length < Coordinator.sizeLimit else { return }
            let starts = view.lineStartOffsets()
            applying = true; storage.beginEditing()
            storage.setAttributes(baseAttributes(view), range: NSRange(location: 0, length: length))
            storage.endEditing(); applying = false
            lineEndStates = [Bool](repeating: false, count: starts.count)
            continueHighlight(view, from: 0, state: false, generation: generation, highlighter: SyntaxHighlighter(language: CodeLanguage.of(parent.path)), budget: 0.008)
        }
        private func continueHighlight(_ view: CodeTextView, from line: Int, state: Bool, generation: Int, highlighter: SyntaxHighlighter, budget: CFTimeInterval) {
            guard generation == self.generation, let storage = view.textStorage else { return }
            let text = storage.string as NSString, starts = view.lineStartOffsets()
            guard starts.count == lineEndStates.count else { return }
            let base = baseAttributes(view), deadline = CFAbsoluteTimeGetCurrent() + budget
            var line = line, state = state
            applying = true; storage.beginEditing()
            while line < starts.count {
                color(line, starts: starts, text: text, storage: storage, base: base, highlighter: highlighter, state: &state)
                lineEndStates[line] = state; line += 1
                if line % 32 == 0, CFAbsoluteTimeGetCurrent() > deadline { break }
            }
            storage.endEditing(); applying = false
            if line < starts.count {
                DispatchQueue.main.async { [weak self, weak view] in
                    if let self, let view { self.continueHighlight(view, from: line, state: state, generation: generation, highlighter: highlighter, budget: 0.008) }
                }
            } else {
                statesValid = true
                view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            }
        }
    }
}

enum CodeEditorStyle {
    static var font: NSFont { NSFont.monospacedSystemFont(ofSize: TextScale.points(12.5), weight: .regular) }
    static var advance: CGFloat { ("0" as NSString).size(withAttributes: [.font: font]).width }
    static let currentLine = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.035) }
}

final class CodeTextView: NSTextView {
    override var wantsDefaultClipping: Bool { true }
    /// UTF-16 offset where each line starts. Built once per text change (reset to nil when the text changes), so the
    /// ruler finds a line number with a binary search instead of walking the whole document on every draw.
    /// Counted on the line feed (0x0A): correct for CRLF files, where "\r\n" is a single Character.
    var lineStarts: [Int]?
    func lineNumber(at location: Int) -> Int {
        let starts = lineStartOffsets()
        var low = 0, high = starts.count - 1
        while low < high { let mid = (low + high + 1) / 2; if starts[mid] <= location { low = mid } else { high = mid - 1 } }
        return low + 1
    }
    /// `lineStarts`, building it when the text changed since the last call.
    func lineStartOffsets() -> [Int] {
        if lineStarts == nil {
            let text = string as NSString; let length = text.length
            var starts = [0]; var buffer = [unichar](repeating: 0, count: min(length, 65_536)); var offset = 0
            while offset < length {
                let count = min(buffer.count, length - offset)
                text.getCharacters(&buffer, range: NSRange(location: offset, length: count))
                for index in 0..<count where buffer[index] == 0x0A { starts.append(offset + index + 1) }
                offset += count
            }
            lineStarts = starts
        }
        return lineStarts ?? [0]
    }
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        // Current line band (only while there is no multi-character selection).
        guard selectedRange().length == 0, let manager = layoutManager, let container = textContainer else { return }
        let text = string as NSString; let length = text.length
        let caret = min(selectedRange().location, length)
        var lineRect: NSRect
        if length == 0 || caret == length && text.character(at: length - 1) == 0x0A {
            lineRect = manager.extraLineFragmentRect
        } else {
            let glyph = manager.glyphIndexForCharacter(at: max(0, min(caret, length - 1)))
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
        guard let view = clientView as? CodeTextView, let manager = view.layoutManager, let container = view.textContainer else { return }
        let text = view.string as NSString
        let caretLine = view.lineNumber(at: min(view.selectedRange().location, text.length))
        let style = NSMutableParagraphStyle(); style.alignment = .right
        let normal: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: TextScale.points(10.5), weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style]
        let current: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: TextScale.points(10.5), weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
        let glyphs = manager.glyphRange(forBoundingRect: view.visibleRect, in: container)
        let firstCharacter = manager.characterIndexForGlyph(at: glyphs.location)
        var number = view.lineNumber(at: firstCharacter)
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
