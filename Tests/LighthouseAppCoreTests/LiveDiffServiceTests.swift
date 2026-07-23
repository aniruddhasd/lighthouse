import Foundation
import Testing
import LighthouseFixtures
import LighthouseGit
@testable import LighthouseAppCore

@Suite("LiveDiffService (fixture repos)")
final class LiveDiffServiceTests {
    private let fixtures: FixtureFactory
    private let service = LiveDiffService(git: GitClient())

    init() throws {
        fixtures = try FixtureFactory()
    }

    deinit {
        try? fixtures.destroy()
    }

    private func taskBranchRepo() throws -> FixtureRepo {
        let repo = try fixtures.cleanRepo()
        try fixtures.git(["checkout", "-b", "task"], in: repo.path)
        return repo
    }

    @Test func mixedChangesPlusUntrackedAllAppear() async throws {
        let repo = try taskBranchRepo()
        try Data("committed\n".utf8).write(to: repo.path.appendingPathComponent("c.txt"))
        try fixtures.git(["add", "c.txt"], in: repo.path)
        try fixtures.git(["commit", "-m", "c"], in: repo.path)
        try Data("unstaged\n".utf8).write(to: repo.path.appendingPathComponent("notes.txt"))
        try Data("brand new\n".utf8).write(to: repo.path.appendingPathComponent("agent output.txt"))

        let diff = try await service.liveDiff(workspace: repo.path, baseBranch: "main")
        #expect(diff.patch.contains("+committed"))
        #expect(diff.patch.contains("+unstaged"))
        // Untracked rendered as an added-file patch (agents write without staging).
        #expect(diff.patch.contains("+brand new"))
        #expect(diff.patch.contains("agent output.txt"))
        #expect(diff.untracked == ["agent output.txt"])
        #expect(diff.entries.map(\.path).sorted() == ["c.txt", "notes.txt"])
    }

    @Test func binaryChangeSaysBinaryNotGarbage() async throws {
        let repo = try taskBranchRepo()
        try Data([0x00, 0x01, 0xFF]).write(to: repo.path.appendingPathComponent("blob.bin"))
        try fixtures.git(["add", "blob.bin"], in: repo.path)
        try fixtures.git(["commit", "-m", "bin"], in: repo.path)
        try Data([0x00, 0xEE, 0xDD, 0x00]).write(to: repo.path.appendingPathComponent("blob.bin"))

        let diff = try await service.liveDiff(workspace: repo.path, baseBranch: "main")
        #expect(diff.patch.contains("Binary files"))
        #expect(!diff.patch.contains("\u{0}"), "raw binary bytes leaked into the patch")
    }

    @Test func hugeUntrackedFileBecomesStubNotPayload() async throws {
        let repo = try taskBranchRepo()
        let huge = String(repeating: "A", count: LiveDiffService.maxFileSectionBytes + 100_000)
        try Data(huge.utf8).write(to: repo.path.appendingPathComponent("huge.log"))

        let diff = try await service.liveDiff(workspace: repo.path, baseBranch: "main")
        #expect(diff.patch.contains("render cap"))
        #expect(diff.patch.contains("huge.log"))
        #expect(diff.patch.utf8.count < 100_000, "cap did not bound the payload")
    }

    @Test func hugeTrackedChangeIsCappedPerFile() async throws {
        let repo = try taskBranchRepo()
        try Data("small\n".utf8).write(to: repo.path.appendingPathComponent("small.txt"))
        try fixtures.git(["add", "small.txt"], in: repo.path)
        let huge = String(repeating: "B", count: LiveDiffService.maxFileSectionBytes + 100_000)
        try Data(huge.utf8).write(to: repo.path.appendingPathComponent("notes.txt")) // tracked

        let diff = try await service.liveDiff(workspace: repo.path, baseBranch: "main")
        #expect(diff.patch.contains("+small"), "small file must survive the cap")
        #expect(diff.patch.contains("render cap"))
        #expect(diff.patch.utf8.count < LiveDiffService.maxFileSectionBytes)
    }

    @Test func cleanWorkspaceGivesEmptyDiff() async throws {
        let repo = try taskBranchRepo()
        let diff = try await service.liveDiff(workspace: repo.path, baseBranch: "main")
        #expect(diff.patch.isEmpty)
        #expect(diff.entries.isEmpty)
        #expect(diff.untracked.isEmpty)
    }

    /// The whole point of the scope toggle: uncommitted shows only working-tree
    /// changes (+ untracked), NOT committed branch work — which vs-base includes.
    @Test func uncommittedScopeExcludesCommittedBranchWork() async throws {
        let repo = try taskBranchRepo()
        // A tracked file that exists in HEAD.
        try Data("v1\n".utf8).write(to: repo.path.appendingPathComponent("tracked.txt"))
        try fixtures.git(["add", "tracked.txt"], in: repo.path)
        try fixtures.git(["commit", "-m", "add tracked"], in: repo.path)
        // Committed branch work — in "vs base", NOT in "uncommitted".
        try Data("committed\n".utf8).write(to: repo.path.appendingPathComponent("committed.txt"))
        try fixtures.git(["add", "committed.txt"], in: repo.path)
        try fixtures.git(["commit", "-m", "committed work"], in: repo.path)
        // Uncommitted: modify the tracked file + add an untracked one.
        try Data("v2\n".utf8).write(to: repo.path.appendingPathComponent("tracked.txt"))
        try Data("new\n".utf8).write(to: repo.path.appendingPathComponent("untracked.txt"))

        let uncommitted = try await service.uncommittedDiff(workspace: repo.path)
        #expect(uncommitted.entries.map(\.path) == ["tracked.txt"]) // committed.txt absent
        #expect(uncommitted.untracked == ["untracked.txt"])
        #expect(uncommitted.patch.contains("+v2"))
        #expect(uncommitted.patch.contains("+new"))
        #expect(!uncommitted.patch.contains("+committed"))

        // vs base still carries the committed branch work.
        let vsBase = try await service.diff(
            workspace: repo.path, baseBranch: "main", scope: .vsBase)
        #expect(vsBase.entries.map(\.path).sorted() == ["committed.txt", "tracked.txt"])
        #expect(vsBase.patch.contains("+committed"))
    }
}
