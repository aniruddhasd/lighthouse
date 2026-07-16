import Foundation
import Testing
import LighthouseFixtures
import LighthouseGit
@testable import LighthouseTaskEngine

/// Guardrail 1 (spec §7): destroying work-losing hazards — unmerged commits
/// AND/OR dirty worktrees — without a typed confirmation carrying the exact
/// hazard set is impossible at the API level. Broken cases first.
@Suite("TaskEngine.removeTask (fixture repos)")
final class TaskRemovalTests {
    private let fixtures: FixtureFactory
    private let worktreesRoot: URL
    private let git = GitClient()
    private let engine: TaskEngine

    init() throws {
        fixtures = try FixtureFactory()
        worktreesRoot = fixtures.root.appendingPathComponent("worktrees", isDirectory: true)
        engine = TaskEngine(git: git)
    }

    deinit {
        try? fixtures.destroy()
    }

    private func repoConfig(_ repo: FixtureRepo) -> RepoConfig {
        RepoConfig(path: repo.path.path, baseBranch: repo.defaultBranch)
    }

    private func makeTask(
        name: String, repos: [RepoConfig]
    ) async throws -> TaskRecord {
        try await engine.createTask(
            name: name, branch: "task/\(name)", adapterKind: "claude-code",
            repos: repos, worktreesRootOverride: worktreesRoot)
    }

    /// Commits a file in the workspace — the branch tip moves past base:
    /// real unmerged (committed) work.
    private func commitWork(in workspace: Workspace, file: String = "work.txt") throws {
        let dir = workspace.worktreeURL
        try Data("agent output\n".utf8).write(to: dir.appendingPathComponent(file))
        try fixtures.git(["add", file], in: dir)
        try fixtures.git(["commit", "-m", "agent work"], in: dir)
    }

    /// Leaves the workspace's working tree dirty WITHOUT committing (branch
    /// stays merged): a modified tracked file plus an untracked file — exactly
    /// what `git worktree remove` refuses.
    private func dirtyWork(in workspace: Workspace) throws {
        let dir = workspace.worktreeURL
        // `notes.txt` is committed by cleanRepo — modify it (tracked change).
        try Data("local edit\n".utf8).write(
            to: dir.appendingPathComponent("notes.txt"))
        // And an untracked file git has never seen.
        try Data("scratch\n".utf8).write(
            to: dir.appendingPathComponent("loose.txt"))
    }

    // MARK: Broken cases first — refusal

