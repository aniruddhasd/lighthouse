import Foundation
import Testing
import LighthouseFixtures
@testable import LighthouseGit

/// `commitDiff` against real fixture repos. Failure-first: an invalid hash
/// (option-lookalike, short flag, shell metachars) must be rejected by
/// validation BEFORE any subprocess runs — proven by the canary file that a
/// leaked `--output=` would create never existing.
@Suite("GitClient.commitDiff (fixture repos)")
final class GitClientCommitDiffTests {
    private let fixtures: FixtureFactory
    private let client = GitClient()

    init() throws { fixtures = try FixtureFactory() }
    deinit { try? fixtures.destroy() }

    private func canaryPath() -> String {
        fixtures.root.appendingPathComponent("PWNED-\(UUID().uuidString)").path
    }

    // MARK: - Failure cases (validation before any git call)

    @Test func invalidHashesAreRejectedAndNoSubprocessRuns() async throws {
        let repo = try fixtures.cleanRepo()
        for hostile in ["--output=", "-x", "; rm", "abc", "z".appending("zzz"), ""] {
            let canary = canaryPath()
            let arg = hostile == "--output=" ? "--output=\(canary)" : hostile
            await #expect {
                _ = try await self.client.commitDiff(worktree: repo.path, hash: arg)
            } throws: { error in
                guard case .invalidRevision = error as? GitClientError else { return false }
                return true
            }
            #expect(!FileManager.default.fileExists(atPath: canary), "commitDiff ran git for invalid hash")
        }
    }

    // MARK: - Happy path

    @Test func normalCommitYieldsAPatch() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 2)
        let head = try await client.headCommit(in: repo.path)
        let patch = try await client.commitDiff(worktree: repo.path, hash: head)
        #expect(patch.contains("diff --git"))
        #expect(patch.contains("notes.txt"))
        #expect(patch.contains("+line 2"))
    }

    @Test func rootCommitWithNoParentYieldsAnAddedFilePatch() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 2)
        // The root commit has no parent; `git show` must still produce a patch.
        let root = try fixtures.git(["rev-list", "--max-parents=0", "HEAD"], in: repo.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let patch = try await client.commitDiff(worktree: repo.path, hash: root)
        #expect(patch.contains("new file mode"))
        #expect(patch.contains("+line 1"))
    }

    @Test func abbreviatedHashIsAcceptedByTheValidator() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 1)
        let full = try await client.headCommit(in: repo.path)
        let short = String(full.prefix(8))
        let patch = try await client.commitDiff(worktree: repo.path, hash: short)
        #expect(patch.contains("diff --git"))
    }
}
