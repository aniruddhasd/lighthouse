import Foundation
import Testing
import LighthouseFixtures
import LighthouseGit
@testable import LighthouseTaskEngine

/// Guardrail 5 (spec §5) enforced at the API level, not just hidden in UI:
/// the walk never auto-resolves, auto-commits a resolution, or reorders.
@Suite("MergeWalk guardrail 5 (fixture repos)")
final class MergeWalkGuardrailTests {
    private let fixtures: FixtureFactory
    private let git = GitClient()

    init() throws { fixtures = try FixtureFactory() }
    deinit { try? fixtures.destroy() }

    @Test func completeNeverAutoCommitsAnUnresolvedConflict() async throws {
        let fixture = try fixtures.contentConflictRepo()
        let walk = MergeWalk(
            taskBranch: fixture.incomingBranch,
            orderedRepos: [RepoConfig(path: fixture.repo.path.path, baseBranch: "main")],
            git: git)
        _ = try await walk.run()

        // Repeatedly asking to complete, with NOTHING staged, must never
        // produce a commit — the merge stays in progress every time.
        for _ in 0..<3 {
            let state = try await walk.completeCurrentRepo()
            guard case .paused(_, .conflicted) = state else {
                Issue.record("auto-completed an unresolved conflict: \(state)"); return
            }
            #expect(try await git.isMergeInProgress(in: fixture.repo.path))
        }
    }

    @Test func runIsIdempotentAndDoesNotResolveOnItsOwn() async throws {
        let fixture = try fixtures.contentConflictRepo()
        let walk = MergeWalk(
            taskBranch: fixture.incomingBranch,
            orderedRepos: [RepoConfig(path: fixture.repo.path.path, baseBranch: "main")],
            git: git)
        let first = try await walk.run()
        let second = try await walk.run()
        #expect(first == second) // still paused on the same conflict
        // The conflicted file still has its markers — the walk did not touch it.
        let content = try String(
            contentsOf: fixture.repo.path.appendingPathComponent(fixture.conflictedPath),
            encoding: .utf8)
        #expect(content.contains("<<<<<<<"))
    }

    /// A clone on main with a cleanly-mergeable "task" branch.
    private func mergeableRepo() throws -> FixtureRepo {
        let repo = try fixtures.cleanRepo()
        try fixtures.git(["checkout", "-b", "task"], in: repo.path)
        try Data("f\n".utf8).write(to: repo.path.appendingPathComponent("f.txt"))
        try fixtures.git(["add", "f.txt"], in: repo.path)
        try fixtures.git(["commit", "-m", "f"], in: repo.path)
        try fixtures.git(["checkout", "main"], in: repo.path)
        return repo
    }

    @Test func walkOrderIsFixedAtConstructionNoReorderAPI() async throws {
        // The public surface offers no way to change order after construction;
        // repoProgress reflects the input order and only ever changes state,
        // never position, across the walk's lifetime.
        let a = try mergeableRepo()
        let b = try mergeableRepo()
        let ordered = [RepoConfig(path: a.path.path, baseBranch: "main"),
                       RepoConfig(path: b.path.path, baseBranch: "main")]
        let walk = MergeWalk(taskBranch: "task", orderedRepos: ordered, git: git)
        let before = await walk.repoProgress.map(\.repoPath)
        _ = try await walk.run()
        let after = await walk.repoProgress.map(\.repoPath)
        #expect(before == [a.path.path, b.path.path])
        #expect(after == before)
    }
}
