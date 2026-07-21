import Foundation
import Testing
import LighthouseFixtures
import LighthouseGit
@testable import LighthouseTaskEngine

/// In-place tasks run in the registered repo's OWN checkout (investigation
/// mode) — no worktree, no branch. The overriding contract is that removal, and
/// hazard detection, must NEVER touch the user's repo or its branches. Failure
/// modes (destruction, false hazards) are asserted first.
@Suite("TaskEngine in-place tasks (fixture repos)")
final class InPlaceTaskTests {
    private let fixtures: FixtureFactory
    private let git = GitClient()
    private let engine: TaskEngine

    init() throws {
        fixtures = try FixtureFactory()
        engine = TaskEngine(git: git)
    }

    deinit {
        try? fixtures.destroy()
    }

    private func repoConfig(_ repo: FixtureRepo) -> RepoConfig {
        RepoConfig(path: repo.path.path, baseBranch: repo.defaultBranch)
    }

    // MARK: - Failure modes first: removal must not destroy the user's repo

    /// Removing an in-place task — even when its repo has UNCOMMITTED changes
    /// and commits ahead of base — leaves the repo directory, its working-tree
    /// edits, and its branch fully intact. Nothing the user owns is destroyed.
    @Test func removingInPlaceTaskLeavesRepoAndBranchUntouched() async throws {
        let repo = try fixtures.cleanRepo()
        let config = repoConfig(repo)

        let task = try await engine.createInPlaceTask(
            name: "investigate", adapterKind: "claude-code", repos: [config])

        // Dirty the repo AND move its branch ahead of base — the exact state a
        // worktree task would flag as a hazard and force-destroy.
        let loose = repo.path.appendingPathComponent("loose.txt")
        try Data("scratch\n".utf8).write(to: loose)
        try Data("edited\n".utf8).write(to: repo.path.appendingPathComponent("notes.txt"))
        _ = try fixtures.git(["add", "notes.txt"], in: repo.path)
        _ = try fixtures.git(["commit", "-m", "ahead of base"], in: repo.path)

        // No hazards → removal needs no destructive confirmation.
        let hazards = try await engine.removalHazards(in: task, repos: [config])
        #expect(hazards.isEmpty)

        let report = try await engine.removeTask(
            task, repos: [config], mode: .refuseIfHazards)

        #expect(report.workspaces.count == 1)
        #expect(report.workspaces[0].worktree == .leftInPlace)
        #expect(report.workspaces[0].branchResult == .leftInPlace)

        // The repo, its uncommitted file, its tracked edit, and its branch all
        // survive.
        #expect(FileManager.default.fileExists(atPath: repo.path.path))
        #expect(FileManager.default.fileExists(atPath: loose.path))
        #expect(try await git.branchExists(repo.defaultBranch, in: repo.path))
        let status = try await git.status(in: repo.path)
        #expect(!status.isClean)  // the untracked file is still there
    }

    /// Hazard detection never reports an in-place workspace, no matter how dirty
    /// or unmerged — there is nothing removal would destroy.
    @Test func inPlaceWorkspaceNeverContributesHazards() async throws {
        let dirty = try fixtures.dirtyRepo()
        let config = repoConfig(dirty.repo)
        let task = try await engine.createInPlaceTask(
            name: "poke", adapterKind: "claude-code", repos: [config])

        let hazards = try await engine.removalHazards(in: task, repos: [config])
        #expect(hazards.isEmpty)
    }

    // MARK: - Creation

    /// In-place creation points the workspace at the repo's OWN path, flags it
    /// in-place and merged, creates NO worktree directory, and records the
    /// repo's current branch for display.
    @Test func createsWorkspaceAtRepoPathWithoutWorktreeOrBranch() async throws {
        let repo = try fixtures.cleanRepo()
        let config = repoConfig(repo)

        let task = try await engine.createInPlaceTask(
            name: "learn", adapterKind: "claude-code", repos: [config])

        #expect(task.workspaces.count == 1)
        let ws = task.workspaces[0]
        #expect(ws.isInPlace)
        #expect(ws.worktreePath == repo.path.path)
        #expect(ws.mergeState == .merged)
        #expect(task.isInPlace)
        // Branch recorded for display is the repo's real current branch — not a
        // freshly created one.
        #expect(task.branch == repo.defaultBranch)
        // No "lighthouse-worktrees" grouping dir was created next to the repo.
        let sibling = repo.path.deletingLastPathComponent()
            .appendingPathComponent(TaskEngine.worktreesDirectoryName)
        #expect(!FileManager.default.fileExists(atPath: sibling.path))
    }

    /// Empty repo list and an invalid task name fail loud before any work — the
    /// same pre-flight guarantees as worktree creation.
    @Test func rejectsEmptyReposAndInvalidNames() async throws {
        await #expect(throws: TaskCreationFailure.self) {
            _ = try await engine.createInPlaceTask(
                name: "x", adapterKind: "claude-code", repos: [])
        }
        let repo = try fixtures.cleanRepo()
        await #expect(throws: TaskCreationFailure.self) {
            _ = try await engine.createInPlaceTask(
                name: "bad/name", adapterKind: "claude-code", repos: [self.repoConfig(repo)])
        }
    }

    /// A path that is not a git worktree fails loud (repoNotFound) rather than
    /// producing a bogus in-place workspace.
    @Test func rejectsNonRepoPath() async throws {
        let dir = try fixtures.nonRepoDirectory()
        let config = RepoConfig(path: dir.path, baseBranch: "main")
        await #expect(throws: TaskCreationFailure.self) {
            _ = try await engine.createInPlaceTask(
                name: "nope", adapterKind: "claude-code", repos: [config])
        }
    }
}

/// A legacy persisted `Workspace` (written before in-place mode) has no
/// `isInPlace` key; it must decode to `false` — the safe worktree default that
/// keeps the removal path destroying only Lighthouse-created worktrees.
@Suite("Workspace backward-compatible decode")
struct WorkspaceDecodeTests {
    @Test func legacyWorkspaceWithoutIsInPlaceDecodesFalse() throws {
        let json = """
        {
          "repoId": "\(UUID().uuidString)",
          "worktreePath": "/tmp/wt",
          "mergeState": "unmerged"
        }
        """
        let ws = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        #expect(ws.isInPlace == false)
    }

    @Test func isInPlaceRoundTrips() throws {
        let ws = Workspace(
            repoId: UUID(), worktreePath: "/tmp/repo",
            mergeState: .merged, isInPlace: true)
        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        #expect(decoded == ws)
        #expect(decoded.isInPlace)
    }
}
