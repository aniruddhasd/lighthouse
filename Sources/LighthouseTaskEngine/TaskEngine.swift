import Foundation
import LighthouseGit

/// How `removeTask` treats unmerged work. Destroying it requires a typed
/// confirmation carrying the exact (repo, branch) pairs being destroyed —
/// the call cannot be constructed without that list (guardrail 1, spec §7:
/// enforced at the API level, not hidden in UI).
public enum TaskRemovalMode: Sendable, Equatable {
    case refuseIfUnmerged
    case destroyUnmergedWork(UnmergedDestructionConfirmation)
}

/// The caller's record of an explicit user confirmation. `destroying` must
/// equal the engine's own freshly computed unmerged set at removal time;
/// any mismatch (stale confirmation) aborts before anything is touched.
public struct UnmergedDestructionConfirmation: Sendable, Equatable {
    public let destroying: [UnmergedWorkItem]

    public init(destroying: [UnmergedWorkItem]) {
        self.destroying = destroying
    }
}

/// Per-workspace account of what removal actually did. External deletions
/// are reconciled and reported, never crashed on and never hidden.
public struct WorkspaceRemovalOutcome: Sendable, Equatable {
    public enum WorktreeOutcome: Sendable, Equatable {
        case removed
        /// The directory was already gone; git's registration was cleaned up.
        case alreadyGone
    }
    public enum BranchOutcome: Sendable, Equatable {
        case deleted
        case alreadyGone
    }

    public let repoId: UUID
    public let repoPath: String
    public let branch: String
    public let worktree: WorktreeOutcome
    public let branchResult: BranchOutcome
}

public struct TaskRemovalReport: Sendable, Equatable {
    public let workspaces: [WorkspaceRemovalOutcome]
}

