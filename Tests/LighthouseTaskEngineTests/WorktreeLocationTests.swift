import Foundation
import Testing
import LighthouseFixtures
import LighthouseGit
@testable import LighthouseTaskEngine

/// Worktree placement (2026-07-12): default is per-repo —
/// `<repo parent>/lighthouse-worktrees/<task>/<repo>` — so sessions stay in
/// the directory trees that cwd-keyed tooling watches; a global override
/// replaces the grouping location. Creation stays atomic: rollback and
/// removal clean up the directory husks they created and NEVER remove a
/// non-empty directory or a pre-existing one.
@Suite("Worktree location and husk cleanup (fixture repos)")
final class WorktreeLocationTests {
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

    /// A repo named `dirName` inside its own parent directory — for testing
    /// per-parent derivation with same-named repos in different parents.
    private func repoInOwnParent(parent: String, dirName: String) throws -> FixtureRepo {
        let parentDir = fixtures.root.appendingPathComponent(parent, isDirectory: true)
        let repoDir = parentDir.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try fixtures.git(["init", "-b", "main"], in: repoDir)
        try fixtures.git(["config", "user.name", "Fixture"], in: repoDir)
        try fixtures.git(["config", "user.email", "f@f.invalid"], in: repoDir)
        try fixtures.git(["config", "commit.gpgsign", "false"], in: repoDir)
        try Data("seed\n".utf8).write(to: repoDir.appendingPathComponent("seed.txt"))
        try fixtures.git(["add", "."], in: repoDir)
        try fixtures.git(["commit", "-m", "seed"], in: repoDir)
        return FixtureRepo(path: repoDir, defaultBranch: "main")
    }

    private func config(_ repo: FixtureRepo, setupScript: String? = nil) -> RepoConfig {
        RepoConfig(path: repo.path.path, baseBranch: repo.defaultBranch, setupScript: setupScript)
    }

    // MARK: Failure cases first

