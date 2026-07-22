import Foundation
import LighthouseGit

/// Typed failures from the task engine. Git-level causes are carried intact
/// as `.git`, never flattened to strings.
public enum TaskEngineError: Error, Sendable {
    case invalidTaskName(String, reason: String)
    case invalidBranchName(String)
    /// The configured repo path does not exist or is not a git work tree.
    case repoNotFound(path: String)
    /// Creation was requested with no repositories selected — a task must own
    /// at least one workspace.
    case noReposSelected
    /// A loaded/degenerate task record carries zero workspaces, so no session
    /// (primary worktree) can be derived for it. Guards the `[0]` index at the
    /// model API boundary against a hand-edited or corrupted config.
    case taskHasNoWorkspaces(taskId: UUID)
    /// A workspace references a repo id absent from the provided configs.
    case unknownRepo(repoId: UUID)
    /// An operation named a task id that is not in the task list.
    case unknownTask(taskId: UUID)
    case baseBranchMissing(repoPath: String, baseBranch: String)
    /// The task branch already exists in this repo. Detected BEFORE any
    /// mutation of that repo, so rollback never touches it (guardrail 6).
    case branchAlreadyExists(repoPath: String, branch: String)
    /// A repo already has a workspace in this task — one workspace per repo per
    /// task, so it can't be added a second time.
    case repoAlreadyInTask(repoId: UUID)
    /// Adopt-a-worktree: the chosen directory is not a git work tree at all.
    case notAGitWorktree(path: String)
    /// Adopt-a-worktree: the directory is a work tree, but not one belonging to
    /// any registered repo (register its repo first, then adopt).
    case notAWorktreeOfRegisteredRepo(path: String)
    case worktreeDestinationOccupied(path: String)
    /// The destination's nearest existing ancestor is not writable —
    /// detected pre-mutation so creation fails before touching anything.
    case worktreeDestinationNotWritable(path: String, unwritableAncestor: String)
    case duplicateWorktreeDestination(path: String)
    /// envCopyList entries must be relative and stay inside the repo.
    case invalidEnvCopyEntry(entry: String, reason: String)
    case envCopySourceMissing(repoPath: String, entry: String)
    case setupScriptNotFound(repoPath: String, script: String)
    case setupScriptFailed(repoPath: String, script: String, exitCode: Int32, stderr: String)
    /// Removal refused: these workspaces hold work-losing hazards (unmerged
    /// commits and/or dirty worktrees) with no matching confirmation.
    case removalHazardsPresent(hazards: [RemovalHazard])
    /// The confirmation's list no longer matches reality — re-confirm.
    case staleConfirmation(confirmed: [RemovalHazard], actual: [RemovalHazard])
    case git(GitClientError)
}

/// One worktree+branch the engine created during a creation attempt.
public struct CreatedArtifact: Sendable, Equatable {
    public let repoPath: String
    public let branch: String
    public let worktreePath: String

    public init(repoPath: String, branch: String, worktreePath: String) {
        self.repoPath = repoPath
        self.branch = branch
        self.worktreePath = worktreePath
    }
}

/// Something rollback tried to remove but could not. Loud by design.
public struct DebrisItem: Sendable, Equatable {
    public let repoPath: String
    public let branch: String
    public let worktreePath: String
    /// What failed while removing it (human-readable, for the error surface).
    public let failure: String

    public init(repoPath: String, branch: String, worktreePath: String, failure: String) {
        self.repoPath = repoPath
        self.branch = branch
        self.worktreePath = worktreePath
        self.failure = failure
    }
}

public enum RollbackOutcome: Sendable, Equatable {
    /// Failure happened before any repo was mutated.
    case notNeeded
    /// Everything the attempt created was removed — zero debris.
    case completed(removed: [CreatedArtifact])
    /// Rollback itself failed partway; `debris` lists exactly what remains.
    case incomplete(removed: [CreatedArtifact], debris: [DebrisItem])
}

/// Thrown by `createTask`. Carries the underlying cause AND an honest account
/// of the rollback (guardrail 6: rollback over debris — and if rollback
/// itself fails, that is reported, never swallowed).
public struct TaskCreationFailure: Error, Sendable {
    /// Repo being processed when creation failed; nil for pre-flight failures
    /// that are not tied to one repo.
    public let repoPath: String?
    public let cause: TaskEngineError
    public let rollback: RollbackOutcome

    public init(repoPath: String?, cause: TaskEngineError, rollback: RollbackOutcome) {
        self.repoPath = repoPath
        self.cause = cause
        self.rollback = rollback
    }
}
