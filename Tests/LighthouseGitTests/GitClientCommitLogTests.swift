import Foundation
import Testing
import LighthouseFixtures
@testable import LighthouseGit

/// `commitLog` against real fixture repos. Edge cases first: a root-commit-only
/// repo, and an empty (unborn) repo which must yield `[]` — never a throw.
@Suite("GitClient.commitLog (fixture repos)")
final class GitClientCommitLogTests {
    private let fixtures: FixtureFactory
    private let client = GitClient()

    init() throws { fixtures = try FixtureFactory() }
    deinit { try? fixtures.destroy() }

    // MARK: - Edge cases

    @Test func emptyRepoYieldsNoCommits() async throws {
        let repo = try fixtures.emptyRepo()
        #expect(try await client.commitLog(worktree: repo.path, limit: 50) == [])
    }

    @Test func rootCommitOnlyRepoParsesTheSingleCommit() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 1)
        let commits = try await client.commitLog(worktree: repo.path, limit: 50)
        #expect(commits.count == 1)
        #expect(commits[0].subject == "commit 1")
    }

    // MARK: - Happy path + field correctness

    @Test func nCommitsParseNewestFirstWithCorrectFields() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 3)
        let commits = try await client.commitLog(worktree: repo.path, limit: 50)
        #expect(commits.count == 3)
        // Newest first.
        #expect(commits.map(\.subject) == ["commit 3", "commit 2", "commit 1"])
        let head = commits[0]
        #expect(head.hash.count == 40)
        #expect(head.hash.allSatisfy { $0.isHexDigit })
        #expect(head.hash.hasPrefix(head.shortHash))
        #expect(head.shortHash.count >= 4 && head.shortHash.count < 40)
        #expect(head.authorName == "Lighthouse Fixture")
        // Author date is strict ISO-8601 (%aI) — parseable by the ISO parser.
        #expect(ISO8601DateFormatter().date(from: head.authorDate) != nil)
    }

    @Test func limitCapsTheNumberOfCommitsReturned() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 5)
        let commits = try await client.commitLog(worktree: repo.path, limit: 2)
        #expect(commits.count == 2)
        #expect(commits.map(\.subject) == ["commit 5", "commit 4"])
    }
}
