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

/// Per-workspace merge-back progress. Partially-merged tasks are a visible
/// state, not an error (spec §2.5) — hence a value per workspace, not per task.
public enum WorkspaceMergeState: String, Codable, Sendable, Equatable, CaseIterable {
    case unmerged
    case merged
    case conflicted
}

/// One repo's worktree within a task — or, in in-place mode, the registered
/// repo's OWN checkout (`isInPlace`), which Lighthouse must never destroy.
public struct Workspace: Codable, Sendable, Equatable {
    public let repoId: UUID
    public var worktreePath: String
    public var mergeState: WorkspaceMergeState
    /// True when this workspace IS the registered repo's own checkout
    /// (`worktreePath == repo.path`) rather than a Lighthouse-created worktree —
    /// investigation mode. When true, removal never deletes the directory or a
    /// branch, and there is no merge-back. Absent in pre-2026-07-21 configs, so
    /// it decodes to `false` (the historical all-worktree behaviour); the key is
    /// nested inside TaskRecord and both-way tolerant (older builds ignore it on
    /// read), so it needs no top-level config schema bump.
    public var isInPlace: Bool
    /// The base branch this task's "vs base" diff compares against — a branch
    /// name. nil means "use the repo's registered `baseBranch`" (the branch the
    /// worktree was created from). Changeable per task (from the Summary tab) so
    /// a task can diff against any branch. Absent in older configs → decodes nil.
    public var baseOverride: String?

    public init(
        repoId: UUID, worktreePath: String, mergeState: WorkspaceMergeState,
        isInPlace: Bool = false, baseOverride: String? = nil
    ) {
        self.repoId = repoId
        self.worktreePath = worktreePath
        self.mergeState = mergeState
        self.isInPlace = isInPlace
        self.baseOverride = baseOverride
    }

    public var worktreeURL: URL { URL(fileURLWithPath: worktreePath, isDirectory: true) }

    /// Custom decode so a legacy workspace (no `isInPlace`/`baseOverride` keys)
    /// loads as a worktree with the repo-default base — the only safe defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repoId = try c.decode(UUID.self, forKey: .repoId)
        worktreePath = try c.decode(String.self, forKey: .worktreePath)
        mergeState = try c.decode(WorkspaceMergeState.self, forKey: .mergeState)
        isInPlace = try c.decodeIfPresent(Bool.self, forKey: .isInPlace) ?? false
        baseOverride = try c.decodeIfPresent(String.self, forKey: .baseOverride)
    }
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
    /// Free-text status the user sets by hand (e.g. "waiting on review"). Empty
    /// means unset. Replaces the old automatic attention state — Lighthouse no
    /// longer infers a task's status from agent hooks; whether a SESSION is live
    /// is tracked separately and honestly (AppModel.liveSessions).
    public var status: String
    /// User-hidden: dropped from the Harbor grid and the ⌘K switcher until
    /// revealed. Purely a view preference — the task, its worktrees and session
    /// are untouched. Absent in older configs → decodes to false.
    public var hidden: Bool
    public var workspaces: [Workspace]

    public init(
        id: UUID = UUID(), name: String, branch: String, adapterKind: String,
        sessionRef: String? = nil, status: String = "", hidden: Bool = false,
        workspaces: [Workspace]
    ) {
        self.id = id
        self.name = name
        self.branch = branch
        self.adapterKind = adapterKind
        self.sessionRef = sessionRef
        self.status = status
        self.hidden = hidden
        self.workspaces = workspaces
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, branch, adapterKind, sessionRef, status, hidden, workspaces
    }

    /// Custom decode so configs written before free-text status (which carried a
    /// `state` enum instead) still load: the legacy `state` key is ignored and
    /// `status`/`hidden` default. Encode is synthesized.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        branch = try c.decode(String.self, forKey: .branch)
        adapterKind = try c.decode(String.self, forKey: .adapterKind)
        sessionRef = try c.decodeIfPresent(String.self, forKey: .sessionRef)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        workspaces = try c.decode([Workspace].self, forKey: .workspaces)
    }

    /// True when EVERY workspace runs in-place (investigation mode) — the UI
    /// keys its merge/branch affordances off this. A task is created either
    /// all-in-place or all-worktree, but a later "add repo to task" can mix
    /// tracked (in-place/adopted) workspaces into a worktree task; that is safe
    /// because merge-back and removal both test `isInPlace` PER WORKSPACE, so a
    /// mixed task merges/removes its worktree workspaces and leaves the tracked
    /// ones untouched. An empty task is not in-place.
    public var isInPlace: Bool {
        !workspaces.isEmpty && workspaces.allSatisfy(\.isInPlace)
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
