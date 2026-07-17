import Foundation
import LighthouseGit

/// A node in the changed-files tree. Files have nil children (OutlineGroup
/// convention); directories carry their sorted contents.
public struct FileTreeNode: Identifiable, Sendable, Equatable {
    /// Short change marker shown next to a file: A/M/D/T/R/C/U, "?" for
    /// untracked, "·" for anything unrecognized.
    public let status: String?
    /// Full repo-relative path (unique → the identity). Directory ids end
    /// in "/" so they never collide with a file of the same path.
    public let id: String
    public let name: String
    public var children: [FileTreeNode]?
    /// Number of changed FILES at or beneath this node (recursive). For a
    /// file it is 1; for a directory it is the count shown in the collapsed
    /// badge so a fold can never hide files invisibly.
    public let fileCount: Int

    public init(status: String?, id: String, name: String, children: [FileTreeNode]?, fileCount: Int) {
        self.status = status
        self.id = id
        self.name = name
        self.children = children
        self.fileCount = fileCount
    }

    public var isFile: Bool { children == nil }

    /// Every directory id in this subtree (for pruning session expansion state).
    public func directoryIDs() -> [String] {
        guard let children else { return [] }
        return [id] + children.flatMap { $0.directoryIDs() }
    }
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

    /// Builds a plain repo FILE tree from a flat list of relative paths (e.g.
    /// `GitClient.listFiles`). Unlike `build(entries:untracked:)` this is a
    /// browser, not a review surface: files carry no status glyph (`status`
    /// nil). Same folder grouping, sorting (dirs first, then files, each
    /// alphabetical), and recursive `fileCount` as the changed-files tree.
    public static func build(paths: [String]) -> [FileTreeNode] {
        var root = DirectoryAccumulator()
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            root.insert(components: components, fullPath: path, status: nil)
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
        var files: [(name: String, fullPath: String, status: String?)] = []

        mutating func insert(components: [String], fullPath: String, status: String?) {
            guard let head = components.first else { return }
            if components.count == 1 {
                files.append((head, fullPath, status))
            } else {
                directories[head, default: DirectoryAccumulator()]
                    .insert(components: Array(components.dropFirst()), fullPath: fullPath, status: status)
            }
        }

        func nodes(prefix: String) -> [FileTreeNode] {
            let directoryNodes = directories.keys.sorted().map { name -> FileTreeNode in
                let children = directories[name]!.nodes(prefix: prefix + name + "/")
                return FileTreeNode(
                    status: nil,
                    id: prefix + name + "/",
                    name: name,
                    children: children,
                    fileCount: children.reduce(0) { $0 + $1.fileCount })
            }
            let fileNodes = files.sorted { $0.name < $1.name }.map { file in
                FileTreeNode(
                    status: file.status, id: file.fullPath, name: file.name,
                    children: nil, fileCount: 1)
            }
            return directoryNodes + fileNodes
        }
    }
}
