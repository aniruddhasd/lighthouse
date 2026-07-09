import Foundation

/// One record from `git worktree list --porcelain -z`.
public struct Worktree: Sendable, Equatable {
    /// Absolute path of the worktree.
    public let path: String
    /// Object name of HEAD; nil for a bare worktree record.
    public let headObject: String?
    /// Full ref (e.g. "refs/heads/main"); nil when detached or bare.
    public let branch: String?
    public let isBare: Bool
    public let isDetached: Bool
    public let isLocked: Bool
    /// Present only when locked with a recorded reason.
    public let lockReason: String?
    public let isPrunable: Bool
    public let prunableReason: String?

    public init(
        path: String, headObject: String? = nil, branch: String? = nil,
        isBare: Bool = false, isDetached: Bool = false,
        isLocked: Bool = false, lockReason: String? = nil,
        isPrunable: Bool = false, prunableReason: String? = nil
    ) {
        self.path = path
        self.headObject = headObject
        self.branch = branch
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.isPrunable = isPrunable
        self.prunableReason = prunableReason
    }

    /// Branch short name ("main" for "refs/heads/main"), if on a branch.
    public var branchShortName: String? {
        guard let branch else { return nil }
        let prefix = "refs/heads/"
        return branch.hasPrefix(prefix) ? String(branch.dropFirst(prefix.count)) : branch
    }
}
