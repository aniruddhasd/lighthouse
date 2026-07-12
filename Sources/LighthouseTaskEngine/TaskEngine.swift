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

    /// Directory that groups a repo's task worktrees when no override is set.
    public static let worktreesDirectoryName = "lighthouse-worktrees"

    /// Where a task's worktree for `repo` goes. Default derives from the
    /// repo's OWN parent — `<repo parent>/lighthouse-worktrees/<task>/<repo>`
    /// — so sessions stay inside the directory tree that cwd-keyed tooling
    /// (per-folder account selectors, direnv) watches; repos living in
    /// different parents get worktrees near their respective repos. A global
    /// override replaces the `<repo parent>/lighthouse-worktrees` part.
    public static func worktreeDestination(
        for repo: RepoConfig, taskName: String, worktreesRootOverride: URL?
    ) -> URL {
        let base = worktreesRootOverride
            ?? repo.pathURL.deletingLastPathComponent()
                .appendingPathComponent(worktreesDirectoryName, isDirectory: true)
        return base
            .appendingPathComponent(taskName, isDirectory: true)
            .appendingPathComponent(repo.pathURL.lastPathComponent, isDirectory: true)
    }

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
        worktreesRootOverride: URL? = nil
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

        var destinations: [UUID: URL] = [:]
        var seen: Set<String> = []
        for repo in repos {
            let destination = Self.worktreeDestination(
                for: repo, taskName: name, worktreesRootOverride: worktreesRootOverride)
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
        // `createdParents` records the destination's parent dirs that did NOT
        // exist before the mutation — the only dirs rollback may delete.
        var created: [CreatedArtifact] = []
        var createdParents: [URL] = []
        var workspaces: [Workspace] = []

        for repo in repos {
            do {
                let workspace = try await createWorkspace(
                    for: repo, branch: branch, at: destinations[repo.id]!,
                    recordingArtifactsIn: &created,
                    recordingCreatedParentsIn: &createdParents)
                workspaces.append(workspace)
            } catch {
                let cause = (error as? TaskEngineError)
                    ?? .git(.unexpectedOutput(description: String(describing: error), output: ""))
                let rollback = await rollBack(created, createdParents: createdParents)
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
        recordingArtifactsIn created: inout [CreatedArtifact],
        recordingCreatedParentsIn createdParents: inout [URL]
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
        // The nearest EXISTING ancestor must be writable, or `worktree add`
        // would fail mid-mutation; fail loud before touching anything.
        let existingAncestor = Self.nearestExistingAncestor(of: destination)
        guard FileManager.default.isWritableFile(atPath: existingAncestor.path) else {
            throw TaskEngineError.worktreeDestinationNotWritable(
                path: destination.path, unwritableAncestor: existingAncestor.path)
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

        // Record which parent dirs `worktree add` is about to create (it
        // mkdir -p's the destination) — deepest first, so rollback can
        // delete in reverse creation order. Only dirs that do NOT yet exist
        // are recorded: rollback never touches a dir this attempt didn't make.
        var missingParents: [URL] = []
        var probe = destination.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: probe.path) {
            missingParents.append(probe)
            probe = probe.deletingLastPathComponent()
        }

        // ---- Mutation point ----
        try await liftGit {
            try await self.git.addWorktree(
                at: destination, newBranch: branch, from: baseTip, in: repoURL)
        }
        created.append(CreatedArtifact(
            repoPath: repo.path, branch: branch, worktreePath: destination.path))
        createdParents.append(contentsOf: missingParents)

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

    /// The nearest ancestor of `url` that exists on disk right now.
    static func nearestExistingAncestor(of url: URL) -> URL {
        var probe = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe = probe.deletingLastPathComponent()
        }
        return probe
    }

    /// Removes a directory only if it is empty. Non-empty or missing dirs
    /// are left exactly as they are.
    private static func removeIfEmpty(_ url: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path),
              contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Best-effort, loud: attempts every artifact in reverse order, records
    /// each failure as debris, never stops early and never swallows.
    /// `createdParents` are the destination parent dirs this attempt created
    /// (deepest first per repo) — removed afterwards only if empty; a dir
    /// that pre-existed the attempt is never in the list.
    private func rollBack(
        _ created: [CreatedArtifact], createdParents: [URL]
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

        // Directory-husk cleanup, cosmetic (not debris accounting): the
        // parent dirs this attempt created are now empty shells — remove
        // them deepest-first, and only while actually empty (a dir holding
        // rollback debris or anything else stays).
        for parent in createdParents {
            Self.removeIfEmpty(parent)
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

            // Husk cleanup: the worktree's parent is this task's grouping
            // dir — remove it once empty; then its parent too, but ONLY when
            // it is our own `lighthouse-worktrees` grouping dir (an override
            // root is user-chosen and never removed). Non-empty dirs always
            // stay — other tasks' worktrees live there.
            let taskDir = workspace.worktreeURL.deletingLastPathComponent()
            Self.removeIfEmpty(taskDir)
            let groupingDir = taskDir.deletingLastPathComponent()
            if groupingDir.lastPathComponent == Self.worktreesDirectoryName {
                Self.removeIfEmpty(groupingDir)
            }
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
