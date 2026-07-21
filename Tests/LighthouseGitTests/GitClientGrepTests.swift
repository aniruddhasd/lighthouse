import Foundation
import Testing
import LighthouseFixtures
@testable import LighthouseGit

/// `git grep` for the ⌘F content search: text vs regex, case sensitivity, a
/// folder scope, binary skipping, and the "no matches" / bad-pattern edges.
@Suite("GitClient.grep (fixture repos)")
final class GitClientGrepTests {
    private let fixtures: FixtureFactory
    private let client = GitClient()

    init() throws { fixtures = try FixtureFactory() }
    deinit { try? fixtures.destroy() }

    /// Writes files, then commits them — git grep searches tracked content.
    private func seed(_ files: [String: String], in repo: URL) throws {
        for (path, content) in files {
            let url = repo.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        _ = try fixtures.git(["add", "-A"], in: repo)
        _ = try fixtures.git(["commit", "-m", "seed"], in: repo)
    }

    // MARK: - Edges first

    @Test func noMatchesReturnsEmptyNotError() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 1)
        let matches = try await client.grep(
            worktree: repo.path, pattern: "zzz-not-present", regex: false, caseSensitive: false)
        #expect(matches.isEmpty)
    }

    @Test func emptyPatternReturnsEmpty() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 1)
        let matches = try await client.grep(
            worktree: repo.path, pattern: "", regex: false, caseSensitive: false)
        #expect(matches.isEmpty)
    }

    @Test func invalidRegexThrows() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 1)
        try seed(["a.txt": "foo\n"], in: repo.path)
        await #expect(throws: GitClientError.self) {
            _ = try await self.client.grep(
                worktree: repo.path, pattern: "fo(", regex: true, caseSensitive: false)
        }
    }

    @Test func binaryFilesAreSkipped() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 1)
        // A NUL byte makes git treat the file as binary; -I must skip it.
        let bin = repo.path.appendingPathComponent("blob.bin")
        try Data([0x00, 0x66, 0x6f, 0x6f, 0x00]).write(to: bin)  // contains "foo" around NULs
        try seed(["text.txt": "foo here\n"], in: repo.path)

        let matches = try await client.grep(
            worktree: repo.path, pattern: "foo", regex: false, caseSensitive: false)
        #expect(matches.allSatisfy { $0.path != "blob.bin" })
        #expect(matches.contains { $0.path == "text.txt" })
    }

    // MARK: - Behaviour

    @Test func fixedStringMatchReportsPathLineAndText() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 1)
        try seed(["src/a.txt": "one\ntarget word\nthree\n"], in: repo.path)

        let matches = try await client.grep(
            worktree: repo.path, pattern: "target", regex: false, caseSensitive: false)
        let hit = try #require(matches.first { $0.path == "src/a.txt" })
        #expect(hit.line == 2)
        #expect(hit.text == "target word")
    }

    @Test func caseInsensitiveByRequestVsSensitive() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 1)
        try seed(["a.txt": "Foo\nbar\n"], in: repo.path)

        let insensitive = try await client.grep(
            worktree: repo.path, pattern: "foo", regex: false, caseSensitive: false)
        #expect(insensitive.contains { $0.path == "a.txt" && $0.line == 1 })

        let sensitive = try await client.grep(
            worktree: repo.path, pattern: "foo", regex: false, caseSensitive: true)
        #expect(sensitive.isEmpty)  // only "Foo" exists
    }

    @Test func regexMode() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 1)
        try seed(["a.txt": "color\ncolour\ncar\n"], in: repo.path)

        let matches = try await client.grep(
            worktree: repo.path, pattern: "colou?r", regex: true, caseSensitive: false)
        let lines = Set(matches.filter { $0.path == "a.txt" }.map(\.line))
        #expect(lines == [1, 2])  // color + colour, not car

        // The same pattern as a literal string matches nothing.
        let literal = try await client.grep(
            worktree: repo.path, pattern: "colou?r", regex: false, caseSensitive: false)
        #expect(literal.isEmpty)
    }

    @Test func folderScopeRestrictsResults() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 1)
        try seed([
            "inside/x.txt": "needle\n",
            "outside/y.txt": "needle\n",
        ], in: repo.path)

        let scoped = try await client.grep(
            worktree: repo.path, pattern: "needle", regex: false,
            caseSensitive: false, folder: "inside")
        #expect(scoped.contains { $0.path == "inside/x.txt" })
        #expect(scoped.allSatisfy { $0.path.hasPrefix("inside/") })
    }

    @Test func limitCapsResults() async throws {
        let repo = try fixtures.cleanRepo(commitCount: 1)
        let manyLines = (1...50).map { "hit line \($0)" }.joined(separator: "\n") + "\n"
        try seed(["big.txt": manyLines], in: repo.path)

        let matches = try await client.grep(
            worktree: repo.path, pattern: "hit", regex: false, caseSensitive: false, limit: 10)
        #expect(matches.count == 10)
    }

    // MARK: - Parser unit (delimiter discipline, no subprocess)

    @Test func parseGrepHandlesColonsAndSpacesInPathsAndText() {
        // path\0line\0text\n — a path with a colon and text with a colon must
        // both survive because only NULs delimit the first two fields.
        let raw = "dir:weird/a b.txt\u{0}12\u{0}let x = y:z\ndir/c.txt\u{0}3\u{0}plain\n"
        let matches = GitClient.parseGrep(Data(raw.utf8), limit: 500)
        #expect(matches.count == 2)
        #expect(matches[0] == GrepMatch(path: "dir:weird/a b.txt", line: 12, text: "let x = y:z"))
        #expect(matches[1] == GrepMatch(path: "dir/c.txt", line: 3, text: "plain"))
    }
}
