import Foundation
import Testing
import LighthouseFixtures
@testable import LighthouseGit

/// Live status tests against hermetic fixture repos. Broken and edge cases
/// first; the clean happy path last.
@Suite("GitClient.status (fixture repos)")
final class GitClientStatusTests {
    private let fixtures: FixtureFactory
    private let client = GitClient()

    init() throws {
        fixtures = try FixtureFactory()
    }

    deinit {
        try? fixtures.destroy()
    }

    // MARK: Broken cases first

    @Test func statusOnNonRepoThrowsNotARepository() async throws {
        let dir = try fixtures.nonRepoDirectory()
        await #expect {
            _ = try await self.client.status(in: dir)
        } throws: { error in
            guard case .notARepository(let path, let failure) = error as? GitClientError else {
                return false
            }
            return path == dir.path && failure.exitCode != 0 && !failure.stderr.isEmpty
        }
    }

    @Test func dirtyTreeReportsAllThreeDirtKinds() async throws {
        let fixture = try fixtures.dirtyRepo()
        let status = try await client.status(in: fixture.repo.path)
        #expect(!status.isClean)
        #expect(status.stagedPaths == [fixture.stagedPath])
        #expect(status.unstagedPaths == [fixture.unstagedPath])
        #expect(status.untracked == [fixture.untrackedPath])
        #expect(status.head == .branch(fixture.repo.defaultBranch))
    }

    @Test func detachedHeadReported() async throws {
        let fixture = try fixtures.detachedHeadRepo()
        let status = try await client.status(in: fixture.repo.path)
        #expect(status.head == .detached)
        #expect(status.headObject == fixture.detachedAt)
    }

    @Test func midMergeContentConflictShowsBothModified() async throws {
        let fixture = try fixtures.contentConflictRepo()
        // Raw git to reach the conflicted state (a conflicting merge exits
        // non-zero → ignore); this asserts status parsing, not the merge itself.
        _ = try? fixtures.git(["merge", "--no-edit", fixture.incomingBranch], in: fixture.repo.path)

        let status = try await client.status(in: fixture.repo.path)
        let entry = try #require(status.unmerged.first)
        #expect(entry.kind == .bothModified)
        #expect(entry.path == fixture.conflictedPath)
    }

    @Test func deleteModifyConflictDetectedFromUStages() async throws {
        let fixture = try fixtures.deleteModifyConflictRepo()
        _ = try? fixtures.git(["merge", "--no-edit", fixture.incomingBranch], in: fixture.repo.path)

        let status = try await client.status(in: fixture.repo.path)
        let entry = try #require(status.unmerged.first)
        // Ours (main) modified, theirs (feature) deleted → "deleted by them".
        #expect(entry.kind == .deletedByThem)
        #expect(entry.kind.isDeleteModify)
        #expect(entry.path == fixture.conflictedPath)
        // Stage 3 (theirs) has no mode because the file is gone on that side.
        #expect(entry.stage3Mode == "000000")
    }

    @Test func binaryConflictDetectedFromStatusNotContent() async throws {
        let fixture = try fixtures.binaryConflictRepo()
        _ = try? fixtures.git(["merge", "--no-edit", fixture.incomingBranch], in: fixture.repo.path)

        // The conflicted file contains raw binary, no text markers — the u
        // line alone is the detector.
        let status = try await client.status(in: fixture.repo.path)
        let entry = try #require(status.unmerged.first)
        #expect(entry.kind == .bothModified)
        #expect(entry.path == fixture.conflictedPath)
    }

    // MARK: Happy paths

    @Test func cleanRepoIsClean() async throws {
        let repo = try fixtures.cleanRepo()
        let status = try await client.status(in: repo.path)
        #expect(status.isClean)
        #expect(status.head == .branch("main"))
        #expect(status.headObject == (try await client.headCommit(in: repo.path)))
    }

    @Test func developBaseBranchReported() async throws {
        let repo = try fixtures.developBaseRepo()
        let status = try await client.status(in: repo.path)
        #expect(status.head == .branch("develop"))
    }
}
