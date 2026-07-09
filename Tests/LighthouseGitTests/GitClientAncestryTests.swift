import Foundation
import Testing
import LighthouseFixtures
@testable import LighthouseGit

@Suite("GitClient branch/ancestry helpers (fixture repos)")
final class GitClientAncestryTests {
    private let fixtures: FixtureFactory
    private let client = GitClient()

    init() throws {
        fixtures = try FixtureFactory()
    }

    deinit {
        try? fixtures.destroy()
    }

    // MARK: Broken cases first

    @Test func isAncestorWithNonexistentRefThrows() async throws {
        let repo = try fixtures.cleanRepo()
        await #expect {
            _ = try await self.client.isAncestor("no-such-ref", of: "main", in: repo.path)
        } throws: { error in
            guard case .commandFailed = error as? GitClientError else { return false }
            return true
        }
    }

    @Test func branchExistsOnNonRepoThrowsNotARepository() async throws {
        let dir = try fixtures.nonRepoDirectory()
        await #expect {
            _ = try await self.client.branchExists("main", in: dir)
        } throws: { error in
            guard case .notARepository = error as? GitClientError else { return false }
            return true
        }
    }

    @Test func syntacticallyInvalidBranchNameSimplyDoesNotExist() async throws {
        let repo = try fixtures.cleanRepo()
        // rev-parse -q exits 1 quietly for a name it can't parse: false, not
        // a throw — validity is isValidBranchName's job.
        #expect(try await client.branchExists("bad name", in: repo.path) == false)
    }

    @Test func invalidBranchNamesRejectedByCheckRefFormat() async throws {
        #expect(try await client.isValidBranchName("bad name") == false)
        #expect(try await client.isValidBranchName("double..dot") == false)
        #expect(try await client.isValidBranchName("ends.lock") == false)
        #expect(try await client.isValidBranchName("") == false)
    }

    // MARK: Happy paths

    @Test func validBranchNamesAccepted() async throws {
        #expect(try await client.isValidBranchName("main"))
        #expect(try await client.isValidBranchName("task/payments-fix"))
    }

    @Test func branchExistenceReflectsReality() async throws {
        let repo = try fixtures.cleanRepo()
        #expect(try await client.branchExists("main", in: repo.path))
        #expect(try await client.branchExists("task/nope", in: repo.path) == false)
        try await client.createBranch("task/yep", in: repo.path)
        #expect(try await client.branchExists("task/yep", in: repo.path))
    }

    @Test func ancestryMatchesHistoryShape() async throws {
        let repo = try fixtures.cleanRepo()
        // Branch at tip: reachable both ways (same commit).
        try await client.createBranch("at-tip", in: repo.path)
        #expect(try await client.isAncestor("at-tip", of: "main", in: repo.path))

        // Branch moves ahead: no longer an ancestor of main; main is its ancestor.
        try fixtures.git(["checkout", "at-tip"], in: repo.path)
        try Data("ahead\n".utf8).write(to: repo.path.appendingPathComponent("ahead.txt"))
        try fixtures.git(["add", "ahead.txt"], in: repo.path)
        try fixtures.git(["commit", "-m", "ahead"], in: repo.path)
        try fixtures.git(["checkout", "main"], in: repo.path)
        #expect(try await client.isAncestor("at-tip", of: "main", in: repo.path) == false)
        #expect(try await client.isAncestor("main", of: "at-tip", in: repo.path))
    }
}