/// Task lifecycle: atomic creation with rollback, and guarded removal.
/// All git goes through GitClient; the only other subprocess is the repo's
/// own user-authored setup script. This engine never launches agent
/// sessions — it records `adapterKind`/`sessionRef` and nothing more.
public actor TaskEngine {
    private let git: GitClient

    public init(git: GitClient = GitClient()) {
        self.git = git
    }

    // MARK: - Creation (spec §2.2, guardrail 6)

    /// Creates one worktree + branch per repo, in order, from each repo's
    /// LOCAL base tip (fully offline — never fetches). Copies env files, runs
    /// the setup script. Any failure at repo N rolls back repos 1..N and
    /// throws `TaskCreationFailure`; rollback removes only what this attempt
    /// created — a pre-existing branch fails the attempt BEFORE that repo is
    /// mutated, so it can never be rolled back away.
    public func createTask(
        name: String,
        branch: String,
        adapterKind: String,
        repos: [RepoConfig],
        worktreesRoot: URL
    ) async throws -> TaskRecord {
        // ---- Pre-flight (no mutation anywhere) ----
        if let reason = Self.taskNameProblem(name) {
            throw TaskCreationFailure(
                repoPath: nil, cause: .invalidTaskName(name, reason: reason), rollback: .notNeeded)
        }
        guard try await liftGit({ try await self.git.isValidBranchName(branch) }) else {
            throw TaskCreationFailure(
                repoPath: nil, cause: .invalidBranchName(branch), rollback: .notNeeded)
        }

        let taskDirectory = worktreesRoot.appendingPathComponent(name, isDirectory: true)
        var destinations: [UUID: URL] = [:]
        var seen: Set<String> = []
        for repo in repos {
            let destination = taskDirectory.appendingPathComponent(
                repo.pathURL.lastPathComponent, isDirectory: true)
            guard seen.insert(destination.path).inserted else {
                throw TaskCreationFailure(
                    repoPath: repo.path,
                    cause: .duplicateWorktreeDestination(path: destination.path),
                    rollback: .notNeeded)
            }
            destinations[repo.id] = destination
        }

        // ---- Per-repo walk, in caller order ----
        // `created` is appended AT the mutation point (inside
        // createWorkspace, right after `worktree add`), so a repo whose
        // provisioning fails AFTER its worktree exists is still rolled back.
        var created: [CreatedArtifact] = []
        var workspaces: [Workspace] = []

        for repo in repos {
            do {
                let workspace = try await createWorkspace(
                    for: repo, branch: branch, at: destinations[repo.id]!,
                    recordingArtifactsIn: &created)
                workspaces.append(workspace)
            } catch {
                let cause = (error as? TaskEngineError)
                    ?? .git(.unexpectedOutput(description: String(describing: error), output: ""))
                let rollback = await rollBack(created, taskDirectory: taskDirectory)
                throw TaskCreationFailure(repoPath: repo.path, cause: cause, rollback: rollback)
            }
        }

        return TaskRecord(
            name: name, branch: branch, adapterKind: adapterKind,
            sessionRef: nil,
            // No agent session exists yet (step 3): nothing needs attention.
            state: .done,
            workspaces: workspaces)
    }

    /// One repo's share of creation. Every check that can fail runs BEFORE
    /// the single mutation point (`addWorktree`); the artifact is recorded
    /// the moment the mutation lands, so later failures (env copy, setup
    /// script) still roll this repo back.
    private func createWorkspace(
        for repo: RepoConfig, branch: String, at destination: URL,
        recordingArtifactsIn created: inout [CreatedArtifact]
    ) async throws -> Workspace {
        let repoURL = repo.pathURL

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repo.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              try await liftGit({ try await self.git.isInsideWorkTree(at: repoURL) })
        else {
            throw TaskEngineError.repoNotFound(path: repo.path)
        }

        // Fail fast BEFORE mutation: never risk rolling back a branch this
        // attempt did not create.
        if try await liftGit({ try await self.git.branchExists(branch, in: repoURL) }) {
            throw TaskEngineError.branchAlreadyExists(repoPath: repo.path, branch: branch)
        }

        let baseTip: String
        do {
            baseTip = try await git.revParse(repo.baseBranch, in: repoURL)
        } catch {
            throw TaskEngineError.baseBranchMissing(repoPath: repo.path, baseBranch: repo.baseBranch)
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            throw TaskEngineError.worktreeDestinationOccupied(path: destination.path)
        }

        // Validate env entries before mutating, too.
        let envEntries = repo.envCopyList ?? []
        for entry in envEntries {
            if let reason = Self.envEntryProblem(entry) {
                throw TaskEngineError.invalidEnvCopyEntry(entry: entry, reason: reason)
            }
            if !FileManager.default.fileExists(atPath: repoURL.appendingPathComponent(entry).path) {
                throw TaskEngineError.envCopySourceMissing(repoPath: repo.path, entry: entry)
            }
        }
        let script = try resolveSetupScript(for: repo)

        // ---- Mutation point ----
        try await liftGit {
            try await self.git.addWorktree(
                at: destination, newBranch: branch, from: baseTip, in: repoURL)
        }
        created.append(CreatedArtifact(
            repoPath: repo.path, branch: branch, worktreePath: destination.path))

        // Env copies: content moves file-to-file only; never read into
        // config or logs (guardrail 4).
        for entry in envEntries {
            let source = repoURL.appendingPathComponent(entry)
            let target = destination.appendingPathComponent(entry)
            do {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: target)
            } catch {
                throw TaskEngineError.invalidEnvCopyEntry(
                    entry: entry, reason: "copy failed: \(String(describing: error))")
            }
        }

        if let script {
            let result: ProcessResultSummary
            do {
                result = try await Self.runSetupScript(script, cwd: destination)
            } catch {
                throw TaskEngineError.setupScriptFailed(
                    repoPath: repo.path, script: script.path,
                    exitCode: -1, stderr: String(describing: error))
            }
            guard result.exitCode == 0 else {
                throw TaskEngineError.setupScriptFailed(
                    repoPath: repo.path, script: script.path,
                    exitCode: result.exitCode, stderr: result.stderr)
            }
        }

        return Workspace(repoId: repo.id, worktreePath: destination.path, mergeState: .unmerged)
    }

    /// Best-effort, loud: attempts every artifact in reverse order, records
    /// each failure as debris, never stops early and never swallows.
    private func rollBack(
        _ created: [CreatedArtifact], taskDirectory: URL
    ) async -> RollbackOutcome {
        if created.isEmpty { return .notNeeded }

        var removed: [CreatedArtifact] = []
        var debris: [DebrisItem] = []

        for artifact in created.reversed() {
            let repoURL = URL(fileURLWithPath: artifact.repoPath, isDirectory: true)
            var failures: [String] = []
            do {
                try await git.removeWorktree(
                    at: URL(fileURLWithPath: artifact.worktreePath, isDirectory: true),
                    in: repoURL,
                    mode: .forceDiscardingChanges(
                        justification: "rollback of failed task creation"))
            } catch {
                failures.append("worktree: \(String(describing: error))")
            }
            do {
                // Force: the branch was created by this very attempt and is
                // definitionally unmerged.
                try await git.deleteBranch(artifact.branch, force: true, in: repoURL)
            } catch {
                failures.append("branch: \(String(describing: error))")
            }
            if failures.isEmpty {
                removed.append(artifact)
            } else {
                debris.append(DebrisItem(
                    repoPath: artifact.repoPath, branch: artifact.branch,
                    worktreePath: artifact.worktreePath,
                    failure: failures.joined(separator: "; ")))
            }
        }

        // The task directory shell is empty once worktrees are gone; removing
        // it is cosmetic cleanup, not debris accounting.
        if debris.isEmpty,
           let contents = try? FileManager.default.contentsOfDirectory(atPath: taskDirectory.path),
           contents.isEmpty {
            try? FileManager.default.removeItem(at: taskDirectory)
        }

        return debris.isEmpty
            ? .completed(removed: removed)
            : .incomplete(removed: removed, debris: debris)
    }

    // MARK: - Unmerged-work detection (guardrail 1)

    /// (repo, branch) pairs whose branch tip is NOT reachable from the repo's
    /// base branch — verified live via `git merge-base --is-ancestor`.
    public func unmergedWork(
        in task: TaskRecord, repos: [RepoConfig]
    ) async throws -> [UnmergedWorkItem] {
        var items: [UnmergedWorkItem] = []
        for workspace in task.workspaces {
            guard let repo = repos.first(where: { $0.id == workspace.repoId }) else {
                throw TaskEngineError.unknownRepo(repoId: workspace.repoId)
            }
            let repoURL = repo.pathURL
            // Branch already gone (external cleanup): nothing left to destroy.
            guard try await liftGit({ try await self.git.branchExists(task.branch, in: repoURL) }) else {
                continue
            }
            let merged = try await liftGit {
                try await self.git.isAncestor(task.branch, of: repo.baseBranch, in: repoURL)
            }
            if !merged {
                items.append(UnmergedWorkItem(
                    repoId: repo.id, repoPath: repo.path, branch: task.branch))
            }
        }
        return items
    }

    // MARK: - Removal (guardrail 1)

    /// Removes every workspace's worktree and branch. If ANY workspace holds
    /// unmerged work, `.refuseIfUnmerged` throws with the exact list, and
    /// `.destroyUnmergedWork` must carry that same list — freshly recomputed
    /// here; a stale list aborts before anything is touched.
    public func removeTask(
        _ task: TaskRecord, repos: [RepoConfig], mode: TaskRemovalMode
    ) async throws -> TaskRemovalReport {
        let actual = try await unmergedWork(in: task, repos: repos)
        switch mode {
        case .refuseIfUnmerged:
            guard actual.isEmpty else {
                throw TaskEngineError.unmergedWorkPresent(items: actual)
            }
        case .destroyUnmergedWork(let confirmation):
            guard Set(confirmation.destroying) == Set(actual) else {
                throw TaskEngineError.staleConfirmation(
                    confirmed: confirmation.destroying, actual: actual)
            }
        }

        // Force applies ONLY to workspaces the confirmation actually lists.
        // A dirty worktree whose branch is merged was never in any list, so
        // it still refuses loudly — guardrail 1's "with that confirmation"
        // means confirmation for THAT repo, not any confirmation at all.
        let confirmedRepoIds: Set<UUID>
        if case .destroyUnmergedWork(let confirmation) = mode {
            confirmedRepoIds = Set(confirmation.destroying.map(\.repoId))
        } else {
            confirmedRepoIds = []
        }

        var outcomes: [WorkspaceRemovalOutcome] = []
        for workspace in task.workspaces {
            let repo = repos.first(where: { $0.id == workspace.repoId })!  // verified above
            let repoURL = repo.pathURL
            let worktreeURL = workspace.worktreeURL

            let directoryExisted = FileManager.default.fileExists(atPath: workspace.worktreePath)
            let worktreeOutcome: WorkspaceRemovalOutcome.WorktreeOutcome
            do {
                let removalMode: WorktreeRemovalMode = confirmedRepoIds.contains(repo.id)
                    ? .forceDiscardingChanges(
                        justification: "user confirmed destruction of unmerged work")
                    : .refuseIfDirty
                try await liftGit {
                    try await self.git.removeWorktree(at: worktreeURL, in: repoURL, mode: removalMode)
                }
                worktreeOutcome = directoryExisted ? .removed : .alreadyGone
            } catch let error as TaskEngineError {
                // "is not a working tree": registration is already gone too
                // (externally pruned). Reconcile and report; don't crash.
                if case .git(.commandFailed(let failure)) = error,
                   !directoryExisted, failure.stderr.contains("is not a working tree") {
                    worktreeOutcome = .alreadyGone
                } else {
                    throw error
                }
            }

            let branchOutcome: WorkspaceRemovalOutcome.BranchOutcome
            if try await liftGit({ try await self.git.branchExists(task.branch, in: repoURL) }) {
                // Merged-ness was verified above via --is-ancestor; `git
                // branch -d`'s own HEAD-relative heuristic would false-refuse
                // when the clone is checked out elsewhere, so force is correct
                // for both paths here.
                try await liftGit {
                    try await self.git.deleteBranch(task.branch, force: true, in: repoURL)
                }
                branchOutcome = .deleted
            } else {
                branchOutcome = .alreadyGone
            }

            outcomes.append(WorkspaceRemovalOutcome(
                repoId: repo.id, repoPath: repo.path, branch: task.branch,
                worktree: worktreeOutcome, branchResult: branchOutcome))
        }

        return TaskRemovalReport(workspaces: outcomes)
    }

    // MARK: - Helpers

    private static func taskNameProblem(_ name: String) -> String? {
        if name.isEmpty { return "empty" }
        if name == "." || name == ".." { return "reserved path component" }
        if name.contains("/") { return "contains '/'" }
        if name.contains("\0") { return "contains NUL" }
        return nil
    }

    private static func envEntryProblem(_ entry: String) -> String? {
        if entry.isEmpty { return "empty" }
        if entry.hasPrefix("/") { return "must be relative to the repo root" }
        if entry.split(separator: "/").contains("..") { return "must not escape the repo root" }
        return nil
    }

    /// Setup script path: absolute, or relative to the registered repo root.
    /// Returns nil when the repo has no script configured.
    private func resolveSetupScript(for repo: RepoConfig) throws -> URL? {
        guard let script = repo.setupScript else { return nil }
        let url = script.hasPrefix("/")
            ? URL(fileURLWithPath: script)
            : repo.pathURL.appendingPathComponent(script)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw TaskEngineError.setupScriptNotFound(repoPath: repo.path, script: script)
        }
        return url
    }

    private struct ProcessResultSummary {
        let exitCode: Int32
        let stderr: String
    }

    /// User-authored code, run deliberately at creation time only, cwd = the
    /// new workspace, argument-array execution (no shell) — spec §8.
    private static func runSetupScript(_ script: URL, cwd: URL) async throws -> ProcessResultSummary {
        let result = try await ProcessRunner.run(
            executable: script.path, arguments: [], workingDirectory: cwd)
        return ProcessResultSummary(exitCode: result.exitCode, stderr: result.stderrText)
    }

    /// Wraps GitClientError into the engine's error space at the boundary;
    /// TaskEngineError and anything else propagate unchanged.
    private func liftGit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as GitClientError {
            throw TaskEngineError.git(error)
        }
    }
}
