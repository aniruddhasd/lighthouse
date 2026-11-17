import Foundation
import Testing
import LighthouseFixtures
import LighthouseGit
@testable import LighthouseTaskEngine

/// Removing ONE repo (workspace) from a task — the inverse of add-workspace.
/// Same guardrail-1 hazard gate as whole-task removal, but scoped to the single
/// workspace: it must refuse unconfirmed hazards, delete only the targeted
/// worktree+branch, and never touch the task's other workspaces. Broken cases
/// first.
@Suite("TaskEngine.removeWorkspace (fixture repos)")
final class WorkspaceRemovalTests {
    private let fixtures: FixtureFactory
    private let worktreesRoot: URL
    private let git = GitClient()
    private let engine: TaskEngine

    init() throws {
        fixtures = try FixtureFactory()
        worktreesRoot = fixtures.root.appendingPathComponent("worktrees", isDirectory: true)
        engine = TaskEngine(git: git)
    }

    deinit { try? fixtures.destroy() }

    private func repoConfig(_ repo: FixtureRepo) -> RepoConfig {
        RepoConfig(path: repo.path.path, baseBranch: repo.defaultBranch)
    }

    private func makeTask(name: String, repos: [RepoConfig]) async throws -> TaskRecord {
        try await engine.createTask(
            name: name, branch: "task/\(name)", adapterKind: "claude-code",
            repos: repos, worktreesRootOverride: worktreesRoot)
    }

    private func commitWork(in workspace: Workspace, file: String = "work.txt") throws {
        let dir = workspace.worktreeURL
        try Data("agent output\n".utf8).write(to: dir.appendingPathComponent(file))
        try fixtures.git(["add", file], in: dir)
        try fixtures.git(["commit", "-m", "agent work"], in: dir)
    }

    private func dirtyWork(in workspace: Workspace) throws {
        let dir = workspace.worktreeURL
        try Data("local edit\n".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data("scratch\n".utf8).write(to: dir.appendingPathComponent("loose.txt"))
    }

    // MARK: Broken cases first — refusal

    @Test func unmergedWorkspaceRefusedWithOnlyItsOwnHazard() async throws {
        let r1 = try fixtures.cleanRepo()
        let r2 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1), repoConfig(r2)]
        let task = try await makeTask(name: "refuse", repos: configs)
        // Unmerged work in repo 2 only — removing repo 2 must refuse.
        try commitWork(in: task.workspaces[1])

