import Foundation
import LighthouseGit

/// Why the merge walk is paused and waiting for the user (spec §2.5, §5
/// guardrail 5: a conflict or precondition failure pauses VISIBLY — the walk
/// never auto-resolves, auto-commits, or reorders).
public enum MergeWalkPauseReason: Sendable, Equatable {
    /// The registered clone has uncommitted changes; merge must run in a
    /// clean checkout on the base branch (§2.5).
    case cloneDirty(repoPath: String)
    /// The clone is on `actual`, not the required base branch.
    case cloneNotOnBase(repoPath: String, base: String, actual: String)
    /// The clone's HEAD is detached; not on the base branch.
    case cloneDetached(repoPath: String, base: String)
    /// A merge is already in progress in the clone before the walk touched it.
    case cloneMidMerge(repoPath: String)
    /// The base branch does not exist in the clone.
    case baseMissing(repoPath: String, base: String)
    /// The merge produced conflicts; these paths are unmerged.
    case conflicted(repoPath: String, paths: [String])
    /// The user aborted this repo's merge; the walk stopped here.
    case abortedByUser(repoPath: String)
}

public enum MergeWalkState: Sendable, Equatable {
    case notStarted
    /// Every workspace merged into its base — the task is done (§2.5).
    case completed
    /// Stopped at `repoId`; `reason` says why. Partially-merged is a
    /// first-class visible state, not an error.
    case paused(repoId: UUID, reason: MergeWalkPauseReason)
}

/// Per-repo progress within the walk.
public struct RepoMergeProgress: Sendable, Equatable {
    public let repoId: UUID
    public let repoPath: String
    public let branch: String
    public var state: WorkspaceMergeState

    public init(repoId: UUID, repoPath: String, branch: String, state: WorkspaceMergeState) {
        self.repoId = repoId
        self.repoPath = repoPath
        self.branch = branch
        self.state = state
    }
}

