import Foundation
import Testing
import LighthouseFixtures
@testable import LighthouseGit

/// Option-injection hardening: a revision argument that looks like a git
/// option (`--output=<path>`, `-c…`) must be treated as a ref — errored as
/// an unknown/invalid revision — never parsed as an option. `--end-of-options`
/// (and `--` for `worktree add`, which rejects `--end-of-options`) guards
/// every ref-in-option-position call.
@Suite("GitClient option-injection guards (fixture repos)")
final class GitClientOptionInjectionTests {
    private let fixtures: FixtureFactory
    private let client = GitClient()

    init() throws {
        fixtures = try FixtureFactory()
    }

    deinit {
        try? fixtures.destroy()
    }

    /// A path the git command would create/write to if the option leaked
    /// through. The assertion is: it never exists afterwards.
    private func canaryPath() -> String {
        fixtures.root.appendingPathComponent("PWNED-\(UUID().uuidString)").path
    }

    @Test func diffAgainstBaseTreatsOutputOptionAsRef() async throws {
        let repo = try fixtures.cleanRepo()
        let canary = canaryPath()
        await #expect {
            _ = try await self.client.diffAgainstBase("--output=\(canary)", in: repo.path)
        } throws: { _ in true } // any throw is fine; the file check is the proof
        #expect(!FileManager.default.fileExists(atPath: canary), "diff --output leaked")
    }

    @Test func liveDiffTreatsOutputOptionAsRef() async throws {
        let repo = try fixtures.cleanRepo()
        let canary = canaryPath()
        await #expect {
            _ = try await self.client.liveDiff(againstMergeBaseOf: "--output=\(canary)", in: repo.path)
        } throws: { _ in true }
        #expect(!FileManager.default.fileExists(atPath: canary), "liveDiff --output leaked")
    }

    @Test func liveDiffNameStatusTreatsOutputOptionAsRef() async throws {
        let repo = try fixtures.cleanRepo()
        let canary = canaryPath()
        await #expect {
            _ = try await self.client.liveDiffNameStatus(
                againstMergeBaseOf: "--output=\(canary)", in: repo.path)
        } throws: { _ in true }
        #expect(!FileManager.default.fileExists(atPath: canary))
    }

    @Test func revParseTreatsOptionLookalikeAsRevision() async throws {
        let repo = try fixtures.cleanRepo()
        let canary = canaryPath()
        await #expect {
            _ = try await self.client.revParse("--output=\(canary)", in: repo.path)
        } throws: { error in
            guard case .commandFailed = error as? GitClientError else { return false }
            return true
        }
        #expect(!FileManager.default.fileExists(atPath: canary))
    }

    @Test func isAncestorTreatsOptionLookalikeAsRevision() async throws {
        let repo = try fixtures.cleanRepo()
        let canary = canaryPath()
        await #expect {
            _ = try await self.client.isAncestor("--output=\(canary)", of: "HEAD", in: repo.path)
        } throws: { error in
            // exit != 0/1 → error, never silent option consumption
            guard case .commandFailed = error as? GitClientError else { return false }
            return true
        }
        #expect(!FileManager.default.fileExists(atPath: canary))
    }

    @Test func mergeTreatsOptionLookalikeAsBranch() async throws {
        let repo = try fixtures.cleanRepo()
        let canary = canaryPath()
        await #expect {
            _ = try await self.client.merge("--output=\(canary)", in: repo.path)
        } throws: { _ in true }
        #expect(!FileManager.default.fileExists(atPath: canary))
        // A failed (not conflicted) merge must not leave merge state behind.
        #expect(try await client.isMergeInProgress(in: repo.path) == false)
    }

    @Test func createBranchTreatsOptionLookalikeStartPointAsRevision() async throws {
        let repo = try fixtures.cleanRepo()
        let canary = canaryPath()
        await #expect {
            try await self.client.createBranch("safe-name", at: "--output=\(canary)", in: repo.path)
        } throws: { _ in true }
        #expect(!FileManager.default.fileExists(atPath: canary))
    }

    @Test func addWorktreeTreatsOptionLookalikeBaseRefAsRef() async throws {
        let repo = try fixtures.cleanRepo()
        let canary = canaryPath()
        let destination = repo.path.deletingLastPathComponent()
            .appendingPathComponent("inject-wt")
        await #expect {
            try await self.client.addWorktree(
                at: destination, newBranch: "safe", from: "--output=\(canary)", in: repo.path)
        } throws: { _ in true }
        #expect(!FileManager.default.fileExists(atPath: canary), "worktree add ref leaked as option")
    }

    // MARK: A legitimate ref still works through the guards

    @Test func legitimateRefsStillResolveThroughGuards() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 2)
        // rev-parse, isAncestor, branch create all work with a normal ref.
        let head = try await client.revParse("HEAD", in: repo.path)
        #expect(head.count == 40)
        #expect(try await client.isAncestor("HEAD~1", of: "HEAD", in: repo.path))
        try await client.createBranch("feature-x", at: "main", in: repo.path)
        #expect(try await client.branchExists("feature-x", in: repo.path))
    }
}