        await #expect {
            _ = try await self.engine.removeWorkspace(
                withRepoId: configs[1].id, from: task, repos: configs, mode: .refuseIfHazards)
        } throws: { error in
            guard case .removalHazardsPresent(let hazards) = error as? TaskEngineError else {
                return false
            }
            return hazards == [.unmergedCommits(
                repoId: configs[1].id, repoPath: r2.path.path, branch: "task/refuse")]
        }

        // Neither workspace was touched.
        #expect(try await git.listWorktrees(in: r1.path).count == 2)
        #expect(try await git.listWorktrees(in: r2.path).count == 2)
        #expect(try await git.branchExists("task/refuse", in: r2.path))
    }

    @Test func dirtyWorkspaceRefusesWithoutConfirmation() async throws {
        let r1 = try fixtures.cleanRepo()
        let r2 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1), repoConfig(r2)]
        let task = try await makeTask(name: "dirty", repos: configs)
        try dirtyWork(in: task.workspaces[0])

        await #expect {
            _ = try await self.engine.removeWorkspace(
                withRepoId: configs[0].id, from: task, repos: configs, mode: .refuseIfHazards)
        } throws: { error in
            guard case .removalHazardsPresent(let hazards) = error as? TaskEngineError else {
                return false
            }
            return hazards == [.dirtyWorktree(
                repoId: configs[0].id, repoPath: r1.path.path, branch: "task/dirty")]
        }
        #expect(try await git.listWorktrees(in: r1.path).count == 2)
        #expect(FileManager.default.fileExists(
            atPath: task.workspaces[0].worktreeURL.appendingPathComponent("loose.txt").path))
    }

    @Test func staleConfirmationAbortsBeforeTouchingAnything() async throws {
        let r1 = try fixtures.cleanRepo()
        let r2 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1), repoConfig(r2)]
        let task = try await makeTask(name: "stale", repos: configs)
        try commitWork(in: task.workspaces[0])

        let wrong = RemovalConfirmation(destroying: [
            .unmergedCommits(repoId: UUID(), repoPath: "/elsewhere", branch: "task/stale")
        ])
        await #expect {
            _ = try await self.engine.removeWorkspace(
                withRepoId: configs[0].id, from: task, repos: configs, mode: .destroy(wrong))
        } throws: { error in
            guard case .staleConfirmation = error as? TaskEngineError else { return false }
            return true
        }
        #expect(try await git.listWorktrees(in: r1.path).count == 2)
        #expect(try await git.branchExists("task/stale", in: r1.path))
    }

    @Test func removingUnknownRepoFailsLoud() async throws {
        let r1 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1)]
        let task = try await makeTask(name: "unknown", repos: configs)
        let strangerId = UUID()
        await #expect {
            _ = try await self.engine.removeWorkspace(
                withRepoId: strangerId, from: task, repos: configs, mode: .refuseIfHazards)
        } throws: { error in
            guard case .unknownRepo(let id) = error as? TaskEngineError else { return false }
            return id == strangerId
        }
    }

    // MARK: Per-workspace hazard query

    @Test func hazardQueryReturnsOnlyTheNamedWorkspacesHazards() async throws {
        let r1 = try fixtures.cleanRepo()
        let r2 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1), repoConfig(r2)]
        let task = try await makeTask(name: "scoped", repos: configs)
        // Both dirty — but a query for repo 2 reports only repo 2.
        try dirtyWork(in: task.workspaces[0])
        try dirtyWork(in: task.workspaces[1])

        let hazards = try await engine.removalHazards(
            forWorkspaceWithRepoId: configs[1].id, in: task, repos: configs)
        #expect(hazards == [.dirtyWorktree(
            repoId: configs[1].id, repoPath: r2.path.path, branch: "task/scoped")])
    }

    // MARK: Confirmed / clean removal — only the one workspace

    @Test func exactConfirmationRemovesOneWorktreeLeavingTheOther() async throws {
        let r1 = try fixtures.cleanRepo()
        let r2 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1), repoConfig(r2)]
        let task = try await makeTask(name: "destroy-one", repos: configs)
        try commitWork(in: task.workspaces[0])
        try commitWork(in: task.workspaces[1])

        let hazards = try await engine.removalHazards(
            forWorkspaceWithRepoId: configs[0].id, in: task, repos: configs)
        #expect(hazards.count == 1)
        let outcome = try await engine.removeWorkspace(
            withRepoId: configs[0].id, from: task, repos: configs,
            mode: .destroy(RemovalConfirmation(destroying: hazards)))

        #expect(outcome.repoId == configs[0].id)
        #expect(outcome.worktree == .removed)
        #expect(outcome.branchResult == .deleted)
        // Repo 1 torn down…
        #expect(try await git.listWorktrees(in: r1.path).count == 1)
        #expect(try await git.branchExists("task/destroy-one", in: r1.path) == false)
        #expect(!FileManager.default.fileExists(atPath: task.workspaces[0].worktreePath))
        // …repo 2 (with its own unmerged work) completely untouched.
        #expect(try await git.listWorktrees(in: r2.path).count == 2)
        #expect(try await git.branchExists("task/destroy-one", in: r2.path))
        #expect(FileManager.default.fileExists(atPath: task.workspaces[1].worktreePath))
    }

    @Test func cleanWorkspaceRemovesWithoutForceLeavingOthers() async throws {
        let r1 = try fixtures.cleanRepo()
        let r2 = try fixtures.cleanRepo()
        let configs = [repoConfig(r1), repoConfig(r2)]
        let task = try await makeTask(name: "clean-one", repos: configs)

        let outcome = try await engine.removeWorkspace(
            withRepoId: configs[1].id, from: task, repos: configs, mode: .refuseIfHazards)

        #expect(outcome.worktree == .removed)
        #expect(outcome.branchResult == .deleted)
        #expect(try await git.listWorktrees(in: r2.path).count == 1)
        #expect(try await git.branchExists("task/clean-one", in: r2.path) == false)
        // Repo 1 still fully present.
        #expect(try await git.listWorktrees(in: r1.path).count == 2)
        #expect(try await git.branchExists("task/clean-one", in: r1.path))
    }

    @Test func inPlaceWorkspaceIsUntrackedNotDeleted() async throws {
        let r1 = try fixtures.cleanRepo()
        let r2 = try fixtures.cleanRepo()
        let c1 = repoConfig(r1)
        let c2 = repoConfig(r2)
        // Owned worktree on r1, plus r2 tracked IN PLACE (its own checkout).
        var task = try await makeTask(name: "mixed", repos: [c1])
        let inPlace = try await engine.inPlaceWorkspace(for: c2, addingTo: task)
        task.workspaces.append(inPlace)

        let outcome = try await engine.removeWorkspace(
            withRepoId: c2.id, from: task, repos: [c1, c2], mode: .refuseIfHazards)

        // Nothing on disk for r2 is touched — it was never ours.
        #expect(outcome.worktree == .leftInPlace)
        #expect(outcome.branchResult == .leftInPlace)
        #expect(FileManager.default.fileExists(atPath: r2.path.path))
        #expect(try await git.listWorktrees(in: r2.path).count == 1) // just its own checkout
        // And r1's owned worktree is still there.
        #expect(try await git.listWorktrees(in: r1.path).count == 2)
    }
}
