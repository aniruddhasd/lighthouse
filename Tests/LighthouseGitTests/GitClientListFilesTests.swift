import Foundation
import Testing
import LighthouseFixtures
@testable import LighthouseGit

/// `listFiles` must be gitignore-aware and delimiter-safe: ignored trees are
/// absent, untracked-but-not-ignored files are present, tracked files are
/// present, and a filename containing a space survives the NUL parse.
@Suite("GitClient.listFiles (fixture repos)")
final class GitClientListFilesTests {
    private let fixtures: FixtureFactory
    private let client = GitClient()

    init() throws { fixtures = try FixtureFactory() }
    deinit { try? fixtures.destroy() }

    private func write(_ relativePath: String, _ content: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    @Test func ignoredTreeExcludedTrackedAndUntrackedIncludedSpacesSurvive() async throws {
        // cleanRepo leaves one tracked, committed file: notes.txt.
        let repo = try fixtures.cleanRepo(commitCount: 1)
        try write(".gitignore", "node_modules/\n", in: repo.path)
        try write("node_modules/lib.js", "ignored\n", in: repo.path)   // ignored dir
        try write("src/app.js", "untracked\n", in: repo.path)          // untracked, not ignored
        try write("with space.txt", "spaced\n", in: repo.path)         // NUL-delimiter proof

        let files = Set(try await client.listFiles(worktree: repo.path))

        #expect(files.contains("notes.txt"), "tracked file missing")
        #expect(files.contains(".gitignore"))
        #expect(files.contains("src/app.js"), "untracked non-ignored file missing")
        #expect(files.contains("with space.txt"), "filename with space lost")
        #expect(!files.contains(where: { $0.hasPrefix("node_modules/") }), "ignored tree leaked")
    }

    @Test func emptyRepoWithNoFilesYieldsEmptyList() async throws {
        let repo = try fixtures.emptyRepo()
        #expect(try await client.listFiles(worktree: repo.path).isEmpty)
    }
}