    @Test func unmergedWorkRefusedWithExactList() async throws {
        let r1 = try fixtures.cleanRepo()
        let r2 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1), repoConfig(r2)]
        let task = try await makeTask(name: "refuse", repos: configs)
        // Unmerged work in repo 2 only.
        try commitWork(in: task.workspaces[1])

        await #expect {
            _ = try await self.engine.removeTask(task, repos: configs, mode: .refuseIfHazards)
        } throws: { error in
            guard case .removalHazardsPresent(let hazards) = error as? TaskEngineError else {
                return false
            }
            return hazards == [.unmergedCommits(
                repoId: configs[1].id, repoPath: r2.path.path, branch: "task/refuse")]
        }

        // Nothing was touched.
        #expect(try await git.listWorktrees(in: r1.path).count == 2)
        #expect(try await git.listWorktrees(in: r2.path).count == 2)
        #expect(try await git.branchExists("task/refuse", in: r2.path))
    }

    @Test func dirtyButMergedWorktreeRefusesWithoutConfirmation() async throws {
        let r1 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1)]
        let task = try await makeTask(name: "dirty-refuse", repos: configs)
        // No commits (branch tip == base tip → merged), but the working tree
        // is dirty: ancestry can't see it, the status check must.
        try dirtyWork(in: task.workspaces[0])

        await #expect {
            _ = try await self.engine.removeTask(task, repos: configs, mode: .refuseIfHazards)
        } throws: { error in
            guard case .removalHazardsPresent(let hazards) = error as? TaskEngineError else {
                return false
            }
            return hazards == [.dirtyWorktree(
                repoId: configs[0].id, repoPath: r1.path.path, branch: "task/dirty-refuse")]
        }

        // The worktree and its uncommitted files survived untouched.
        #expect(try await git.listWorktrees(in: r1.path).count == 2)
        #expect(try await git.branchExists("task/dirty-refuse", in: r1.path))
        #expect(FileManager.default.fileExists(
            atPath: task.workspaces[0].worktreeURL.appendingPathComponent("loose.txt").path))
    }

    @Test func staleConfirmationAbortsBeforeTouchingAnything() async throws {
        let r1 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1)]
        let task = try await makeTask(name: "stale", repos: configs)
        try commitWork(in: task.workspaces[0])

        // A confirmation for the WRONG thing (e.g. computed before more work
        // landed, or hand-built): the exact-set check must reject it.
        let wrong = RemovalConfirmation(destroying: [
            .unmergedCommits(repoId: UUID(), repoPath: "/somewhere/else", branch: "task/stale")
        ])
        await #expect {
            _ = try await self.engine.removeTask(
                task, repos: configs, mode: .destroy(wrong))
        } throws: { error in
            guard case .staleConfirmation = error as? TaskEngineError else { return false }
            return true
        }

        #expect(try await git.listWorktrees(in: r1.path).count == 2)
        #expect(try await git.branchExists("task/stale", in: r1.path))
    }

    @Test func emptyConfirmationWhenUnmergedWorkExistsIsStale() async throws {
        let r1 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1)]
        let task = try await makeTask(name: "empty-conf", repos: configs)
        try commitWork(in: task.workspaces[0])

        await #expect {
            _ = try await self.engine.removeTask(
                task, repos: configs,
                mode: .destroy(RemovalConfirmation(destroying: [])))
        } throws: { error in
            guard case .staleConfirmation = error as? TaskEngineError else { return false }
            return true
        }
        #expect(try await git.branchExists("task/empty-conf", in: r1.path))
    }

    /// The anti-stale invariant now covers the DIRTY set: a worktree that
    /// became dirty AFTER the (empty) confirmation was built must abort — the
    /// engine recomputes dirtiness at removal time and refuses on the mismatch,
    /// touching nothing.
    @Test func confirmationBuiltCleanThenWorktreeDirtiedIsStale() async throws {
        let r1 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1)]
        let task = try await makeTask(name: "raced", repos: configs)

        // Sheet time: nothing to destroy.
        let assessed = try await engine.removalHazards(in: task, repos: configs)
        #expect(assessed.isEmpty)

        // Between assess and confirm the agent wrote uncommitted changes.
        try dirtyWork(in: task.workspaces[0])

        await #expect {
            _ = try await self.engine.removeTask(
                task, repos: configs,
                mode: .destroy(RemovalConfirmation(destroying: assessed)))
        } throws: { error in
            guard case .staleConfirmation = error as? TaskEngineError else { return false }
            return true
        }
        // Untouched: worktree still attached, uncommitted file still there.
        #expect(try await git.listWorktrees(in: r1.path).count == 2)
        #expect(FileManager.default.fileExists(
            atPath: task.workspaces[0].worktreeURL.appendingPathComponent("loose.txt").path))
    }

    @Test func workspaceReferencingUnknownRepoFailsLoud() async throws {
        let r1 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1)]
        let task = try await makeTask(name: "unknown", repos: configs)

        await #expect {
            // Repos list missing the config the workspace references.
            _ = try await self.engine.removeTask(task, repos: [], mode: .refuseIfHazards)
        } throws: { error in
            guard case .unknownRepo(let id) = error as? TaskEngineError else { return false }
            return id == configs[0].id
        }
    }

    // MARK: Dirty-hazard detection

    @Test func modifiedAndUntrackedFilesAreADirtyHazard() async throws {
        let r1 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1)]
        let task = try await makeTask(name: "detect-dirty", repos: configs)
        try dirtyWork(in: task.workspaces[0])

        let hazards = try await engine.removalHazards(in: task, repos: configs)
        #expect(hazards == [.dirtyWorktree(
            repoId: configs[0].id, repoPath: r1.path.path, branch: "task/detect-dirty")])
    }

    @Test func ignoredOnlyChangesAreNotAHazard() async throws {
        // Commit a .gitignore on the base branch so the worktree inherits it
        // and its branch stays merged.
        let r1 = try fixtures.cleanRepo()
        try Data("ignored.txt\n".utf8).write(
            to: r1.path.appendingPathComponent(".gitignore"))
        try fixtures.git(["add", ".gitignore"], in: r1.path)
        try fixtures.git(["commit", "-m", "add gitignore"], in: r1.path)

        let configs = [repoConfig(r1)]
        let task = try await makeTask(name: "ignored", repos: configs)
        // Only an ignored file is present — git's own "modified or untracked"
        // signal (and therefore `worktree remove`) does not count it.
        try Data("junk\n".utf8).write(
            to: task.workspaces[0].worktreeURL.appendingPathComponent("ignored.txt"))

        let hazards = try await engine.removalHazards(in: task, repos: configs)
        #expect(hazards.isEmpty)
    }

    @Test func goneWorktreeDirectoryIsNotDirty() async throws {
        let r1 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1)]
        let task = try await makeTask(name: "gone", repos: configs)
        // Someone rm -rf'd the worktree — there is nothing left to lose.
        try FileManager.default.removeItem(at: task.workspaces[0].worktreeURL)

        let hazards = try await engine.removalHazards(in: task, repos: configs)
        #expect(hazards.isEmpty)
    }

    /// Fail-secure: if the dirty check itself errors, the worktree is a hazard,
    /// never assumed clean. A corrupted `.git` link makes `git status` in the
    /// worktree fail while the directory still exists.
    @Test func dirtyDetectionFailureIsTreatedAsHazard() async throws {
        let r1 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1)]
        let task = try await makeTask(name: "status-fail", repos: configs)
        // Corrupt the worktree's gitdir link → `git status` there errors.
        try Data("garbage\n".utf8).write(
            to: task.workspaces[0].worktreeURL.appendingPathComponent(".git"))

        let hazards = try await engine.removalHazards(in: task, repos: configs)
        #expect(hazards == [.dirtyWorktree(
            repoId: configs[0].id, repoPath: r1.path.path, branch: "task/status-fail")])

        // And it refuses without a confirmation — never removes on unknown state.
        await #expect {
            _ = try await self.engine.removeTask(task, repos: configs, mode: .refuseIfHazards)
        } throws: { error in
            guard case .removalHazardsPresent = error as? TaskEngineError else { return false }
            return true
        }
    }

    // MARK: Confirmed destruction

    @Test func exactConfirmationDestroysUnmergedWork() async throws {
        let r1 = try fixtures.cleanRepo()
        let r2 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1), repoConfig(r2)]
        let task = try await makeTask(name: "destroy", repos: configs)
        try commitWork(in: task.workspaces[0])
        try commitWork(in: task.workspaces[1])

        // The UI flow: ask the engine what's hazardous, show it, confirm it.
        let hazards = try await engine.removalHazards(in: task, repos: configs)
        #expect(hazards.count == 2)
        let report = try await engine.removeTask(
            task, repos: configs,
            mode: .destroy(RemovalConfirmation(destroying: hazards)))

        #expect(report.workspaces.count == 2)
        for (outcome, repo) in zip(report.workspaces, [r1, r2]) {
            #expect(outcome.worktree == .removed)
            #expect(outcome.branchResult == .deleted)
            #expect(try await git.listWorktrees(in: repo.path).count == 1)
            #expect(try await git.branchExists("task/destroy", in: repo.path) == false)
        }
        #expect(!FileManager.default.fileExists(atPath: task.workspaces[0].worktreePath))
    }

    @Test func exactConfirmationDiscardsDirtyWorktree() async throws {
        let r1 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1)]
        let task = try await makeTask(name: "discard-dirty", repos: configs)
        try dirtyWork(in: task.workspaces[0])

        let hazards = try await engine.removalHazards(in: task, repos: configs)
        #expect(hazards.count == 1)
        let report = try await engine.removeTask(
            task, repos: configs,
            mode: .destroy(RemovalConfirmation(destroying: hazards)))

        #expect(report.workspaces[0].worktree == .removed)
        #expect(report.workspaces[0].branchResult == .deleted)
        #expect(try await git.listWorktrees(in: r1.path).count == 1)
        #expect(try await git.branchExists("task/discard-dirty", in: r1.path) == false)
        #expect(!FileManager.default.fileExists(atPath: task.workspaces[0].worktreePath))
    }

    // MARK: Clean removal and reconciliation

    @Test func mergedEverywhereTaskRemovesCleanlyWithoutForce() async throws {
        let r1 = try fixtures.cleanRepo()
        let r2 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1), repoConfig(r2)]
        // Fresh task: branch tip == base tip, clean working trees → no hazard;
        // removal never forces (a clean `worktree remove` succeeds on its own).
        let task = try await makeTask(name: "clean-remove", repos: configs)

        let report = try await engine.removeTask(task, repos: configs, mode: .refuseIfHazards)
        #expect(report.workspaces.allSatisfy {
            $0.worktree == .removed && $0.branchResult == .deleted
        })
        for repo in [r1, r2] {
            #expect(try await git.listWorktrees(in: repo.path).count == 1)
            #expect(try await git.branchExists("task/clean-remove", in: repo.path) == false)
        }
    }

    @Test func externallyDeletedWorktreeIsReconciledNotCrashed() async throws {
        let r1 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1)]
        let task = try await makeTask(name: "external", repos: configs)

        // Someone rm -rf'd the worktree behind Lighthouse's back.
        try FileManager.default.removeItem(at: task.workspaces[0].worktreeURL)

        let report = try await engine.removeTask(task, repos: configs, mode: .refuseIfHazards)
        #expect(report.workspaces.count == 1)
        #expect(report.workspaces[0].worktree == .alreadyGone)
        #expect(report.workspaces[0].branchResult == .deleted)
        // Registration cleaned up, branch gone.
        #expect(try await git.listWorktrees(in: r1.path).count == 1)
        #expect(try await git.branchExists("task/external", in: r1.path) == false)
    }

    @Test func externallyDeletedBranchIsReconciledNotCrashed() async throws {
        let r1 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1)]
        let task = try await makeTask(name: "nobranch", repos: configs)

        // Someone force-deleted the branch; worktree becomes detached.
        try fixtures.git(["checkout", "--detach"], in: task.workspaces[0].worktreeURL)
        try fixtures.git(["branch", "-D", "task/nobranch"], in: r1.path)

        let report = try await engine.removeTask(task, repos: configs, mode: .refuseIfHazards)
        #expect(report.workspaces[0].branchResult == .alreadyGone)
        #expect(try await git.listWorktrees(in: r1.path).count == 1)
    }
}
