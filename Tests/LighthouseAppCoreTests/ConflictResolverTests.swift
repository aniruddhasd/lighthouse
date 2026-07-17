import Foundation
import Testing
import LighthouseFixtures
import LighthouseGit
@testable import LighthouseAppCore

/// Resolver over real conflicted fixture repos. Proves binary and
/// delete/modify are classified from status/numstat (never text-parsed), and
/// that text resolutions stage a marker-free, byte-correct result.
@Suite("ConflictResolver (fixture repos)")
final class ConflictResolverTests {
    private let fixtures: FixtureFactory
    private let git = GitClient()
    private let resolver: ConflictResolver

    init() throws {
        fixtures = try FixtureFactory()
        resolver = ConflictResolver(git: GitClient())
    }

    deinit {
        try? fixtures.destroy()
    }

    /// Puts a fixture's clone into the paused-merge state (feature → main).
    private func startMerge(_ fixture: ConflictFixture) async throws {
        _ = try await git.merge(fixture.incomingBranch, in: fixture.repo.path)
    }

    // MARK: Classification

    @Test func textConflictClassifiedWithZdiff3Blocks() async throws {
        let fixture = try fixtures.contentConflictRepo()
        try await startMerge(fixture)
        // zdiff3 markers with base section.
        try await git.rematerializeConflict(path: fixture.conflictedPath, in: fixture.repo.path)

        let classified = try await resolver.classify(in: fixture.repo.path)
        #expect(classified.count == 1)
        guard case .text(let blocks) = classified[0].kind else {
            Issue.record("expected text, got \(classified[0].kind)"); return
        }
        #expect(blocks.count == 1)
        #expect(blocks[0].current.contains("main change"))
        #expect(blocks[0].incoming.contains("feature change"))
        #expect(blocks[0].base?.contains("common") == true) // zdiff3 base section
    }

    @Test func binaryConflictClassifiedBinaryNotTextParsed() async throws {
        let fixture = try fixtures.binaryConflictRepo()
        try await startMerge(fixture)
        let classified = try await resolver.classify(in: fixture.repo.path)
        #expect(classified.count == 1)
        #expect(classified[0].kind == .binary)
    }

    @Test func deleteModifyClassifiedNotTextParsed() async throws {
        let fixture = try fixtures.deleteModifyConflictRepo()
        try await startMerge(fixture)
        let classified = try await resolver.classify(in: fixture.repo.path)
        #expect(classified.count == 1)
        guard case .deleteModify = classified[0].kind else {
            Issue.record("expected deleteModify, got \(classified[0].kind)"); return
        }
    }

    // MARK: Resolution stages a clean result

    @Test func resolveTextPerBlockStagesMarkerFreeResult() async throws {
        let fixture = try fixtures.contentConflictRepo()
        try await startMerge(fixture)

        try await resolver.resolveText(
            path: fixture.conflictedPath,
            resolution: FileResolution(choices: [0: .incoming]),
            in: fixture.repo.path)

        // File has the incoming side, no markers, and is staged (no longer u).
        let content = try String(
            contentsOf: fixture.repo.path.appendingPathComponent(fixture.conflictedPath),
            encoding: .utf8)
        #expect(content.contains("feature change"))
        #expect(!content.contains("<<<<<<<"))
        let status = try await git.status(in: fixture.repo.path)
        #expect(status.unmerged.isEmpty)
        // A full merge --continue now succeeds.
        #expect(try await git.continueMerge(in: fixture.repo.path) == .merged)
    }

    @Test func resolveWholeFileTextOurs() async throws {
        let fixture = try fixtures.contentConflictRepo()
        try await startMerge(fixture)
        try await resolver.resolveWholeFileText(
            path: fixture.conflictedPath, side: .current, in: fixture.repo.path)
        let content = try String(
            contentsOf: fixture.repo.path.appendingPathComponent(fixture.conflictedPath),
            encoding: .utf8)
        #expect(content.contains("main change"))
        #expect(!content.contains("feature change"))
    }

    @Test func resolveBinaryTakesTheirsAndStages() async throws {
        let fixture = try fixtures.binaryConflictRepo()
        try await startMerge(fixture)
        try await resolver.resolveBinary(
            path: fixture.conflictedPath, side: .theirs, in: fixture.repo.path)
        let status = try await git.status(in: fixture.repo.path)
        #expect(status.unmerged.isEmpty)
        #expect(try await git.continueMerge(in: fixture.repo.path) == .merged)
    }

    @Test func resolveDeleteModifyKeepDeletedRemovesFile() async throws {
        let fixture = try fixtures.deleteModifyConflictRepo()
        try await startMerge(fixture)
        let classified = try await resolver.classify(in: fixture.repo.path)
        guard case .deleteModify(let modifiedSide) = classified[0].kind else {
            Issue.record("not deleteModify"); return
        }
        try await resolver.resolveDeleteModify(
            path: fixture.conflictedPath, keepModified: false,
            modifiedSide: modifiedSide, in: fixture.repo.path)
        #expect(try await git.continueMerge(in: fixture.repo.path) == .merged)
        // The file is gone (kept the deletion).
        #expect(!FileManager.default.fileExists(
            atPath: fixture.repo.path.appendingPathComponent(fixture.conflictedPath).path))
    }

    @Test func resolveDeleteModifyKeepModifiedRestoresContent() async throws {
        let fixture = try fixtures.deleteModifyConflictRepo()
        try await startMerge(fixture)
        let classified = try await resolver.classify(in: fixture.repo.path)
        guard case .deleteModify(let modifiedSide) = classified[0].kind else {
            Issue.record("not deleteModify"); return
        }
        try await resolver.resolveDeleteModify(
            path: fixture.conflictedPath, keepModified: true,
            modifiedSide: modifiedSide, in: fixture.repo.path)
        #expect(try await git.continueMerge(in: fixture.repo.path) == .merged)
        #expect(FileManager.default.fileExists(
            atPath: fixture.repo.path.appendingPathComponent(fixture.conflictedPath).path))
    }
}
