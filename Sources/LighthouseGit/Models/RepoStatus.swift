import Foundation

/// One side (index or working tree) of a status XY pair, as defined by the
/// `git status` short-format table (verified against git 2.50.1 docs).
public enum FileState: Character, Sendable, Equatable {
    case unmodified = "."
    case modified = "M"
    case typeChanged = "T"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case unmerged = "U"
}

/// Conflict classification from the XY pair of an unmerged (`u`) entry.
/// The seven combinations come from the short-format table in git-status(1).
public enum ConflictKind: String, Sendable, Equatable, CaseIterable {
    case bothDeleted = "DD"
    case addedByUs = "AU"
    case deletedByThem = "UD"
    case addedByThem = "UA"
    case deletedByUs = "DU"
    case bothAdded = "AA"
    case bothModified = "UU"

    /// True for the two delete/modify shapes (one side deleted, other modified).
    public var isDeleteModify: Bool {
        self == .deletedByUs || self == .deletedByThem
    }
}

/// A `1` line: an ordinary changed tracked entry.
public struct ChangedEntry: Sendable, Equatable {
    public let indexState: FileState
    public let worktreeState: FileState
    public let path: String

    public init(indexState: FileState, worktreeState: FileState, path: String) {
        self.indexState = indexState
        self.worktreeState = worktreeState
        self.path = path
    }
}

/// A `2` line: a renamed or copied entry.
public struct RenamedEntry: Sendable, Equatable {
    public let indexState: FileState
    public let worktreeState: FileState
    /// e.g. "R100" or "C75" — rename/copy plus similarity score.
    public let score: String
    /// Target path (where the content is now).
    public let path: String
    /// Source path (where the content came from).
    public let originalPath: String

    public init(indexState: FileState, worktreeState: FileState, score: String, path: String, originalPath: String) {
        self.indexState = indexState
        self.worktreeState = worktreeState
        self.score = score
        self.path = path
        self.originalPath = originalPath
    }
}

/// A `u` line: an unmerged (conflicted) entry. This is Lighthouse's conflict
/// detector — conflicts are recognized from status, never by reading file
/// content, so binary and delete/modify conflicts are handled uniformly.
public struct UnmergedEntry: Sendable, Equatable {
    public let kind: ConflictKind
    public let path: String
    /// Octal file modes for merge stages 1 (base), 2 (ours), 3 (theirs), and the worktree.
    public let stage1Mode: String
    public let stage2Mode: String
    public let stage3Mode: String
    public let worktreeMode: String
    /// Object names for merge stages 1 (base), 2 (ours), 3 (theirs).
    public let stage1Object: String
    public let stage2Object: String
    public let stage3Object: String

    public init(
        kind: ConflictKind, path: String,
        stage1Mode: String, stage2Mode: String, stage3Mode: String, worktreeMode: String,
        stage1Object: String, stage2Object: String, stage3Object: String
    ) {
        self.kind = kind
        self.path = path
        self.stage1Mode = stage1Mode
        self.stage2Mode = stage2Mode
        self.stage3Mode = stage3Mode
        self.worktreeMode = worktreeMode
        self.stage1Object = stage1Object
        self.stage2Object = stage2Object
        self.stage3Object = stage3Object
    }
}

/// Ahead/behind counts from the `# branch.ab` header (upstream must be set).
public struct AheadBehind: Sendable, Equatable {
    public let ahead: Int
    public let behind: Int

    public init(ahead: Int, behind: Int) {
        self.ahead = ahead
        self.behind = behind
    }
}

/// Typed model of `git status --porcelain=v2 --branch -z`.
public struct RepoStatus: Sendable, Equatable {
    public enum Head: Sendable, Equatable {
        case branch(String)
        case detached
        /// Branch exists but has no commits yet (`# branch.oid (initial)`).
        case unborn(String)
    }

    public let head: Head
    /// Full object name of the current commit; nil on an unborn branch.
    public let headObject: String?
    /// From `# branch.upstream`, if an upstream is configured.
    public let upstream: String?
    /// From `# branch.ab`, if an upstream is configured and present.
    public let aheadBehind: AheadBehind?

    public let changed: [ChangedEntry]
    public let renamed: [RenamedEntry]
    public let unmerged: [UnmergedEntry]
    public let untracked: [String]
    public let ignored: [String]

    public init(
        head: Head, headObject: String?, upstream: String?, aheadBehind: AheadBehind?,
        changed: [ChangedEntry], renamed: [RenamedEntry], unmerged: [UnmergedEntry],
        untracked: [String], ignored: [String]
    ) {
        self.head = head
        self.headObject = headObject
        self.upstream = upstream
        self.aheadBehind = aheadBehind
        self.changed = changed
        self.renamed = renamed
        self.unmerged = unmerged
        self.untracked = untracked
        self.ignored = ignored
    }

    /// No tracked changes, no conflicts, nothing untracked.
    public var isClean: Bool {
        changed.isEmpty && renamed.isEmpty && unmerged.isEmpty && untracked.isEmpty
    }

    public var hasConflicts: Bool { !unmerged.isEmpty }

    /// Tracked entries with a staged (index-side) change.
    public var stagedPaths: [String] {
        changed.filter { $0.indexState != .unmodified }.map(\.path)
            + renamed.filter { $0.indexState != .unmodified }.map(\.path)
    }

    /// Tracked entries with an unstaged (worktree-side) change.
    public var unstagedPaths: [String] {
        changed.filter { $0.worktreeState != .unmodified }.map(\.path)
            + renamed.filter { $0.worktreeState != .unmodified }.map(\.path)
    }

    public var conflictedPaths: [String] { unmerged.map(\.path) }
}
