import Foundation

/// One record from `git diff --name-status -z <base>...HEAD`.
public struct DiffEntry: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        case added
        case modified
        case deleted
        case typeChanged
        case unmerged
        case renamed(score: Int)
        case copied(score: Int)
        /// A status letter this model does not know; carried verbatim so
        /// nothing is silently dropped.
        case other(String)
    }

    public let change: Change
    public let path: String
    /// Source path for renames/copies.
    public let originalPath: String?

    public init(change: Change, path: String, originalPath: String? = nil) {
        self.change = change
        self.path = path
        self.originalPath = originalPath
    }
}

/// Result of `merge` / `merge --continue`. A conflict is an expected state,
/// not an error — it is reported here, never thrown.
public enum MergeOutcome: Sendable, Equatable {
    /// The merge completed (fast-forward or merge commit).
    case merged
    /// The merge stopped with conflicts; the repo has MERGE_HEAD and these
    /// paths have unmerged (`u`) status entries.
    case conflicted(paths: [String])
}
