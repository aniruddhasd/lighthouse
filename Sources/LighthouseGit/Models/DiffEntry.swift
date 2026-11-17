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
