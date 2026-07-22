import Foundation
import Testing
import LighthouseFixtures
import LighthouseGit
@testable import LighthouseTaskEngine

/// Adding a workspace to an ALREADY-created task: a new worktree, a registered
/// repo's checkout tracked in-place, or an adopted existing worktree. The
/// guards that must hold (no duplicate repo, real git work tree, belongs to a
/// registered repo) are asserted first.
@Suite("TaskEngine add-workspace (fixture repos)")
final class AddWorkspaceTests {
    private let fixtures: FixtureFactory
    private let git = GitClient()
    private let engine: TaskEngine

    init() throws {
        fixtures = try FixtureFactory()
        engine = TaskEngine(git: git)
    }
    deinit { try? fixtures.destroy() }

    private func repoConfig(_ repo: FixtureRepo) -> RepoConfig {
        RepoConfig(path: repo.path.path, baseBranch: repo.defaultBranch)
    }

    /// A worktree task on repo A, branch "feature".
    private func baseTask(_ repoA: RepoConfig) async throws -> TaskRecord {
        try await engine.createTask(
            name: "task", branch: "feature", adapterKind: "claude-code", repos: [repoA])
    }

    // MARK: - Failures first

    @Test func addWorktreeRejectsRepoAlreadyInTask() async throws {
        let a = repoConfig(try fixtures.cleanRepo())
        let task = try await baseTask(a)
        await #expect {
            _ = try await self.engine.addWorktreeWorkspace(to: task, repo: a, branch: "feature")
        } throws: { error in
            guard case .repoAlreadyInTask = error as? TaskEngineError else { return false }
            return true
        }
    }

    @Test func trackInPlaceRejectsRepoAlreadyInTask() async throws {
        let a = repoConfig(try fixtures.cleanRepo())
        let task = try await baseTask(a)
        await #expect {
            _ = try await self.engine.inPlaceWorkspace(for: a, addingTo: task)
        } throws: { error in
            guard case .repoAlreadyInTask = error as? TaskEngineError else { return false }
            return true
        }
    }

    @Test func adoptRejectsNonWorktreeDirectory() async throws {
        let a = repoConfig(try fixtures.cleanRepo())
        let task = try await baseTask(a)
        let plain = try fixtures.nonRepoDirectory()
        await #expect {
            _ = try await self.engine.adoptWorktreeWorkspace(
                at: plain, addingTo: task, repos: [a])
        } throws: { error in
            guard case .notAGitWorktree = error as? TaskEngineError else { return false }
            return true
        }
    }

    @Test func adoptRejectsWorktreeOfNoRegisteredRepo() async throws {
        let a = repoConfig(try fixtures.cleanRepo())
        let task = try await baseTask(a)
        // A different repo's own checkout — a real work tree, but not A's.
        let stranger = try fixtures.cleanRepo()
        await #expect {
            _ = try await self.engine.adoptWorktreeWorkspace(
                at: stranger.path, addingTo: task, repos: [a])
        } throws: { error in
            guard case .notAWorktreeOfRegisteredRepo = error as? TaskEngineError else { return false }
            return true
        }
    }

    // MARK: - Happy paths

    @Test func addWorktreeCreatesBranchAndWorkspace() async throws {
        let a = repoConfig(try fixtures.cleanRepo())
        let b = repoConfig(try fixtures.cleanRepo())
        let task = try await baseTask(a)

        let ws = try await engine.addWorktreeWorkspace(to: task, repo: b, branch: "feature")

        #expect(ws.repoId == b.id)
        #expect(!ws.isInPlace)
        #expect(ws.mergeState == .unmerged)
        #expect(FileManager.default.fileExists(atPath: ws.worktreePath))
        #expect(try await git.branchExists("feature", in: b.pathURL))
    }

    @Test func trackInPlaceReturnsUnownedCheckoutWorkspace() async throws {
        let a = repoConfig(try fixtures.cleanRepo())
        let b = repoConfig(try fixtures.cleanRepo())
        let task = try await baseTask(a)

        let ws = try await engine.inPlaceWorkspace(for: b, addingTo: task)

        #expect(ws.repoId == b.id)
        #expect(ws.isInPlace) // never merged back / destroyed
        #expect(ws.mergeState == .merged)
        #expect(ws.worktreePath == b.path)
    }

    @Test func adoptTracksAnExistingWorktreeOfARegisteredRepo() async throws {
        let a = repoConfig(try fixtures.cleanRepo())
        let bRepo = try fixtures.cleanRepo()
        let b = repoConfig(bRepo)
        let task = try await baseTask(a)

        // The agent spun up its own worktree of repo B.
        let wt = bRepo.path.deletingLastPathComponent()
            .appendingPathComponent("agent-wt-\(UUID().uuidString.prefix(6))")
        _ = try fixtures.git(
            ["worktree", "add", "-b", "agent", wt.path, bRepo.defaultBranch], in: bRepo.path)

        let ws = try await engine.adoptWorktreeWorkspace(
            at: wt, addingTo: task, repos: [a, b])

        #expect(ws.repoId == b.id) // matched to B by its worktree list
        #expect(ws.isInPlace) // adopted → Lighthouse doesn't own it
        #expect(ws.worktreePath == wt.resolvingSymlinksInPath().path)
    }
}
