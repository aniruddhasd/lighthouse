import Foundation
import Testing
import LighthouseFixtures
@testable import LighthouseGit

/// `RepoCloner` — the one network git op, tested offline by cloning a local
/// fixture repo (a local path is a valid clone source). Failure modes first.
@Suite("RepoCloner (local-path clones)")
final class RepoClonerTests {
    private let fixtures: FixtureFactory
    private let cloner = RepoCloner()

    init() throws { fixtures = try FixtureFactory() }
    deinit { try? fixtures.destroy() }

    // MARK: - Failures first

    @Test func cloningANonexistentSourceFails() async throws {
        let missing = fixtures.root.appendingPathComponent("no-such-source")
        let dest = fixtures.root.appendingPathComponent("dest")
        await #expect {
            try await self.cloner.clone(url: missing.path, into: dest)
        } throws: { error in
            guard case .cloneFailed(let stderr) = error as? RepoCloneError else { return false }
            return !stderr.isEmpty
        }
        // git removes the target dir it created when a clone fails.
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func launchFailureWhenGitExecutableMissing() async throws {
        let brokenCloner = RepoCloner(gitExecutable: "/nonexistent/git")
        let repo = try fixtures.cleanRepo()
        let dest = fixtures.root.appendingPathComponent("dest")
        await #expect {
            try await brokenCloner.clone(url: repo.path.path, into: dest)
        } throws: { error in
            guard case .launchFailed = error as? RepoCloneError else { return false }
            return true
        }
    }

    // MARK: - Happy path

    @Test func clonesLocalRepoIntoDestination() async throws {
        let source = try fixtures.cleanRepo()
        let dest = fixtures.root.appendingPathComponent("cloned", isDirectory: true)

        try await cloner.clone(url: source.path.path, into: dest)

        // A real working tree lands at the destination.
        #expect(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent(".git").path))
        // And it is a functioning clone: git accepts it as a work tree.
        let insideWorkTree = try await GitClient().isInsideWorkTree(at: dest)
        #expect(insideWorkTree)
    }
}
