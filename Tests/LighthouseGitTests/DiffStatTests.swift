import Foundation
import Testing
import LighthouseFixtures
@testable import LighthouseGit

/// The deterministic diff counts: the pure numstat parser (failure/edge cases
/// first), then `GitClient.diffStat` end-to-end on a real fixture with a known
/// add/del/files.
@Suite("DiffStat parsing + GitClient.diffStat")
final class DiffStatTests {
    private let fixtures: FixtureFactory
    private let client = GitClient()

    init() throws { fixtures = try FixtureFactory() }
    deinit { try? fixtures.destroy() }

    // MARK: Parser — failure & edge cases first

    @Test func emptyOutputIsKnownZero() {
        #expect(DiffStat.parse(numstat: "") == .zero)
        #expect(DiffStat.parse(numstat: "\n\n") == .zero)
    }

    @Test func binaryLineCountsTheFileButZeroLines() {
        // A binary file prints `-\t-\t<path>`: one changed file, no line counts.
        let stat = DiffStat.parse(numstat: "-\t-\timage.png\n")
        #expect(stat == DiffStat(filesChanged: 1, added: 0, deleted: 0))
    }

    @Test func binaryAndTextMix() {
        let stat = DiffStat.parse(numstat: "5\t2\tsrc.swift\n-\t-\tlogo.png\n")
        #expect(stat == DiffStat(filesChanged: 2, added: 5, deleted: 2))
    }

    @Test func renameIsOneFileWithItsCounts() {
        // `git diff --numstat` renders a rename on ONE line; the path field
        // carries `{old => new}` (or `old => new`) — irrelevant to counting.
        let stat = DiffStat.parse(numstat: "3\t1\t{old => new}/file.txt\n")
        #expect(stat == DiffStat(filesChanged: 1, added: 3, deleted: 1))
    }

    @Test func zeroChangeRecordCountsTheFile() {
        // A mode-only change is `0\t0\t<path>` — a changed file with no lines.
        let stat = DiffStat.parse(numstat: "0\t0\texecutable.sh\n")
        #expect(stat == DiffStat(filesChanged: 1, added: 0, deleted: 0))
    }

    @Test func multipleRecordsSum() {
        let stat = DiffStat.parse(numstat: "2\t0\ta.txt\n0\t1\tb.txt\n1\t0\tc.txt\n")
        #expect(stat == DiffStat(filesChanged: 3, added: 3, deleted: 1))
    }

    @Test func pathWithSpacesIsOneRecord() {
        // maxSplits keeps the path (with spaces/tabs) intact as the third field.
        let stat = DiffStat.parse(numstat: "4\t2\tnew file here.txt\n")
        #expect(stat == DiffStat(filesChanged: 1, added: 4, deleted: 2))
    }

    @Test func malformedLinesAreSkippedNotCrashed() {
        // A line without the two count fields + a path is not a record.
        let stat = DiffStat.parse(numstat: "garbage\n5\t3\treal.txt\nonly\tone\n")
        #expect(stat == DiffStat(filesChanged: 1, added: 5, deleted: 3))
    }

    // MARK: GitClient.diffStat — exact on a real fixture

    @Test func diffStatExactOnKnownFixture() async throws {
        // Base commit on main carries f.txt + g.txt (3 lines each). Working
        // tree then: f.txt +2 (append), g.txt -1 (delete a line), h.txt +1
        // (new, staged). merge-base(main, HEAD==main) is that commit, so the
        // diff is exactly those working changes.
        let repo = try fixtures.cleanRepo()
        try Data("1\n2\n3\n".utf8).write(to: repo.path.appendingPathComponent("f.txt"))
        try Data("1\n2\n3\n".utf8).write(to: repo.path.appendingPathComponent("g.txt"))
        try fixtures.git(["add", "f.txt", "g.txt"], in: repo.path)
        try fixtures.git(["commit", "-m", "setup"], in: repo.path)

        try Data("1\n2\n3\n4\n5\n".utf8).write(to: repo.path.appendingPathComponent("f.txt")) // +2
        try Data("1\n2\n".utf8).write(to: repo.path.appendingPathComponent("g.txt"))           // -1
        try Data("hello\n".utf8).write(to: repo.path.appendingPathComponent("h.txt"))          // new
        try fixtures.git(["add", "h.txt"], in: repo.path)

        let stat = try await client.diffStat(worktree: repo.path, base: "main")
        #expect(stat == DiffStat(filesChanged: 3, added: 3, deleted: 1))
    }

    @Test func diffStatIsKnownZeroWhenNoChanges() async throws {
        let repo = try fixtures.cleanRepo()
        let stat = try await client.diffStat(worktree: repo.path, base: "main")
        #expect(stat == .zero)
    }

    @Test func diffStatOnNonRepoThrowsTyped() async throws {
        let dir = try fixtures.nonRepoDirectory()
        await #expect {
            _ = try await self.client.diffStat(worktree: dir, base: "main")
        } throws: { error in
            switch error as? GitClientError {
            case .commandFailed, .notARepository: return true
            default: return false
            }
        }
    }
}
