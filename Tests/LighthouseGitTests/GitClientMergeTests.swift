import Foundation
import Testing
import LighthouseFixtures
@testable import LighthouseGit

@Suite("GitClient merge (fixture repos)")
final class GitClientMergeTests {
    private let fixtures: FixtureFactory
    private let client = GitClient()

    init() throws {
        fixtures = try FixtureFactory()
    }

    deinit {
        try? fixtures.destroy()
    }

    // MARK: Conflicts first — a conflict is a state, not a thrown failure

    @Test func contentConflictReportedAsStateWithMergeHeadAndUEntries() async throws {
        let fixture = try fixtures.contentConflictRepo()

        #expect(try await client.isMergeInProgress(in: fixture.repo.path) == false)
        let outcome = try await client.merge(fixture.incomingBranch, in: fixture.repo.path)
        #expect(outcome == .conflicted(paths: [fixture.conflictedPath]))
        #expect(try await client.isMergeInProgress(in: fixture.repo.path))

        let status = try await client.status(in: fixture.repo.path)
        #expect(status.conflictedPaths == [fixture.conflictedPath])
    }

    @Test func mergingNonexistentBranchThrowsNotConflict() async throws {
        let repo = try fixtures.cleanRepo()
        await #expect {
            _ = try await self.client.merge("no-such-branch", in: repo.path)
        } throws: { error in
            guard case .commandFailed(let failure) = error as? GitClientError else {
                return false
            }
            return failure.exitCode != 0 && !failure.stderr.isEmpty
        }
        // A failed (not conflicted) merge must not leave merge state behind.
        #expect(try await client.isMergeInProgress(in: repo.path) == false)
    }

    @Test func continueMergeWhileStillConflictedStaysConflicted() async throws {
        let fixture = try fixtures.contentConflictRepo()
        _ = try await client.merge(fixture.incomingBranch, in: fixture.repo.path)

        // Nothing resolved yet: continuing must report the conflict state
        // again, not complete and not crash.
        let outcome = try await client.continueMerge(in: fixture.repo.path)
        #expect(outcome == .conflicted(paths: [fixture.conflictedPath]))
        #expect(try await client.isMergeInProgress(in: fixture.repo.path))
    }

    @Test func rematerializeConflictRestoresZdiff3Markers() async throws {
        let fixture = try fixtures.contentConflictRepo()
        _ = try await client.merge(fixture.incomingBranch, in: fixture.repo.path)
        let conflictedFile = fixture.repo.path.appendingPathComponent(fixture.conflictedPath)

        // Simulate an external editor destroying the markers.
        try Data("mangled beyond recognition\n".utf8).write(to: conflictedFile)

        try await client.rematerializeConflict(path: fixture.conflictedPath, in: fixture.repo.path)

        // zdiff3 markers include the base section delimiter "|||||||".
        // Reading the file here is test verification, not client behavior.
        let content = try String(contentsOf: conflictedFile, encoding: .utf8)
        #expect(content.contains("<<<<<<<"))
        #expect(content.contains("|||||||"))
        #expect(content.contains("======="))
        #expect(content.contains(">>>>>>>"))
        #expect(content.contains("main change"))
        #expect(content.contains("feature change"))
        #expect(content.contains("common")) // the base section's line
    }

    @Test func resolveStageAndContinueCompletesMerge() async throws {
        let fixture = try fixtures.contentConflictRepo()
        _ = try await client.merge(fixture.incomingBranch, in: fixture.repo.path)

        // Resolve and stage. Staging is deliberately outside GitClient's API
        // surface for this build step, so the fixture runner does it.
        let conflictedFile = fixture.repo.path.appendingPathComponent(fixture.conflictedPath)
        try Data("alpha\nresolved\nomega\n".utf8).write(to: conflictedFile)
        try fixtures.git(["add", fixture.conflictedPath], in: fixture.repo.path)

        let outcome = try await client.continueMerge(in: fixture.repo.path)
        #expect(outcome == .merged)
        #expect(try await client.isMergeInProgress(in: fixture.repo.path) == false)

        // The resulting merge commit has both parents.
        let headParent2 = try await client.revParse("HEAD^2", in: fixture.repo.path)
        let featureTip = try await client.revParse(fixture.incomingBranch, in: fixture.repo.path)
        #expect(headParent2 == featureTip)
    }

    // MARK: Happy paths

    @Test func fastForwardMergeMovesHeadToBranchTip() async throws {
        let repo = try fixtures.cleanRepo()
        // Build a branch strictly ahead of main, then come back to main.
        try fixtures.git(["checkout", "-b", "ahead"], in: repo.path)
        try Data("new\n".utf8).write(to: repo.path.appendingPathComponent("new.txt"))
        try fixtures.git(["add", "new.txt"], in: repo.path)
        try fixtures.git(["commit", "-m", "ahead commit"], in: repo.path)
        try fixtures.git(["checkout", "main"], in: repo.path)

        let outcome = try await client.merge("ahead", in: repo.path)
        #expect(outcome == .merged)
        // Fast-forward: HEAD is exactly the branch tip, no merge commit.
        let head = try await client.headCommit(in: repo.path)
        let branchTip = try await client.revParse("ahead", in: repo.path)
        #expect(head == branchTip)
    }

    @Test func nonFastForwardCleanMergeCreatesMergeCommit() async throws {
        let repo = try fixtures.cleanRepo()
        // Diverge without overlap: different files on each branch.
        try fixtures.git(["checkout", "-b", "side"], in: repo.path)
        try Data("side\n".utf8).write(to: repo.path.appendingPathComponent("side.txt"))
        try fixtures.git(["add", "side.txt"], in: repo.path)
        try fixtures.git(["commit", "-m", "side commit"], in: repo.path)
        try fixtures.git(["checkout", "main"], in: repo.path)
        try Data("mainline\n".utf8).write(to: repo.path.appendingPathComponent("mainline.txt"))
        try fixtures.git(["add", "mainline.txt"], in: repo.path)
        try fixtures.git(["commit", "-m", "main commit"], in: repo.path)
        let mainTipBefore = try await client.headCommit(in: repo.path)

        let outcome = try await client.merge("side", in: repo.path)
        #expect(outcome == .merged)
        #expect(try await client.isMergeInProgress(in: repo.path) == false)

        // Merge commit: parent 1 is the old main tip, parent 2 the side tip.
        #expect(try await client.revParse("HEAD^1", in: repo.path) == mainTipBefore)
        let sideTip = try await client.revParse("side", in: repo.path)
        #expect(try await client.revParse("HEAD^2", in: repo.path) == sideTip)
    }
}
