import Foundation
struct DiffDisplayLine {
    enum Kind { case metadata, hunk, addition, deletion, context, annotation }
    var text: String
    var oldLine: Int?
    var newLine: Int?
    var hunk: Int?
    var kind: Kind
    /// Index into `UnifiedDiff.files` of the file this line belongs to (multi-file output only).
    var file: Int? = nil
    /// The "▸ path" line that opens a file's section; the viewer can collapse everything else of that file.
    var fileHeader = false
}
/// One file of a multi-file patch: what happened to it and how many lines changed.
struct DiffFile: Equatable {
    var path: String
    /// Previous path of a moved file.
    var originalPath: String? = nil
    var kind: ChangeKind = .modified
    var additions = 0
    var deletions = 0
    var binary = false
}
struct UnifiedDiff {
    var lines: [DiffDisplayLine] = []
    /// Files of the patch, in order (empty when the text is not a patch).
    var files: [DiffFile] = []
    init(_ text: String) {
        let raw = text.components(separatedBy: "\n")
        // A conflicted file is shown by Git as a combined diff (`diff --cc`, `@@@` hunks, two marker columns).
        let patch = text.hasPrefix("diff --git ") || text.hasPrefix("diff --cc ") || text.hasPrefix("diff --combined ") || raw.contains { $0.hasPrefix("@@ ") || $0.hasPrefix("@@@ ") }
        var old = 0; var new = 0; var hunk = -1
        var combined = false
        let expression = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)
        let combinedExpression = try! NSRegularExpression(pattern: #"^@@@ -\d+(?:,\d+)? -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@@"#)
        // `git show`/`log -p` output carries a preamble and several files; a plain single-file diff keeps its compact form.
        let preamble = patch && !text.hasPrefix("diff --git ")
        let fileHeaders = preamble || raw.filter { $0.hasPrefix("diff --git ") }.count > 1
        var inHeader = false
        var current: Int?
        for (index, line) in raw.enumerated() {
            // Every line appended in this iteration belongs to the file being read.
            let start = lines.count
            defer { if let current { for position in start..<lines.count where lines[position].file == nil { lines[position].file = current } } }
            // \u{1} marks a commit header (format "%x01…"): show it and return to preamble mode so the
            // next commit's message and --stat lines are not mistaken for diff content.
            if line.hasPrefix("\u{1}") {
                lines.append(DiffDisplayLine(text: String(line.dropFirst()), oldLine: nil, newLine: nil, hunk: nil, kind: .metadata))
                hunk = -1; inHeader = false; current = nil; continue
            }
            if patch && (line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ")) {
                inHeader = true; combined = true
                files.append(DiffFile(path: String(line.dropFirst(line.hasPrefix("diff --cc ") ? 10 : 16)))); current = files.count - 1
                continue
            }
            if patch && line.hasPrefix("diff --git ") {
                inHeader = true; combined = false
                let path = line.range(of: " b/", options: .backwards).map { String(line[$0.upperBound...]) } ?? line
                let previous = current
                files.append(DiffFile(path: path)); current = files.count - 1
                if fileHeaders {
                    // A blank line closes the previous file so consecutive files do not run together.
                    if let previous, lines.last?.text.isEmpty == false { lines.append(DiffDisplayLine(text: "", oldLine: nil, newLine: nil, hunk: nil, kind: .annotation, file: previous)) }
                    lines.append(DiffDisplayLine(text: "▸ " + path, oldLine: nil, newLine: nil, hunk: nil, kind: .metadata, file: current, fileHeader: true))
                }
                continue
            }
            if line.hasPrefix("@@ "), let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let left = Range(match.range(at: 1), in: line), let right = Range(match.range(at: 2), in: line) {
                old = Int(line[left]) ?? 0; new = Int(line[right]) ?? 0; hunk += 1; inHeader = false
                lines.append(DiffDisplayLine(text: line, oldLine: nil, newLine: nil, hunk: hunk, kind: .hunk)); continue
            }
            if line.hasPrefix("@@@ "), let match = combinedExpression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let right = Range(match.range(at: 1), in: line) {
                new = Int(line[right]) ?? 0; hunk += 1; inHeader = false; combined = true
                lines.append(DiffDisplayLine(text: line, oldLine: nil, newLine: nil, hunk: hunk, kind: .hunk)); continue
            }
            if !patch { lines.append(DiffDisplayLine(text: line, oldLine: nil, newLine: index + 1, hunk: nil, kind: .context)); continue }
            if inHeader {
                if let current {
                    if line.hasPrefix("new file") { files[current].kind = .added }
                    else if line.hasPrefix("deleted file") { files[current].kind = .deleted }
                    else if line.hasPrefix("rename from ") { files[current].kind = .renamed; files[current].originalPath = String(line.dropFirst(12)) }
                    else if line.hasPrefix("rename ") { files[current].kind = .renamed }
                    else if line.hasPrefix("Binary files") { files[current].binary = true }
                }
                if ["Binary files", "new file", "deleted file", "rename ", "similarity"].contains(where: line.hasPrefix) { lines.append(DiffDisplayLine(text: line, oldLine: nil, newLine: nil, hunk: nil, kind: .annotation)) }
                continue
            }
            if hunk < 0 { if preamble { lines.append(DiffDisplayLine(text: line, oldLine: nil, newLine: nil, hunk: nil, kind: .annotation)) }; continue }
            if line.hasPrefix("\\ ") { lines.append(DiffDisplayLine(text: line, oldLine: nil, newLine: nil, hunk: hunk, kind: .annotation)); continue }
            if combined {
                // Two marker columns (one per parent): added in the result if any is "+", removed if any is "-".
                let markers = line.prefix(2)
                if markers.contains("+") { lines.append(DiffDisplayLine(text: line, oldLine: nil, newLine: new, hunk: hunk, kind: .addition)); new += 1; if let current { files[current].additions += 1 } }
                else if markers.contains("-") { lines.append(DiffDisplayLine(text: line, oldLine: nil, newLine: nil, hunk: hunk, kind: .deletion)); if let current { files[current].deletions += 1 } }
                else if !line.isEmpty { lines.append(DiffDisplayLine(text: line, oldLine: nil, newLine: new, hunk: hunk, kind: .context)); new += 1 }
                continue
            }
            if line.hasPrefix("+") { lines.append(DiffDisplayLine(text: line, oldLine: nil, newLine: new, hunk: hunk, kind: .addition)); new += 1; if let current { files[current].additions += 1 } }
            else if line.hasPrefix("-") { lines.append(DiffDisplayLine(text: line, oldLine: old, newLine: nil, hunk: hunk, kind: .deletion)); old += 1; if let current { files[current].deletions += 1 } }
            else if line.hasPrefix(" ") { lines.append(DiffDisplayLine(text: line, oldLine: old, newLine: new, hunk: hunk, kind: .context)); old += 1; new += 1 }
            else { lines.append(DiffDisplayLine(text: line, oldLine: nil, newLine: nil, hunk: hunk, kind: .annotation)) }
        }
        if lines.isEmpty && !text.isEmpty { lines = [DiffDisplayLine(text: text, oldLine: nil, newLine: nil, hunk: nil, kind: .annotation)] }
    }
}

