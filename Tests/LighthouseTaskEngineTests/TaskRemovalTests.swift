import Foundation
import Testing
import LighthouseFixtures
import LighthouseGit
@testable import LighthouseTaskEngine

/// Guardrail 1 (spec §7): destroying unmerged work without a typed
/// confirmation carrying the exact (repo, branch) list is impossible at the
/// API level. Broken cases first.
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
            repos: repos, worktreesRoot: worktreesRoot)
    }

    /// Commits a file in the workspace — the branch tip moves past base:
    /// real unmerged work.
    private func commitWork(in workspace: Workspace, file: String = "work.txt") throws {
        let dir = workspace.worktreeURL
        try Data("agent output\n".utf8).write(to: dir.appendingPathComponent(file))
        try fixtures.git(["add", file], in: dir)
        try fixtures.git(["commit", "-m", "agent work"], in: dir)
    }

    // MARK: Broken cases first

    @Test func unmergedWorkRefusedWithExactList() async throws {
        let r1 = try fixtures.cleanRepo()
        let r2 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1), repoConfig(r2)]
        let task = try await makeTask(name: "refuse", repos: configs)
        // Unmerged work in repo 2 only.
        try commitWork(in: task.workspaces[1])

        await #expect {
            _ = try await self.engine.removeTask(task, repos: configs, mode: .refuseIfUnmerged)
        } throws: { error in
            guard case .unmergedWorkPresent(let items) = error as? TaskEngineError else {
                return false
            }
            return items == [UnmergedWorkItem(
                repoId: configs[1].id, repoPath: r2.path.path, branch: "task/refuse")]
        }

        // Nothing was touched.
        #expect(try await git.listWorktrees(in: r1.path).count == 2)
        #expect(try await git.listWorktrees(in: r2.path).count == 2)
        #expect(try await git.branchExists("task/refuse", in: r2.path))
    }

    @Test func staleConfirmationAbortsBeforeTouchingAnything() async throws {
        let r1 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1)]
        let task = try await makeTask(name: "stale", repos: configs)
        try commitWork(in: task.workspaces[0])

        // A confirmation for the WRONG thing (e.g. computed before more work
        // landed, or hand-built): the exact-list check must reject it.
        let wrong = UnmergedDestructionConfirmation(destroying: [
            UnmergedWorkItem(repoId: UUID(), repoPath: "/somewhere/else", branch: "task/stale")
        ])
        await #expect {
            _ = try await self.engine.removeTask(
                task, repos: configs, mode: .destroyUnmergedWork(wrong))
        } throws: { error in
            guard case .staleConfirmation = error as? TaskEngineError else { return false }
            return true
        }

        #expect(try await git.listWorktrees(in: r1.path).count == 2)
        #expect(try await git.branchExists("task/stale", in: r1.path))
    }

    @Test func emptyConfirmationWhenWorkExistsIsStale() async throws {
        let r1 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1)]
        let task = try await makeTask(name: "empty-conf", repos: configs)
        try commitWork(in: task.workspaces[0])

        await #expect {
            _ = try await self.engine.removeTask(
                task, repos: configs,
                mode: .destroyUnmergedWork(UnmergedDestructionConfirmation(destroying: [])))
        } throws: { error in
            guard case .staleConfirmation = error as? TaskEngineError else { return false }
            return true
        }
        #expect(try await git.branchExists("task/empty-conf", in: r1.path))
    }

    @Test func dirtyButMergedWorktreeStillRefusesEvenInDestroyMode() async throws {
        let r1 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1)]
        let task = try await makeTask(name: "dirty-merged", repos: configs)
        // No commits (branch tip == base tip → "merged"), but uncommitted
        // changes exist: ancestry can't see them, the dirty check must.
        try Data("uncommitted\n".utf8).write(
            to: task.workspaces[0].worktreeURL.appendingPathComponent("loose.txt"))

        for mode in [TaskRemovalMode.refuseIfUnmerged,
                     .destroyUnmergedWork(UnmergedDestructionConfirmation(destroying: []))] {
            await #expect {
                _ = try await self.engine.removeTask(task, repos: configs, mode: mode)
            } throws: { error in
                guard case .git(.dirtyWorktree) = error as? TaskEngineError else { return false }
                return true
            }
        }
        // The uncommitted file survived both attempts.
        #expect(FileManager.default.fileExists(
            atPath: task.workspaces[0].worktreeURL.appendingPathComponent("loose.txt").path))
    }

    @Test func workspaceReferencingUnknownRepoFailsLoud() async throws {
        let r1 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1)]
        let task = try await makeTask(name: "unknown", repos: configs)

        await #expect {
            // Repos list missing the config the workspace references.
            _ = try await self.engine.removeTask(task, repos: [], mode: .refuseIfUnmerged)
        } throws: { error in
            guard case .unknownRepo(let id) = error as? TaskEngineError else { return false }
            return id == configs[0].id
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

        // The UI flow: ask the engine what's unmerged, show it, confirm it.
        let items = try await engine.unmergedWork(in: task, repos: configs)
        #expect(items.count == 2)
        let report = try await engine.removeTask(
            task, repos: configs,
            mode: .destroyUnmergedWork(UnmergedDestructionConfirmation(destroying: items)))

        #expect(report.workspaces.count == 2)
        for (outcome, repo) in zip(report.workspaces, [r1, r2]) {
            #expect(outcome.worktree == .removed)
            #expect(outcome.branchResult == .deleted)
            #expect(try await git.listWorktrees(in: repo.path).count == 1)
            #expect(try await git.branchExists("task/destroy", in: repo.path) == false)
        }
        #expect(!FileManager.default.fileExists(atPath: task.workspaces[0].worktreePath))
    }

    // MARK: Clean removal and reconciliation

    @Test func mergedEverywhereTaskRemovesCleanly() async throws {
        let r1 = try fixtures.cleanRepo()
        let r2 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1), repoConfig(r2)]
        // Fresh task: branch tip == base tip in both repos → merged by
        // definition (reachable from base).
        let task = try await makeTask(name: "clean-remove", repos: configs)

        let report = try await engine.removeTask(task, repos: configs, mode: .refuseIfUnmerged)
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

        let report = try await engine.removeTask(task, repos: configs, mode: .refuseIfUnmerged)
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

        let report = try await engine.removeTask(task, repos: configs, mode: .refuseIfUnmerged)
        #expect(report.workspaces[0].branchResult == .alreadyGone)
        #expect(try await git.listWorktrees(in: r1.path).count == 1)
    }
}
