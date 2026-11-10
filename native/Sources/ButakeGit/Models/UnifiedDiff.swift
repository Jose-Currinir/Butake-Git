import Foundation
struct DiffDisplayLine {
    enum Kind { case metadata, hunk, addition, deletion, context, annotation }
    var text: String
    var oldLine: Int?
    var newLine: Int?
    var hunk: Int?
    var kind: Kind
}
struct UnifiedDiff {
    var lines: [DiffDisplayLine] = []
    init(_ text: String) {
        let raw = text.components(separatedBy: "\n")
        let patch = text.hasPrefix("diff --git ") || raw.contains { $0.hasPrefix("@@ ") }
        var old = 0; var new = 0; var hunk = -1
        let expression = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)
        // `git show`/`log -p` output carries a preamble and several files; a plain single-file diff keeps its compact form.
        let preamble = patch && !text.hasPrefix("diff --git ")
        let fileHeaders = preamble || raw.filter { $0.hasPrefix("diff --git ") }.count > 1
        var inHeader = false
        for (index, line) in raw.enumerated() {
            // \u{1} marks a commit header (format "%x01…"): show it and return to preamble mode so the
            // next commit's message and --stat lines are not mistaken for diff content.
            if line.hasPrefix("\u{1}") {
                lines.append(DiffDisplayLine(text: String(line.dropFirst()), oldLine: nil, newLine: nil, hunk: nil, kind: .metadata))
                hunk = -1; inHeader = false; continue
            }
            if patch && line.hasPrefix("diff --git ") {
                inHeader = true
                if fileHeaders {
                    let path = line.range(of: " b/", options: .backwards).map { String(line[$0.upperBound...]) } ?? line
                    lines.append(DiffDisplayLine(text: "▸ " + path, oldLine: nil, newLine: nil, hunk: nil, kind: .metadata))
                }
                continue
            }
            if line.hasPrefix("@@ "), let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let left = Range(match.range(at: 1), in: line), let right = Range(match.range(at: 2), in: line) {
                old = Int(line[left]) ?? 0; new = Int(line[right]) ?? 0; hunk += 1; inHeader = false
                lines.append(DiffDisplayLine(text: line, oldLine: nil, newLine: nil, hunk: hunk, kind: .hunk)); continue
            }
            if !patch { lines.append(DiffDisplayLine(text: line, oldLine: nil, newLine: index + 1, hunk: nil, kind: .context)); continue }
            if inHeader {
                if ["Binary files", "new file", "deleted file", "rename ", "similarity"].contains(where: line.hasPrefix) { lines.append(DiffDisplayLine(text: line, oldLine: nil, newLine: nil, hunk: nil, kind: .annotation)) }
                continue
            }
            if hunk < 0 { if preamble { lines.append(DiffDisplayLine(text: line, oldLine: nil, newLine: nil, hunk: nil, kind: .annotation)) }; continue }
            if line.hasPrefix("\\ ") { lines.append(DiffDisplayLine(text: line, oldLine: nil, newLine: nil, hunk: hunk, kind: .annotation)); continue }
            if line.hasPrefix("+") { lines.append(DiffDisplayLine(text: line, oldLine: nil, newLine: new, hunk: hunk, kind: .addition)); new += 1 }
            else if line.hasPrefix("-") { lines.append(DiffDisplayLine(text: line, oldLine: old, newLine: nil, hunk: hunk, kind: .deletion)); old += 1 }
            else if line.hasPrefix(" ") { lines.append(DiffDisplayLine(text: line, oldLine: old, newLine: new, hunk: hunk, kind: .context)); old += 1; new += 1 }
            else { lines.append(DiffDisplayLine(text: line, oldLine: nil, newLine: nil, hunk: hunk, kind: .annotation)) }
        }
        if lines.isEmpty && !text.isEmpty { lines = [DiffDisplayLine(text: text, oldLine: nil, newLine: nil, hunk: nil, kind: .annotation)] }
    }
}
