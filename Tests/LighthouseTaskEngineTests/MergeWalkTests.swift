import Foundation
import Testing
import LighthouseFixtures
import LighthouseGit
@testable import LighthouseTaskEngine

/// The merge walk over fixture repos (spec §2.5, §7). Failure and precondition
/// cases first; the conflict end-to-end and clean happy path last. The clone
/// is the fixture repo (on base), the "task branch" is the fixture's
/// incoming branch — exactly the merge-back shape.
@Suite("MergeWalk (fixture repos)")
final class MergeWalkTests {
    private let fixtures: FixtureFactory
    private let git = GitClient()

    init() throws {
        fixtures = try FixtureFactory()
    }

    deinit {
        try? fixtures.destroy()
    }

    private func repoConfig(_ repo: FixtureRepo, base: String = "main") -> RepoConfig {
        RepoConfig(path: repo.path.path, baseBranch: base)
    }

    /// A clone on `main` with a `task` branch strictly ahead (no conflict).
    private func cleanMergeableRepo() throws -> FixtureRepo {
        let repo = try fixtures.cleanRepo()
        try fixtures.git(["checkout", "-b", "task"], in: repo.path)
        try Data("feature work\n".utf8).write(to: repo.path.appendingPathComponent("feature.txt"))
        try fixtures.git(["add", "feature.txt"], in: repo.path)
        try fixtures.git(["commit", "-m", "feature"], in: repo.path)
        try fixtures.git(["checkout", "main"], in: repo.path)
        return repo
    }

    // MARK: Preconditions pause with the right reason

    @Test func dirtyClonePausesWithReason() async throws {
        let repo = try cleanMergeableRepo()
        try Data("uncommitted\n".utf8).write(to: repo.path.appendingPathComponent("dirt.txt"))
        try fixtures.git(["add", "dirt.txt"], in: repo.path)
        let walk = MergeWalk(taskBranch: "task", orderedRepos: [repoConfig(repo)], git: git)

        let state = try await walk.run()
        guard case .paused(_, .cloneDirty(let path)) = state else {
            Issue.record("expected cloneDirty, got \(state)"); return
        }
        #expect(path == repo.path.path)
    }

    @Test func wrongBranchPausesWithReason() async throws {
        let repo = try cleanMergeableRepo()
        try fixtures.git(["checkout", "task"], in: repo.path) // clone NOT on base
        let walk = MergeWalk(taskBranch: "task", orderedRepos: [repoConfig(repo)], git: git)

        let state = try await walk.run()
        guard case .paused(_, .cloneNotOnBase(_, let base, let actual)) = state else {
            Issue.record("expected cloneNotOnBase, got \(state)"); return
        }
        #expect(base == "main")
        #expect(actual == "task")
    }

    @Test func missingBasePausesWithReason() async throws {
        let repo = try cleanMergeableRepo()
        let walk = MergeWalk(
            taskBranch: "task", orderedRepos: [repoConfig(repo, base: "no-such-base")], git: git)
        let state = try await walk.run()
        guard case .paused(_, .baseMissing) = state else {
            Issue.record("expected baseMissing, got \(state)"); return
        }
    }

    @Test func detachedClonePauses() async throws {
        let repo = try cleanMergeableRepo()
        try fixtures.git(["checkout", "--detach"], in: repo.path)
        let walk = MergeWalk(taskBranch: "task", orderedRepos: [repoConfig(repo)], git: git)
        let state = try await walk.run()
        guard case .paused(_, .cloneDetached) = state else {
            Issue.record("expected cloneDetached, got \(state)"); return
        }
    }

    // MARK: Conflict pauses (a state, not an error) and resolves end-to-end

    @Test func conflictPausesAndReportsPaths() async throws {
        let fixture = try fixtures.contentConflictRepo() // clone on main, "feature" conflicts
        let walk = MergeWalk(
            taskBranch: fixture.incomingBranch,
            orderedRepos: [repoConfig(fixture.repo)], git: git)

        let state = try await walk.run()
        guard case .paused(_, .conflicted(let repoPath, let paths)) = state else {
            Issue.record("expected conflicted, got \(state)"); return
        }
        #expect(repoPath == fixture.repo.path.path)
        #expect(paths == [fixture.conflictedPath])
        #expect(await walk.conflictedPaths() == [fixture.conflictedPath])
        // MERGE_HEAD is present — a real paused merge in the clone.
        #expect(try await git.isMergeInProgress(in: fixture.repo.path))
    }