/// One block of a multi-file output: a note (commit header and message) or one file with its own patch.
struct DiffSection: Identifiable, Equatable {
    var id: Int
    var note: String? = nil
    var file: DiffFile? = nil
    /// The file's patch, starting at its `diff --git` line.
    var patch = ""
    /// Splits `git show` / `git diff` output at each file so every file can be shown, collapsed and scrolled to on
    /// its own. Returns nothing when the text is not a patch.
    static func split(_ text: String) -> [DiffSection] {
        let files = UnifiedDiff(text).files
        guard !files.isEmpty else { return [] }
        var sections: [DiffSection] = []; var buffer: [String] = []; var next = 0; var inFile = false
        func flush() {
            defer { buffer.removeAll(keepingCapacity: true) }
            if inFile, next < files.count {
                while buffer.last?.isEmpty == true { buffer.removeLast() }
                sections.append(DiffSection(id: sections.count, file: files[next], patch: buffer.joined(separator: "\n"))); next += 1
            } else if !inFile {
                let note = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty { sections.append(DiffSection(id: sections.count, note: note)) }
            }
        }
        // `components(separatedBy:)`, not `split`: "\r\n" is a single Character, so `split` kept a CRLF file and the
        // next file's `diff --git` line in one piece and every later card showed another file's patch.
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("\u{1}") { flush(); inFile = false; buffer.append(String(line.dropFirst())); continue }
            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") { flush(); inFile = true }
            buffer.append(line)
        }
        flush()
        return sections
    }
}
