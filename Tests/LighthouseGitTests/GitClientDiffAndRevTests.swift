import Foundation
import Testing
import LighthouseFixtures
@testable import LighthouseGit

@Suite("GitClient diff, branches, rev-parse (fixture repos)")
final class GitClientDiffAndRevTests {
    private let fixtures: FixtureFactory
    private let client = GitClient()

    init() throws {
        fixtures = try FixtureFactory()
    }

    deinit {
        try? fixtures.destroy()
    }

    // MARK: Broken cases first

    @Test func revParseOnNonRepoThrowsNotARepository() async throws {
        let dir = try fixtures.nonRepoDirectory()
        await #expect {
            _ = try await self.client.headCommit(in: dir)
        } throws: { error in
            guard case .notARepository = error as? GitClientError else { return false }
            return true
        }
    }

    @Test func isInsideWorkTreeIsFalseForPlainDirectoryWithoutThrowing() async throws {
        let dir = try fixtures.nonRepoDirectory()
        #expect(try await client.isInsideWorkTree(at: dir) == false)
    }

    @Test func revParseUnknownRevisionThrows() async throws {
        let repo = try fixtures.cleanRepo()
        await #expect {
            _ = try await self.client.revParse("does-not-exist", in: repo.path)
        } throws: { error in
            guard case .commandFailed = error as? GitClientError else { return false }
            return true
        }
    }

    @Test func deletingUnmergedBranchWithoutForceThrows() async throws {
        let repo = try fixtures.cleanRepo()
        try await client.createBranch("orphan", in: repo.path)
        try fixtures.git(["checkout", "orphan"], in: repo.path)
        try Data("unmerged\n".utf8).write(to: repo.path.appendingPathComponent("only-here.txt"))
        try fixtures.git(["add", "only-here.txt"], in: repo.path)
        try fixtures.git(["commit", "-m", "unmerged commit"], in: repo.path)
        try fixtures.git(["checkout", "main"], in: repo.path)

        await #expect {
            try await self.client.deleteBranch("orphan", in: repo.path)
        } throws: { error in
            guard case .commandFailed(let failure) = error as? GitClientError else {
                return false
            }
            return !failure.stderr.isEmpty
        }
        // Forced deletion is the explicit opt-in.
        try await client.deleteBranch("orphan", force: true, in: repo.path)
    }

    @Test func launchFailureIsTypedNotSilent() async throws {
        let repo = try fixtures.cleanRepo()
        let broken = GitClient(gitExecutable: "/nonexistent/not-git")
        await #expect {
            _ = try await broken.headCommit(in: repo.path)
        } throws: { error in
            guard case .launchFailed = error as? GitClientError else { return false }
            return true
        }
    }

    // MARK: rev-parse from subdirectories

    @Test func topLevelFromWorktreeSubdirectory() async throws {
        let repo = try fixtures.cleanRepo()
        let subdir = repo.path.appendingPathComponent("deep/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        let top = try await client.topLevel(of: subdir)
        // Compare resolved paths: /var/folders is a symlink to /private/var.
        #expect(top.resolvingSymlinksInPath().path == repo.path.resolvingSymlinksInPath().path)
        #expect(try await client.isInsideWorkTree(at: subdir))
        #expect(try await client.headCommit(in: subdir) == (try await client.headCommit(in: repo.path)))
    }

    // MARK: Diff happy paths

    @Test func diffBaseTripleDotShowsOnlyBranchSideChanges() async throws {
        let repo = try fixtures.cleanRepo()
        // Branch adds a file; main then moves ahead with its own commit —
        // base...HEAD must show only the branch side.
        try fixtures.git(["checkout", "-b", "task"], in: repo.path)
        try Data("branch work\n".utf8).write(to: repo.path.appendingPathComponent("branch-file.txt"))
        try fixtures.git(["add", "branch-file.txt"], in: repo.path)
        try fixtures.git(["commit", "-m", "branch work"], in: repo.path)
        try fixtures.git(["checkout", "main"], in: repo.path)
        try Data("main moved on\n".utf8).write(to: repo.path.appendingPathComponent("main-file.txt"))
        try fixtures.git(["add", "main-file.txt"], in: repo.path)
        try fixtures.git(["commit", "-m", "main moved on"], in: repo.path)
        try fixtures.git(["checkout", "task"], in: repo.path)

        let patch = try await client.diffAgainstBase("main", in: repo.path)
        #expect(patch.contains("branch-file.txt"))
        #expect(patch.contains("+branch work"))
        #expect(!patch.contains("main-file.txt"))

        let entries = try await client.diffNameStatus(against: "main", in: repo.path)
        #expect(entries == [DiffEntry(change: .added, path: "branch-file.txt")])
    }

    @Test func diffNameStatusReportsModificationsAndDeletions() async throws {
        let repo = try fixtures.cleanRepo()
        try fixtures.git(["checkout", "-b", "edits"], in: repo.path)
        try Data("rewritten\n".utf8).write(to: repo.path.appendingPathComponent("notes.txt"))
        try fixtures.git(["rm", "--cached", "-q", "notes.txt"], in: repo.path)
        try fixtures.git(["add", "notes.txt"], in: repo.path)
        try Data("extra\n".utf8).write(to: repo.path.appendingPathComponent("extra.txt"))
        try fixtures.git(["add", "extra.txt"], in: repo.path)
        try fixtures.git(["commit", "-m", "edit and add"], in: repo.path)

        let entries = try await client.diffNameStatus(against: "main", in: repo.path)
        #expect(entries.count == 2)
        #expect(entries.contains(DiffEntry(change: .added, path: "extra.txt")))
        #expect(entries.contains(DiffEntry(change: .modified, path: "notes.txt")))
    }

    // MARK: Branch happy path

    @Test func createBranchAtExplicitRef() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 2)
        let firstCommit = try await client.revParse("HEAD~1", in: repo.path)
        try await client.createBranch("from-first", at: firstCommit, in: repo.path)
        #expect(try await client.revParse("from-first", in: repo.path) == firstCommit)
        try await client.deleteBranch("from-first", in: repo.path)
        await #expect(throws: GitClientError.self) {
            _ = try await self.client.revParse("from-first", in: repo.path)
        }
    }
}
