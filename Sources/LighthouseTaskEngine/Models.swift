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

/// One (repo, branch) pair whose branch tip is not reachable from the repo's
/// base branch — work that would be destroyed by removing the task.
public struct UnmergedWorkItem: Sendable, Equatable, Hashable {
    public let repoId: UUID
    public let repoPath: String
    public let branch: String

    public init(repoId: UUID, repoPath: String, branch: String) {
        self.repoId = repoId
        self.repoPath = repoPath
        self.branch = branch
    }
}
