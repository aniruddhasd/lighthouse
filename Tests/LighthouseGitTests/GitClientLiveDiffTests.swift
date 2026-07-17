import Foundation
import Testing
import LighthouseFixtures
@testable import LighthouseGit

/// The live-diff invocation (`git diff --merge-base <base> --`): committed +
/// staged + unstaged relative to the merge base, base-side commits excluded,
/// untracked separate.
@Suite("GitClient live diff (fixture repos)")
final class GitClientLiveDiffTests {
    private let fixtures: FixtureFactory
    private let client = GitClient()

    init() throws {
        fixtures = try FixtureFactory()
    }

    deinit {
        try? fixtures.destroy()
    }

    /// Repo with a task branch holding one committed, one staged, one
    /// unstaged change while main moved ahead independently.
    private func mixedRepo() throws -> FixtureRepo {
        let repo = try fixtures.cleanRepo()
        try fixtures.git(["checkout", "-b", "task"], in: repo.path)
        try Data("committed change\n".utf8).write(to: repo.path.appendingPathComponent("committed.txt"))
        try fixtures.git(["add", "committed.txt"], in: repo.path)
        try fixtures.git(["commit", "-m", "committed"], in: repo.path)
        // Base moves on AFTER branching — must not appear in the live diff.
        try fixtures.git(["checkout", "main"], in: repo.path)
        try Data("base moved\n".utf8).write(to: repo.path.appendingPathComponent("base-moved.txt"))
        try fixtures.git(["add", "base-moved.txt"], in: repo.path)
        try fixtures.git(["commit", "-m", "base moved"], in: repo.path)
        try fixtures.git(["checkout", "task"], in: repo.path)
        // Staged + unstaged on the task side.
        try Data("staged change\n".utf8).write(to: repo.path.appendingPathComponent("staged.txt"))
        try fixtures.git(["add", "staged.txt"], in: repo.path)
        try Data("unstaged line\n".utf8).write(
            to: repo.path.appendingPathComponent("notes.txt")) // tracked, modified, unstaged
        return repo
    }

    // MARK: Broken/edge cases first

    @Test func liveDiffOnNonRepoThrowsTyped() async throws {
        // Outside a repo, `git diff` switches to implicit no-index mode and
        // rejects --merge-base as an unknown option (exit 129) — so the
        // typed error is commandFailed, not notARepository. Loud either way.
        let dir = try fixtures.nonRepoDirectory()
        await #expect {
            _ = try await self.client.liveDiff(againstMergeBaseOf: "main", in: dir)
        } throws: { error in
            switch error as? GitClientError {
            case .commandFailed, .notARepository: return true
            default: return false
            }
        }
    }

    @Test func emptyDiffIsEmptyString() async throws {
        let repo = try fixtures.cleanRepo()
        try fixtures.git(["checkout", "-b", "task"], in: repo.path)
        let patch = try await client.liveDiff(againstMergeBaseOf: "main", in: repo.path)
        #expect(patch.isEmpty)
        let entries = try await client.liveDiffNameStatus(againstMergeBaseOf: "main", in: repo.path)
        #expect(entries.isEmpty)
    }

    @Test func untrackedPatchForBinaryFileSaysBinaryNotGarbage() async throws {
        let repo = try fixtures.cleanRepo()
        try Data([0x00, 0xFF, 0x00, 0x10]).write(to: repo.path.appendingPathComponent("blob.bin"))
        let patch = try await client.untrackedFilePatch(for: "blob.bin", in: repo.path)
        #expect(patch.contains("Binary files"))
        #expect(patch.contains("blob.bin"))
    }

    @Test func untrackedPatchHandlesSpacesInPath() async throws {
        let repo = try fixtures.cleanRepo()
        try Data("hello\n".utf8).write(to: repo.path.appendingPathComponent("new file here.txt"))
        let patch = try await client.untrackedFilePatch(for: "new file here.txt", in: repo.path)
        #expect(patch.contains("new file here.txt"))
        #expect(patch.contains("+hello"))
    }

    // MARK: The live semantics

    @Test func liveDiffCoversCommittedStagedAndUnstaged() async throws {
        let repo = try mixedRepo()
        let patch = try await client.liveDiff(againstMergeBaseOf: "main", in: repo.path)
        #expect(patch.contains("+committed change"))
        #expect(patch.contains("+staged change"))
        #expect(patch.contains("+unstaged line"))
        // Base-side commits are NOT the task's changes.
        #expect(!patch.contains("base-moved"))
    }

    @Test func liveNameStatusMatchesThePatch() async throws {
        let repo = try mixedRepo()
        let entries = try await client.liveDiffNameStatus(againstMergeBaseOf: "main", in: repo.path)
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0.change) })
        #expect(byPath["committed.txt"] == .added)
        #expect(byPath["staged.txt"] == .added)
        #expect(byPath["notes.txt"] == .modified)
        #expect(byPath["base-moved.txt"] == nil)
    }
}
