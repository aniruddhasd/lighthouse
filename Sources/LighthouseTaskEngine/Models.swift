import Foundation

/// A registered local clone. `path` is the clone's own checkout — the place
/// merges eventually land (spec §2.5); worktrees for tasks are created
/// elsewhere. Persisted in the config store (a future-public schema).
public struct RepoConfig: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Absolute path of the registered clone's working tree.
    public var path: String
    public var baseBranch: String
    /// Optional user-authored executable, absolute or relative to `path`.
    /// Run once per workspace at creation, cwd = the new workspace.
    public var setupScript: String?
    /// Repo-relative paths copied from the clone into each new workspace
    /// (e.g. [".env"]). Contents are copied, never read into config or logs.
    public var envCopyList: [String]?

    public init(
        id: UUID = UUID(), path: String, baseBranch: String,
        setupScript: String? = nil, envCopyList: [String]? = nil
    ) {
        self.id = id
        self.path = path
        self.baseBranch = baseBranch
        self.setupScript = setupScript
        self.envCopyList = envCopyList
    }

    public var pathURL: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// Task attention state (spec §3 attention pipeline):
/// working / needs-input / done / dirty.
public enum TaskAttentionState: String, Codable, Sendable, Equatable, CaseIterable {
    case working
    case needsInput = "needs-input"
    case done
    case dirty
}

/// Per-workspace merge-back progress. Partially-merged tasks are a visible
/// state, not an error (spec §2.5) — hence a value per workspace, not per task.
public enum WorkspaceMergeState: String, Codable, Sendable, Equatable, CaseIterable {
    case unmerged
    case merged
    case conflicted
}

/// One repo's worktree within a task.
public struct Workspace: Codable, Sendable, Equatable {
    public let repoId: UUID
    public var worktreePath: String
    public var mergeState: WorkspaceMergeState

    public init(repoId: UUID, worktreePath: String, mergeState: WorkspaceMergeState) {
        self.repoId = repoId
        self.worktreePath = worktreePath
        self.mergeState = mergeState
    }

    public var worktreeURL: URL { URL(fileURLWithPath: worktreePath, isDirectory: true) }
}

/// The unit of intent: a name, a branch, one workspace per repo it touches.
/// Named TaskRecord (not Task) to avoid colliding with Swift Concurrency's
/// `Task`, which would poison every `Task {}` use in importing code.
/// `sessionRef`/`adapterKind` are recorded here but never acted on by the
/// task engine — session launch belongs to the agent adapter (build step 3).
public struct TaskRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var branch: String
    public var adapterKind: String
    public var sessionRef: String?
    public var state: TaskAttentionState
    public var workspaces: [Workspace]

    public init(
        id: UUID = UUID(), name: String, branch: String, adapterKind: String,
        sessionRef: String? = nil, state: TaskAttentionState, workspaces: [Workspace]
    ) {
        self.id = id
        self.name = name
        self.branch = branch
        self.adapterKind = adapterKind
        self.sessionRef = sessionRef
        self.state = state
        self.workspaces = workspaces
    }
}

/// A work-losing condition on one workspace — either kind is destroyed by
/// removing the task and so demands the same explicit, typed confirmation.
/// Both hazards can hold for the same (repo, branch): a branch with unmerged
/// commits AND uncommitted changes lists two hazards, and the repo is forced.
public enum RemovalHazard: Sendable, Equatable, Hashable {
    /// The branch tip is not reachable from the repo's base branch:
    /// committed work would be lost.
    case unmergedCommits(repoId: UUID, repoPath: String, branch: String)
    /// The worktree directory has uncommitted/untracked changes that
    /// `git worktree remove` refuses and only `--force` would discard.
    case dirtyWorktree(repoId: UUID, repoPath: String, branch: String)

    public var repoId: UUID {
        switch self {
        case .unmergedCommits(let id, _, _), .dirtyWorktree(let id, _, _): return id
        }
    }
    public var repoPath: String {
        switch self {
        case .unmergedCommits(_, let path, _), .dirtyWorktree(_, let path, _): return path
        }
    }
    public var branch: String {
        switch self {
        case .unmergedCommits(_, _, let branch), .dirtyWorktree(_, _, let branch): return branch
        }
    }
}
