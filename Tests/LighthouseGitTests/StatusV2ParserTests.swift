import Foundation
import Testing
@testable import LighthouseGit

/// Pure-parser tests on synthetic porcelain v2 input (NUL-terminated, as
/// produced by `git status --porcelain=v2 --branch -z`). These cover fields
/// that are hard to provoke in a live offline fixture, e.g. ahead/behind.
@Suite("StatusV2Parser (synthetic input)")
struct StatusV2ParserTests {

    private func data(_ tokens: [String]) -> Data {
        Data(tokens.map { $0 + "\0" }.joined().utf8)
    }

    // MARK: Broken input first

    @Test func malformedLineThrows() {
        let input = data(["# branch.head main", "Z this is not a status line"])
        #expect(throws: GitClientError.self) {
            _ = try StatusV2Parser.parse(input)
        }
    }

    @Test func changedEntryWithMissingFieldsThrows() {
        let input = data(["# branch.head main", "1 M. N... 100644 100644"])
        #expect(throws: GitClientError.self) {
            _ = try StatusV2Parser.parse(input)
        }
    }

    @Test func renameEntryWithoutOriginalPathThrows() {
        let input = data([
            "# branch.head main",
            "2 R. N... 100644 100644 100644 aaaa bbbb R100 new.txt",
        ]).dropLast() // strip the final NUL so no origPath token follows
        #expect(throws: GitClientError.self) {
            _ = try StatusV2Parser.parse(Data(input))
        }
    }

    @Test func unknownConflictXYThrows() {
        let input = data([
            "# branch.head main",
            "u XX N... 100644 100644 100644 100644 a1 a2 a3 f.txt",
        ])
        #expect(throws: GitClientError.self) {
            _ = try StatusV2Parser.parse(input)
        }
    }

    @Test func missingBranchHeaderThrows() {
        let input = data(["? loose.txt"])
        #expect(throws: GitClientError.self) {
            _ = try StatusV2Parser.parse(input)
        }
    }

    @Test func malformedAheadBehindThrows() {
        let input = data(["# branch.head main", "# branch.ab plus2 minus1"])
        #expect(throws: GitClientError.self) {
            _ = try StatusV2Parser.parse(input)
        }
    }

    // MARK: Headers

    @Test func cleanBranchHeaders() throws {
        let status = try StatusV2Parser.parse(data([
            "# branch.oid 3ac7f2c2c1fd45f4a5e1c4ff5b6f7a8b9c0d1e2f",
            "# branch.head main",
        ]))
        #expect(status.head == .branch("main"))
        #expect(status.headObject == "3ac7f2c2c1fd45f4a5e1c4ff5b6f7a8b9c0d1e2f")
        #expect(status.isClean)
        #expect(!status.hasConflicts)
    }

    @Test func detachedHead() throws {
        let status = try StatusV2Parser.parse(data([
            "# branch.oid 3ac7f2c2c1fd45f4a5e1c4ff5b6f7a8b9c0d1e2f",
            "# branch.head (detached)",
        ]))
        #expect(status.head == .detached)
    }

    @Test func unbornBranch() throws {
        let status = try StatusV2Parser.parse(data([
            "# branch.oid (initial)",
            "# branch.head main",
        ]))
        #expect(status.head == .unborn("main"))
        #expect(status.headObject == nil)
    }

    @Test func aheadBehindCounts() throws {
        let status = try StatusV2Parser.parse(data([
            "# branch.oid 3ac7f2c2c1fd45f4a5e1c4ff5b6f7a8b9c0d1e2f",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +3 -2",
        ]))
        #expect(status.upstream == "origin/main")
        #expect(status.aheadBehind == AheadBehind(ahead: 3, behind: 2))
    }

    @Test func unknownHeadersAreIgnored() throws {
        let status = try StatusV2Parser.parse(data([
            "# branch.head main",
            "# stash 2",
            "# some.future.header with values",
        ]))
        #expect(status.head == .branch("main"))
    }

    // MARK: Entries

    @Test func ordinaryChangedEntries() throws {
        let status = try StatusV2Parser.parse(data([
            "# branch.head main",
            "1 M. N... 100644 100644 100644 aaaa bbbb staged.txt",
            "1 .M N... 100644 100644 100644 cccc cccc tracked.txt",
            "? untracked.txt",
        ]))
        #expect(status.stagedPaths == ["staged.txt"])
        #expect(status.unstagedPaths == ["tracked.txt"])
        #expect(status.untracked == ["untracked.txt"])
        #expect(!status.isClean)
    }

    @Test func pathsWithSpacesSurviveUnquoted() throws {
        // With -z, paths are printed as-is: no quoting to unescape.
        let status = try StatusV2Parser.parse(data([
            "# branch.head main",
            "1 .M N... 100644 100644 100644 aaaa aaaa my file with spaces.txt",
            "? another spaced file.txt",
        ]))
        #expect(status.changed.first?.path == "my file with spaces.txt")
        #expect(status.untracked == ["another spaced file.txt"])
    }

    @Test func renamedEntryReadsNULSeparatedOriginalPath() throws {
        let status = try StatusV2Parser.parse(data([
            "# branch.head main",
            "2 R. N... 100644 100644 100644 aaaa aaaa R100 new name.txt",
            "old name.txt",
        ]))
        let entry = try #require(status.renamed.first)
        #expect(entry.path == "new name.txt")
        #expect(entry.originalPath == "old name.txt")
        #expect(entry.score == "R100")
        #expect(entry.indexState == .renamed)
    }

    @Test(arguments: [
        ("DD", ConflictKind.bothDeleted),
        ("AU", ConflictKind.addedByUs),
        ("UD", ConflictKind.deletedByThem),
        ("UA", ConflictKind.addedByThem),
        ("DU", ConflictKind.deletedByUs),
        ("AA", ConflictKind.bothAdded),
        ("UU", ConflictKind.bothModified),
    ])
    func allSevenConflictKindsParse(xy: String, expected: ConflictKind) throws {
        let status = try StatusV2Parser.parse(data([
            "# branch.head main",
            "u \(xy) N... 100644 100644 100644 100644 a1a1 a2a2 a3a3 conflicted.txt",
        ]))
        let entry = try #require(status.unmerged.first)
        #expect(entry.kind == expected)
        #expect(entry.path == "conflicted.txt")
        #expect(status.hasConflicts)
    }

    @Test func deleteModifyClassification() {
        #expect(ConflictKind.deletedByUs.isDeleteModify)
        #expect(ConflictKind.deletedByThem.isDeleteModify)
        #expect(!ConflictKind.bothModified.isDeleteModify)
        #expect(!ConflictKind.bothDeleted.isDeleteModify)
    }

    @Test func unmergedEntryCarriesStageModesAndObjects() throws {
        let status = try StatusV2Parser.parse(data([
            "# branch.head main",
            "u UU N... 100644 100755 100644 100644 a1a1 a2a2 a3a3 f.txt",
        ]))
        let entry = try #require(status.unmerged.first)
        #expect(entry.stage1Mode == "100644")
        #expect(entry.stage2Mode == "100755")
        #expect(entry.stage3Mode == "100644")
        #expect(entry.worktreeMode == "100644")
        #expect(entry.stage1Object == "a1a1")
        #expect(entry.stage2Object == "a2a2")
        #expect(entry.stage3Object == "a3a3")
    }

    @Test func ignoredEntries() throws {
        let status = try StatusV2Parser.parse(data([
            "# branch.head main",
            "! build output.log",
        ]))
        #expect(status.ignored == ["build output.log"])
        #expect(status.isClean) // ignored files don't dirty the tree
    }
}
