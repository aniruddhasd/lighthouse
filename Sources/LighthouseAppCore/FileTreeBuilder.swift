import Foundation
import LighthouseGit

/// A node in the changed-files tree. Files have nil children (OutlineGroup
/// convention); directories carry their sorted contents.
public struct FileTreeNode: Identifiable, Sendable, Equatable {
    /// Short change marker shown next to a file: A/M/D/T/R/C/U, "?" for
    /// untracked, "·" for anything unrecognized.
    public let status: String?
    /// Full repo-relative path (unique → the identity).
    public let id: String
    public let name: String
    public var children: [FileTreeNode]?

    public var isFile: Bool { children == nil }
}

/// Builds the review pane's read-only tree from the live diff's file list.
/// Deliberately a CHANGED-FILES tree, not a repo browser: the spec's tree is
/// a review surface (§2.4) — what changed, grouped by directory.
public enum FileTreeBuilder {

    public static func build(entries: [DiffEntry], untracked: [String]) -> [FileTreeNode] {
        var files: [(path: String, status: String)] = entries.map { ($0.path, marker(for: $0.change)) }
        let tracked = Set(entries.map(\.path))
        for path in untracked where !tracked.contains(path) {
            files.append((path, "?"))
        }

        var root = DirectoryAccumulator()
        for (path, status) in files {
            root.insert(components: path.split(separator: "/").map(String.init),
                        fullPath: path, status: status)
        }
        return root.nodes(prefix: "")
    }

    static func marker(for change: DiffEntry.Change) -> String {
        switch change {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .typeChanged: return "T"
        case .unmerged: return "U"
        case .renamed: return "R"
        case .copied: return "C"
        case .other: return "·"
        }
    }

    private struct DirectoryAccumulator {
        var directories: [String: DirectoryAccumulator] = [:]
        var files: [(name: String, fullPath: String, status: String)] = []

        mutating func insert(components: [String], fullPath: String, status: String) {
            guard let head = components.first else { return }
            if components.count == 1 {
                files.append((head, fullPath, status))
            } else {
                directories[head, default: DirectoryAccumulator()]
                    .insert(components: Array(components.dropFirst()), fullPath: fullPath, status: status)
            }
        }

        func nodes(prefix: String) -> [FileTreeNode] {
            let directoryNodes = directories.keys.sorted().map { name in
                FileTreeNode(
                    status: nil,
                    id: prefix + name + "/",
                    name: name,
                    children: directories[name]!.nodes(prefix: prefix + name + "/"))
            }
            let fileNodes = files.sorted { $0.name < $1.name }.map { file in
                FileTreeNode(status: file.status, id: file.fullPath, name: file.name, children: nil)
            }
            return directoryNodes + fileNodes
        }
    }
}