    @Test func resolveThenCompleteFinishesTheWalk() async throws {
        let fixture = try fixtures.contentConflictRepo()
        let walk = MergeWalk(
            taskBranch: fixture.incomingBranch,
            orderedRepos: [repoConfig(fixture.repo)], git: git)
        _ = try await walk.run()

        // Resolve by writing clean content + staging (what the resolver does).
        let file = fixture.repo.path.appendingPathComponent(fixture.conflictedPath)
        try Data("alpha\nresolved\nomega\n".utf8).write(to: file)
        try await git.stage(paths: [fixture.conflictedPath], in: fixture.repo.path)

        let state = try await walk.completeCurrentRepo()
        #expect(state == .completed)
        #expect(try await git.isMergeInProgress(in: fixture.repo.path) == false)
        let progress = await walk.repoProgress
        #expect(progress.allSatisfy { $0.state == .merged })
    }

    @Test func completeWhileStillConflictedStaysPaused() async throws {
        let fixture = try fixtures.contentConflictRepo()
        let walk = MergeWalk(
            taskBranch: fixture.incomingBranch,
            orderedRepos: [repoConfig(fixture.repo)], git: git)
        _ = try await walk.run()
        // Nothing staged: completing must NOT finish — never auto-resolves.
        let state = try await walk.completeCurrentRepo()
        guard case .paused(_, .conflicted) = state else {
            Issue.record("must stay paused, got \(state)"); return
        }
    }

    @Test func abortRestoresCloneAndPauses() async throws {
        let fixture = try fixtures.contentConflictRepo()
        let walk = MergeWalk(
            taskBranch: fixture.incomingBranch,
            orderedRepos: [repoConfig(fixture.repo)], git: git)
        _ = try await walk.run()

        let state = try await walk.abortCurrentRepo()
        guard case .paused(_, .abortedByUser) = state else {
            Issue.record("expected abortedByUser, got \(state)"); return
        }
        // Merge state gone; clone clean on base again.
        #expect(try await git.isMergeInProgress(in: fixture.repo.path) == false)
        let status = try await git.status(in: fixture.repo.path)
        #expect(status.isClean)
        #expect(status.head == .branch("main"))
    }

    // MARK: Multi-repo order and partial-merge

    /// A conflicting clone on the SAME task branch name (a Lighthouse task
    /// uses one branch name across repos): main and task both edit one line.
    private func conflictingTaskRepo() throws -> FixtureRepo {
        let repo = try fixtures.cleanRepo()
        let file = "shared.txt"
        try Data("alpha\ncommon\nomega\n".utf8).write(to: repo.path.appendingPathComponent(file))
        try fixtures.git(["add", file], in: repo.path)
        try fixtures.git(["commit", "-m", "seed shared"], in: repo.path)
        try fixtures.git(["checkout", "-b", "task"], in: repo.path)
        try Data("alpha\ntask edit\nomega\n".utf8).write(to: repo.path.appendingPathComponent(file))
        try fixtures.git(["commit", "-am", "task edit"], in: repo.path)
        try fixtures.git(["checkout", "main"], in: repo.path)
        try Data("alpha\nmain edit\nomega\n".utf8).write(to: repo.path.appendingPathComponent(file))
        try fixtures.git(["commit", "-am", "main edit"], in: repo.path)
        return repo
    }

    @Test func walkMergesFirstThenStopsAtConflictLeavingOrderIntact() async throws {
        let clean = try cleanMergeableRepo()          // "task" merges cleanly
        let conflicting = try conflictingTaskRepo()   // "task" conflicts
        let walk = MergeWalk(
            taskBranch: "task",
            orderedRepos: [repoConfig(clean), repoConfig(conflicting)], git: git)

        let state = try await walk.run()
        // Paused at the second repo on a conflict; the first is merged.
        guard case .paused(_, .conflicted(let path, _)) = state else {
            Issue.record("expected conflicted at repo 2, got \(state)"); return
        }
        #expect(path == conflicting.path.path)
        let progress = await walk.repoProgress
        #expect(progress.map(\.repoPath) == [clean.path.path, conflicting.path.path]) // order intact
        #expect(progress[0].state == .merged)
        #expect(progress[1].state == .conflicted)  // partially-merged, visible
    }

    @Test func cleanRepoMergesAndCompletes() async throws {
        let repo = try cleanMergeableRepo()
        let walk = MergeWalk(taskBranch: "task", orderedRepos: [repoConfig(repo)], git: git)
        let state = try await walk.run()
        #expect(state == .completed)
        // The feature commit is now on main.
        #expect(try await git.isAncestor("task", of: "main", in: repo.path))
    }
}