    @Test func unwritableParentFailsLoudBeforeAnyMutation() async throws {
        let repo = try repoInOwnParent(parent: "ro-parent", dirName: "repo")
        let parent = repo.path.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: parent.path)
        }

        var caught: TaskCreationFailure?
        do {
            _ = try await engine.createTask(
                name: "blocked", branch: "task/blocked", adapterKind: "claude-code",
                repos: [config(repo)])
        } catch let failure as TaskCreationFailure {
            caught = failure
        }
        let failure = try #require(caught)
        guard case .worktreeDestinationNotWritable(_, let ancestor) = failure.cause else {
            Issue.record("wrong cause: \(failure.cause)")
            return
        }
        #expect(ancestor == parent.path)
        guard case .notNeeded = failure.rollback else {
            Issue.record("pre-mutation failure must need no rollback")
            return
        }
        #expect(try await git.branchExists("task/blocked", in: repo.path) == false)
    }

    @Test func rollbackRemovesTheParentDirsItCreated() async throws {
        let r1 = try repoInOwnParent(parent: "parent-a", dirName: "svc")
        let r2 = try repoInOwnParent(parent: "parent-b", dirName: "svc")
        // Repo 2's setup script fails after repo 1's worktree (and its
        // freshly created lighthouse-worktrees dirs) exist.
        try Data("#!/bin/sh\nexit 9\n".utf8).write(to: r2.path.appendingPathComponent("boom.sh"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: r2.path.appendingPathComponent("boom.sh").path)

        var caught: TaskCreationFailure?
        do {
            _ = try await engine.createTask(
                name: "husks", branch: "task/husks", adapterKind: "claude-code",
                repos: [config(r1), config(r2, setupScript: "boom.sh")])
        } catch let failure as TaskCreationFailure {
            caught = failure
        }
        let failure = try #require(caught)
        guard case .completed = failure.rollback else {
            Issue.record("expected clean rollback, got \(failure.rollback)")
            return
        }
        // No lighthouse-worktrees husks left in either parent.
        for repo in [r1, r2] {
            let grouping = repo.path.deletingLastPathComponent()
                .appendingPathComponent(TaskEngine.worktreesDirectoryName)
            #expect(!FileManager.default.fileExists(atPath: grouping.path),
                    "husk left behind: \(grouping.path)")
        }
    }

    @Test func rollbackNeverRemovesAPreexistingOrNonEmptyDir() async throws {
        let repo = try repoInOwnParent(parent: "parent-c", dirName: "svc")
        // lighthouse-worktrees pre-exists WITH unrelated content.
        let grouping = repo.path.deletingLastPathComponent()
            .appendingPathComponent(TaskEngine.worktreesDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: grouping, withIntermediateDirectories: true)
        let unrelated = grouping.appendingPathComponent("keep-me.txt")
        try Data("precious\n".utf8).write(to: unrelated)

        try Data("#!/bin/sh\nexit 9\n".utf8).write(to: repo.path.appendingPathComponent("boom.sh"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: repo.path.appendingPathComponent("boom.sh").path)

        do {
            _ = try await engine.createTask(
                name: "careful", branch: "task/careful", adapterKind: "claude-code",
                repos: [config(repo, setupScript: "boom.sh")])
        } catch is TaskCreationFailure {}

        // The pre-existing dir and its content survived; only the task
        // subdirectory this attempt created is gone.
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(!FileManager.default.fileExists(
            atPath: grouping.appendingPathComponent("careful").path))
    }

    // MARK: Placement

    @Test func defaultDerivesPerRepoParentEvenWithSameRepoNames() async throws {
        let r1 = try repoInOwnParent(parent: "team-one", dirName: "svc")
        let r2 = try repoInOwnParent(parent: "team-two", dirName: "svc")

        let task = try await engine.createTask(
            name: "cross", branch: "task/cross", adapterKind: "claude-code",
            repos: [config(r1), config(r2)])

        let expected1 = fixtures.root
            .appendingPathComponent("team-one/\(TaskEngine.worktreesDirectoryName)/cross/svc").path
        let expected2 = fixtures.root
            .appendingPathComponent("team-two/\(TaskEngine.worktreesDirectoryName)/cross/svc").path
        #expect(task.workspaces.map(\.worktreePath) == [expected1, expected2])
        for workspace in task.workspaces {
            #expect(try await git.isInsideWorkTree(at: workspace.worktreeURL))
        }
    }

    @Test func overrideReplacesTheDerivedLocation() async throws {
        let repo = try repoInOwnParent(parent: "parent-d", dirName: "svc")
        let override = fixtures.root.appendingPathComponent("my custom root", isDirectory: true)

        let task = try await engine.createTask(
            name: "overridden", branch: "task/overridden", adapterKind: "claude-code",
            repos: [config(repo)], worktreesRootOverride: override)

        #expect(task.workspaces[0].worktreePath
            == override.appendingPathComponent("overridden/svc").path)
        // Nothing derived next to the repo.
        #expect(!FileManager.default.fileExists(
            atPath: repo.path.deletingLastPathComponent()
                .appendingPathComponent(TaskEngine.worktreesDirectoryName).path))
    }

    // MARK: Removal husk cleanup

    @Test func removalCleansEmptiedGroupingDirs() async throws {
        let repo = try repoInOwnParent(parent: "parent-e", dirName: "svc")
        let repoConfig = config(repo)
        let task = try await engine.createTask(
            name: "tidy", branch: "task/tidy", adapterKind: "claude-code",
            repos: [repoConfig])

        _ = try await engine.removeTask(
            task, repos: [repoConfig], mode: .refuseIfUnmerged)

        let grouping = repo.path.deletingLastPathComponent()
            .appendingPathComponent(TaskEngine.worktreesDirectoryName)
        #expect(!FileManager.default.fileExists(atPath: grouping.path))
    }

    @Test func removalKeepsGroupingDirWhileOtherTasksLiveThere() async throws {
        let repo = try repoInOwnParent(parent: "parent-f", dirName: "svc")
        let repoConfig = config(repo)
        let keep = try await engine.createTask(
            name: "keeper", branch: "task/keeper", adapterKind: "claude-code",
            repos: [repoConfig])
        let doomed = try await engine.createTask(
            name: "doomed", branch: "task/doomed", adapterKind: "claude-code",
            repos: [repoConfig])

        _ = try await engine.removeTask(
            doomed, repos: [repoConfig], mode: .refuseIfUnmerged)

        // The shared grouping dir stays (non-empty); only doomed's task dir
        // is gone; keeper's worktree is untouched.
        let grouping = repo.path.deletingLastPathComponent()
            .appendingPathComponent(TaskEngine.worktreesDirectoryName)
        #expect(FileManager.default.fileExists(atPath: grouping.path))
        #expect(!FileManager.default.fileExists(
            atPath: grouping.appendingPathComponent("doomed").path))
        #expect(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: keep.workspaces[0].worktreePath).path))
        _ = try await engine.removeTask(keep, repos: [repoConfig], mode: .refuseIfUnmerged)
        #expect(!FileManager.default.fileExists(atPath: grouping.path))
    }

    @Test func removalNeverRemovesTheOverrideRootItself() async throws {
        let repo = try repoInOwnParent(parent: "parent-g", dirName: "svc")
        let repoConfig = config(repo)
        let override = fixtures.root.appendingPathComponent("chosen-root", isDirectory: true)
        let task = try await engine.createTask(
            name: "solo", branch: "task/solo", adapterKind: "claude-code",
            repos: [repoConfig], worktreesRootOverride: override)

        _ = try await engine.removeTask(task, repos: [repoConfig], mode: .refuseIfUnmerged)

        // The task dir inside the override is cleaned, but the user-chosen
        // root directory itself is never deleted, even when empty.
        #expect(!FileManager.default.fileExists(
            atPath: override.appendingPathComponent("solo").path))
        #expect(FileManager.default.fileExists(atPath: override.path))
    }
}
