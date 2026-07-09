import Foundation
import Testing
import LighthouseFixtures
@testable import LighthouseGit

@Suite("GitClient worktrees (fixture repos)")
final class GitClientWorktreeTests {
    private let fixtures: FixtureFactory
    private let client = GitClient()

    init() throws {
        fixtures = try FixtureFactory()
    }

    deinit {
        try? fixtures.destroy()
    }

    // MARK: Broken cases first

    @Test func listOnNonRepoThrowsNotARepository() async throws {
        let dir = try fixtures.nonRepoDirectory()
        await #expect {
            _ = try await self.client.listWorktrees(in: dir)
        } throws: { error in
            guard case .notARepository = error as? GitClientError else { return false }
            return true
        }
    }

    /// Guardrail-1 groundwork: removing a dirty worktree without force must
    /// be a typed error and must leave the tree untouched.
    @Test func removingDirtyWorktreeWithoutForceThrowsAndLeavesTreeUntouched() async throws {
        let fixture = try fixtures.repoWithAttachedWorktrees(count: 1)
        let worktree = fixture.worktrees[0]
        let dirtyFile = worktree.path.appendingPathComponent("uncommitted.txt")
        try Data("unmerged work\n".utf8).write(to: dirtyFile)

        await #expect {
            try await self.client.removeWorktree(
                at: worktree.path, in: fixture.repo.path, mode: .refuseIfDirty)
        } throws: { error in
            guard case .dirtyWorktree(_, let failure) = error as? GitClientError else {
                return false
            }
            return failure.exitCode != 0
        }

        // The worktree and the uncommitted file are still there.
        #expect(FileManager.default.fileExists(atPath: dirtyFile.path))
        let listed = try await client.listWorktrees(in: fixture.repo.path)
        #expect(listed.contains { $0.path == worktree.path.path })
    }

    @Test func forcedRemovalOfDirtyWorktreeSucceeds() async throws {
        let fixture = try fixtures.repoWithAttachedWorktrees(count: 1)
        let worktree = fixture.worktrees[0]
        try Data("doomed\n".utf8).write(
            to: worktree.path.appendingPathComponent("uncommitted.txt"))

        try await client.removeWorktree(
            at: worktree.path, in: fixture.repo.path,
            mode: .forceDiscardingChanges(justification: "test: user typed the confirmation"))

        #expect(!FileManager.default.fileExists(atPath: worktree.path.path))
    }

    @Test func addingWorktreeOnExistingBranchNameFails() async throws {
        let fixture = try fixtures.repoWithAttachedWorktrees(count: 1)
        let destination = fixture.repo.path.deletingLastPathComponent()
            .appendingPathComponent("dup-branch-wt")
        await #expect {
            // "wt-1" already exists — must fail loudly, not reuse it.
            try await self.client.addWorktree(
                at: destination, newBranch: fixture.worktrees[0].branch,
                from: fixture.repo.defaultBranch, in: fixture.repo.path)
        } throws: { error in
            guard case .commandFailed(let failure) = error as? GitClientError else {
                return false
            }
            return !failure.stderr.isEmpty
        }
    }

    // MARK: Paths with spaces (add / list / remove round-trip)

    @Test func worktreeRoundTripWithSpacesEverywhere() async throws {
        let fixture = try fixtures.spacesRepo()

        // Spaces belong in the PATHS; branch names cannot contain spaces
        // (git check-ref-format).
        try await client.addWorktree(
            at: fixture.worktreeDestination, newBranch: "task/spaced-work",
            from: fixture.repo.defaultBranch, in: fixture.repo.path)

        let listed = try await client.listWorktrees(in: fixture.repo.path)
        #expect(listed.count == 2)
        let added = try #require(listed.first { $0.path == fixture.worktreeDestination.path })
        #expect(added.branchShortName == "task/spaced-work")
        #expect(!added.isDetached)

        try await client.removeWorktree(
            at: fixture.worktreeDestination, in: fixture.repo.path, mode: .refuseIfDirty)
        let afterRemoval = try await client.listWorktrees(in: fixture.repo.path)
        #expect(afterRemoval.count == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.worktreeDestination.path))
    }

    // MARK: Happy paths

    @Test func listReportsMainAndAttachedWorktrees() async throws {
        let fixture = try fixtures.repoWithAttachedWorktrees(count: 2)
        let listed = try await client.listWorktrees(in: fixture.repo.path)

        #expect(listed.count == 3) // main worktree + 2 linked
        #expect(listed[0].path == fixture.repo.path.path) // main is always first
        for attached in fixture.worktrees {
            let record = try #require(listed.first { $0.path == attached.path.path })
            #expect(record.branchShortName == attached.branch)
            #expect(record.headObject != nil)
        }
    }

    @Test func addedWorktreeStartsAtBaseRefTip() async throws {
        let repo = try fixtures.cleanRepo()
        let baseTip = try await client.headCommit(in: repo.path)
        let destination = repo.path.deletingLastPathComponent().appendingPathComponent("task-wt")

        try await client.addWorktree(
            at: destination, newBranch: "task/one", from: "main", in: repo.path)

        #expect(try await client.headCommit(in: destination) == baseTip)
        let status = try await client.status(in: destination)
        #expect(status.head == .branch("task/one"))
        #expect(status.isClean)
    }
}
