import SwiftUI

/// A commit or comparison as a page of cards, one per file: the header says what happened to the file and
/// stays pinned while its changes scroll; a click on it expands or collapses the file.
struct DiffSectionsView: View {
    let sections: [DiffSection]
    let collapsed: Set<Int>
    let toggle: (Int) -> Void
    /// Measured height of each expanded diff (reported by the AppKit view once laid out).
    @State private var heights: [Int: CGFloat] = [:]
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    if let file = section.file {
                        // A file that was only moved has nothing to show beyond its header.
                        let expandable = file.binary || section.patch.range(of: "\n@@", options: .literal) != nil
                        let open = expandable && !collapsed.contains(section.id)
                        Section {
                            if open {
                                DiffView(text: section.patch, path: file.path, embedded: true) { height in if heights[section.id] != height { heights[section.id] = height } }
                                    .frame(height: heights[section.id] ?? DiffSectionsView.estimate(section.patch))
                                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8))
                                    .overlay { UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8).strokeBorder(Color.primary.opacity(0.12)) }
                                    .padding(.bottom, 12)
                            }
                        } header: {
                            DiffFileHeader(file: file, open: open, expandable: expandable) { toggle(section.id) }.padding(.bottom, open ? 0 : 8)
                        }
                    } else if let note = section.note {
                        DiffNoteView(text: note).padding(.bottom, 14)
                    }
                }
            }.padding(.horizontal, 14).padding(.vertical, 12)
        }.background(Brand.background)
    }
    /// Height before the first layout: about one row per line (trailing header lines are not shown).
    static func estimate(_ patch: String) -> CGFloat {
        CGFloat(max(1, patch.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } - 2)) * TextScale.points(18.5) + 12
    }
}

/// Header of a file card: disclosure arrow, file icon, name and folder, what happened to it and its line counts.
private struct DiffFileHeader: View {
    let file: DiffFile; let open: Bool; var expandable = true; let action: () -> Void
    @State private var hovering = false
    private var shape: UnevenRoundedRectangle { UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: open ? 0 : 8, bottomTrailingRadius: open ? 0 : 8, topTrailingRadius: 8) }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "chevron.right").font(.ui(size: 10, weight: .bold)).foregroundStyle(.secondary).rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12).opacity(expandable ? 1 : 0)
                FileTypeIcon(path: file.path, size: 17)
                Text((file.path as NSString).lastPathComponent).font(.ui(size: 13, weight: .semibold)).lineLimit(1)
                if case let folder = (file.path as NSString).deletingLastPathComponent, !folder.isEmpty {
                    Text(folder).font(.ui(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                ChangeKindBadge(kind: file.kind)
                if let original = file.originalPath { Text("← \(original)").font(.ui(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer(minLength: 8)
                StatsBadge(stats: file.binary ? LineStats() : LineStats(additions: file.additions, deletions: file.deletions)).scaleEffect(1.2, anchor: .trailing)
            }
            .padding(.horizontal, 12).frame(height: 36).contentShape(Rectangle())
            // Opaque: the header stays pinned over the changes that scroll under it.
            .background { shape.fill(Brand.background).overlay(shape.fill(Color.primary.opacity(hovering ? 0.11 : 0.07))) }
            .overlay { shape.strokeBorder(Color.primary.opacity(0.12)) }
        }
        .buttonStyle(.plain).allowsHitTesting(expandable).onHover { hovering = expandable && $0 }.help(file.path)
        .accessibilityIdentifier("diff.file.\(file.path)").accessibilityLabel("\(file.path), \(file.kind.title)")
        .accessibilityValue(L(open ? "expanded" : "collapsed"))
    }
}

/// Commit header and message (or any text before the first file): subject, author line and body.
private struct DiffNoteView: View {
    let text: String
    var body: some View {
        let lines = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        VStack(alignment: .leading, spacing: 4) {
            Text(lines[0]).font(.ui(size: 14, weight: .semibold))
            if lines.count > 1, !lines[1].isEmpty { Text(lines[1]).font(.ui(size: 11.5)).foregroundStyle(.secondary) }
            if lines.count > 2, case let body = lines[2].trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                Text(body).font(.ui(size: 12)).foregroundStyle(.primary.opacity(0.85)).padding(.top, 4)
            }
        }
        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
    }
}
