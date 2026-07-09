import Foundation
import LighthouseGit

/// Typed failures from the task engine. Git-level causes are carried intact
/// as `.git`, never flattened to strings.
public enum TaskEngineError: Error, Sendable {
    case invalidTaskName(String, reason: String)
    case invalidBranchName(String)
    /// The configured repo path does not exist or is not a git work tree.
    case repoNotFound(path: String)
    /// A workspace references a repo id absent from the provided configs.
    case unknownRepo(repoId: UUID)
    case baseBranchMissing(repoPath: String, baseBranch: String)
    /// The task branch already exists in this repo. Detected BEFORE any
    /// mutation of that repo, so rollback never touches it (guardrail 6).
    case branchAlreadyExists(repoPath: String, branch: String)
    case worktreeDestinationOccupied(path: String)
    case duplicateWorktreeDestination(path: String)
    /// envCopyList entries must be relative and stay inside the repo.
    case invalidEnvCopyEntry(entry: String, reason: String)
    case envCopySourceMissing(repoPath: String, entry: String)
    case setupScriptNotFound(repoPath: String, script: String)
    case setupScriptFailed(repoPath: String, script: String, exitCode: Int32, stderr: String)
    /// Removal refused: these branches hold work not reachable from base.
    case unmergedWorkPresent(items: [UnmergedWorkItem])
    /// The confirmation's list no longer matches reality — re-confirm.
    case staleConfirmation(confirmed: [UnmergedWorkItem], actual: [UnmergedWorkItem])
    case git(GitClientError)
}

/// One worktree+branch the engine created during a creation attempt.
public struct CreatedArtifact: Sendable, Equatable {
    public let repoPath: String
    public let branch: String
    public let worktreePath: String
}

/// Something rollback tried to remove but could not. Loud by design.
public struct DebrisItem: Sendable, Equatable {
    public let repoPath: String
    public let branch: String
    public let worktreePath: String
    /// What failed while removing it (human-readable, for the error surface).
    public let failure: String
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
}
