import Foundation
struct GraphSegment { var from: Int; var to: Int; var startsAtNode: Bool }
struct GraphRow {
    var column: Int
    var incoming: [Int]
    var outgoing: [GraphSegment]
    var laneCount: Int
}
struct CommitGraph {
    var rows: [GraphRow] = []
    var width: Int = 1
    /// Branch each commit belongs to, following first parents down from decorated tips (topological order: children first).
    var branchLabels: [String: String] = [:]
    static func branchLabels(_ commits: [GitCommit], localBranches: Set<String>) -> [String: String] {
        var labels: [String: String] = [:]
        for commit in commits {
            if labels[commit.hash] == nil {
                let refs = CommitReference.parse(commit.refs, localBranches: localBranches)
                if let ref = refs.first(where: { $0.kind == .head }) ?? refs.first(where: { $0.kind == .branch }) ?? refs.first(where: { $0.kind == .remote }) { labels[commit.hash] = ref.name }
            }
            if let label = labels[commit.hash], let first = commit.parents.first, labels[first] == nil { labels[first] = label }
        }
        return labels
    }
    init(commits: [GitCommit], localBranches: Set<String> = []) {
        branchLabels = CommitGraph.branchLabels(commits, localBranches: localBranches)
        var active: [String] = []
        for commit in commits {
            let incoming = Array(active.indices)
            let column: Int
            if let index = active.firstIndex(of: commit.hash) { column = index }
            else { column = active.count; active.append(commit.hash) }
            let before = active
            active.remove(at: column)
            for (index, parent) in commit.parents.enumerated() where !active.contains(parent) {
                if index == 0 { active.insert(parent, at: min(column, active.count)) }
                else { active.append(parent) }
            }
            var outgoing: [GraphSegment] = []
            for (index, identity) in before.enumerated() where identity != commit.hash {
                if let destination = active.firstIndex(of: identity) { outgoing.append(GraphSegment(from: index, to: destination, startsAtNode: false)) }
            }
            for parent in commit.parents { if let destination = active.firstIndex(of: parent) { outgoing.append(GraphSegment(from: column, to: destination, startsAtNode: true)) } }
            let count = max(before.count, active.count, 1)
            width = max(width, count)
            rows.append(GraphRow(column: column, incoming: incoming, outgoing: outgoing, laneCount: count))
        }
    }
}
