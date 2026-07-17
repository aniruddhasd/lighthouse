import Foundation
import Testing
import LighthouseFixtures
@testable import LighthouseGit

/// `fileContents` is a filesystem read behind a hard containment boundary.
/// Failure/edge cases first: path traversal and symlink escapes must be
/// refused (never returning outside-the-worktree bytes); binary and oversized
/// files report distinct states; a missing path throws cleanly. Then the
/// happy path: normal UTF-8 returned byte-exact.
@Suite("GitClient.fileContents (fixture repos)")
final class GitClientFileContentsTests {
    private let fixtures: FixtureFactory
    private let client = GitClient()

    init() throws { fixtures = try FixtureFactory() }
    deinit { try? fixtures.destroy() }

    // MARK: - Security: boundary escapes rejected

    @Test func pathTraversalToRealOutsideFileIsRejected() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 1)
        // Enough `..` to climb to filesystem root, then a file that really
        // exists outside the worktree. realpath resolves it; containment fails.
        let escape = String(repeating: "../", count: 20) + "etc/passwd"
        await #expect {
            _ = try await self.client.fileContents(worktree: repo.path, relativePath: escape)
        } throws: { error in
            guard case .pathOutsideWorktree = error as? GitClientError else { return false }
            return true
        }
    }

    @Test func symlinkEscapingTheWorktreeIsRejected() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 1)
        let link = repo.path.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: "/etc/passwd")
        await #expect {
            _ = try await self.client.fileContents(worktree: repo.path, relativePath: "escape-link")
        } throws: { error in
            guard case .pathOutsideWorktree = error as? GitClientError else { return false }
            return true
        }
    }

    @Test func absolutePathOutsideWorktreeIsRejected() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 1)
        await #expect {
            _ = try await self.client.fileContents(worktree: repo.path, relativePath: "/etc/passwd")
        } throws: { error in
            guard case .pathOutsideWorktree = error as? GitClientError else { return false }
            return true
        }
    }

    // MARK: - Edge: binary, too-large, missing, directory

    @Test func fileWithNulByteIsReportedBinary() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 1)
        try Data([0x48, 0x00, 0x49]).write(to: repo.path.appendingPathComponent("blob.bin"))
        #expect(try await client.fileContents(worktree: repo.path, relativePath: "blob.bin") == .binary)
    }

    @Test func fileOverTheCapIsReportedTooLargeWithItsSize() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 1)
        let overCap = 2 * 1024 * 1024 + 1
        try Data(repeating: 0x41, count: overCap).write(to: repo.path.appendingPathComponent("big.txt"))
        #expect(try await client.fileContents(worktree: repo.path, relativePath: "big.txt")
                == .tooLarge(bytes: overCap))
    }

    @Test func missingPathThrowsFileUnreadable() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 1)
        await #expect {
            _ = try await self.client.fileContents(worktree: repo.path, relativePath: "does-not-exist.txt")
        } throws: { error in
            guard case .fileUnreadable = error as? GitClientError else { return false }
            return true
        }
    }

    @Test func directoryPathThrowsFileUnreadable() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 1)
        try FileManager.default.createDirectory(
            at: repo.path.appendingPathComponent("subdir"), withIntermediateDirectories: true)
        await #expect {
            _ = try await self.client.fileContents(worktree: repo.path, relativePath: "subdir")
        } throws: { error in
            guard case .fileUnreadable = error as? GitClientError else { return false }
            return true
        }
    }

    // MARK: - Happy path

    @Test func normalUtf8FileIsReturnedByteExact() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 1)
        let content = "héllo\nworld\n☕ 汉字\n"
        try Data(content.utf8).write(to: repo.path.appendingPathComponent("text.txt"))
        #expect(try await client.fileContents(worktree: repo.path, relativePath: "text.txt")
                == .text(content))
    }

    @Test func fileInSubdirectoryInsideWorktreeIsAllowed() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 1)
        try FileManager.default.createDirectory(
            at: repo.path.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("let x = 1\n".utf8).write(to: repo.path.appendingPathComponent("src/a.swift"))
        #expect(try await client.fileContents(worktree: repo.path, relativePath: "src/a.swift")
                == .text("let x = 1\n"))
    }
}