/// Drives a task-level "merge to base" across the task's repos in a
/// user-chosen order. Each repo's merge runs in the REGISTERED CLONE's own
/// checkout on the base branch (spec §2.5) — never a temp worktree, whose
/// ref updates would desync the main checkout.
///
/// Guardrail 5 is enforced at the API level: the order is fixed at
/// construction (no setter), and there is no operation that resolves or
/// commits a conflict on the user's behalf — `completeCurrentRepo()` only
/// runs `merge --continue` over what the caller has ALREADY staged, and it
/// reports the outcome rather than looping.
public actor MergeWalk {
    private let git: GitClient
    private let taskBranch: String
    /// User-chosen order; index into it is the walk cursor.
    private var progress: [RepoMergeProgress]
    private let baseBranches: [UUID: String]
    private var cursor = 0
    public private(set) var state: MergeWalkState = .notStarted

    /// - Parameter orderedRepos: repos in the user-chosen walk order (default
    ///   creation order at the call site). Captured once — the walk cannot be
    ///   reordered after this.
    public init(taskBranch: String, orderedRepos: [RepoConfig], git: GitClient = GitClient()) {
        self.git = git
        self.taskBranch = taskBranch
        self.baseBranches = Dictionary(
            uniqueKeysWithValues: orderedRepos.map { ($0.id, $0.baseBranch) })
        self.progress = orderedRepos.map {
            RepoMergeProgress(
                repoId: $0.id, repoPath: $0.path, branch: taskBranch, state: .unmerged)
        }
    }

    public var repoProgress: [RepoMergeProgress] { progress }

    /// Conflicted paths at the current pause (empty otherwise).
    public func conflictedPaths() -> [String] {
        if case .paused(_, .conflicted(_, let paths)) = state { return paths }
        return []
    }

    /// The clone directory for the currently-paused repo (for the resolver).
    public func currentRepoPath() -> URL? {
        guard case .paused(let repoId, _) = state,
              let repo = progress.first(where: { $0.repoId == repoId }) else { return nil }
        return URL(fileURLWithPath: repo.repoPath, isDirectory: true)
    }

    // MARK: - Driving the walk

    /// Processes pending repos in order from the cursor: checks preconditions,
    /// merges, and stops at the first conflict/precondition pause or when all
    /// repos are merged. Idempotent to call again after a resolution.
    @discardableResult
    public func run() async throws -> MergeWalkState {
        while cursor < progress.count {
            if progress[cursor].state == .merged {
                cursor += 1
                continue
            }
            let repo = progress[cursor]
            let clone = URL(fileURLWithPath: repo.repoPath, isDirectory: true)
            let base = baseBranches[repo.repoId]!

            // Already paused on THIS repo's conflict (re-entrant run): don't
            // re-run preconditions/merge — a mid-merge MERGE_HEAD would else
            // read as a precondition failure. Re-report the conflict.
            if progress[cursor].state == .conflicted {
                let paths = try await git.status(in: clone).conflictedPaths
                return pause(.conflicted(repoPath: repo.repoPath, paths: paths))
            }

            // Precondition: base exists, clone on base, clean, no mid-merge.
            guard try await git.branchExists(base, in: clone) else {
                return pause(.baseMissing(repoPath: repo.repoPath, base: base))
            }
            if try await git.isMergeInProgress(in: clone) {
                return pause(.cloneMidMerge(repoPath: repo.repoPath))
            }
            let status = try await git.status(in: clone)
            switch status.head {
            case .branch(base):
                break
            case .branch(let actual):
                return pause(.cloneNotOnBase(repoPath: repo.repoPath, base: base, actual: actual))
            case .unborn(let actual):
                return pause(.cloneNotOnBase(repoPath: repo.repoPath, base: base, actual: actual))
            case .detached:
                return pause(.cloneDetached(repoPath: repo.repoPath, base: base))
            }
            guard status.isClean else {
                return pause(.cloneDirty(repoPath: repo.repoPath))
            }

            // Merge the task branch into the clone's base checkout.
            let outcome = try await git.merge(taskBranch, in: clone)
            switch outcome {
            case .merged:
                progress[cursor].state = .merged
                cursor += 1
            case .conflicted(let paths):
                progress[cursor].state = .conflicted
                return pause(.conflicted(repoPath: repo.repoPath, paths: paths))
            }
        }
        state = .completed
        return state
    }

    /// After the caller has resolved and STAGED every conflicted file, runs
    /// `git merge --continue`. On success the repo is merged and the walk
    /// resumes; if files remain unresolved the walk stays paused (never
    /// auto-resolves). The caller triggers this explicitly ("complete this
    /// repo's merge") — the engine never commits on its own.
    @discardableResult
    public func completeCurrentRepo() async throws -> MergeWalkState {
        guard case .paused(let repoId, .conflicted(let repoPath, _)) = state,
              let index = progress.firstIndex(where: { $0.repoId == repoId }) else {
            return state
        }
        let clone = URL(fileURLWithPath: repoPath, isDirectory: true)
        let outcome = try await git.continueMerge(in: clone)
        switch outcome {
        case .merged:
            progress[index].state = .merged
            cursor = index + 1
            return try await run()
        case .conflicted(let paths):
            // Still unresolved files — stay paused, refresh the list.
            return pause(.conflicted(repoPath: repoPath, paths: paths))
        }
    }

    /// `git merge --abort` on the paused repo, restoring its pre-merge state.
    /// The repo returns to unmerged and the walk stays paused there; a later
    /// `run()` retries it. The in-app exit from a trap (spec §2.5 addition).
    @discardableResult
    public func abortCurrentRepo() async throws -> MergeWalkState {
        guard case .paused(let repoId, .conflicted(let repoPath, _)) = state,
              let index = progress.firstIndex(where: { $0.repoId == repoId }) else {
            return state
        }
        try await git.abortMerge(in: URL(fileURLWithPath: repoPath, isDirectory: true))
        progress[index].state = .unmerged
        cursor = index
        return pause(.abortedByUser(repoPath: repoPath))
    }

    private func pause(_ reason: MergeWalkPauseReason) -> MergeWalkState {
        let repoId = progress[cursor].repoId
        state = .paused(repoId: repoId, reason: reason)
        return state
    }
}
