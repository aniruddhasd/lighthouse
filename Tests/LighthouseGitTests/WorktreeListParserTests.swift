import Foundation
import Testing
@testable import LighthouseGit

/// Pure-parser tests on synthetic `worktree list --porcelain -z` input,
/// mirroring the record shapes documented in git-worktree(1) (git 2.50.1),
/// including states hard to provoke live (bare, locked, prunable).
@Suite("WorktreeListParser (synthetic input)")
struct WorktreeListParserTests {

    private func data(_ tokens: [String]) -> Data {
        Data(tokens.map { $0 + "\0" }.joined().utf8)
    }

    // MARK: Broken input first

    @Test func attributeBeforeAnyRecordThrows() {
        let input = data(["HEAD abcd1234", "", "worktree /some/path"])
        #expect(throws: GitClientError.self) {
            _ = try WorktreeListParser.parse(input)
        }
    }

    @Test func worktreeLabelWithoutPathThrows() {
        let input = data(["worktree", ""])
        #expect(throws: GitClientError.self) {
            _ = try WorktreeListParser.parse(input)
        }
    }

    @Test func emptyOutputYieldsNoWorktrees() throws {
        #expect(try WorktreeListParser.parse(Data()) == [])
    }

    // MARK: Documented record shapes

    @Test func fullDocumentedExampleParses() throws {
        // The exact example from git-worktree(1), NUL-terminated.
        let input = data([
            "worktree /path/to/bare-source",
            "bare",
            "",
            "worktree /path/to/linked-worktree",
            "HEAD abcd1234abcd1234abcd1234abcd1234abcd1234",
            "branch refs/heads/master",
            "",
            "worktree /path/to/other-linked-worktree",
            "HEAD 1234abc1234abc1234abc1234abc1234abc1234a",
            "detached",
            "",
            "worktree /path/to/linked-worktree-locked-no-reason",
            "HEAD 5678abc5678abc5678abc5678abc5678abc5678c",
            "branch refs/heads/locked-no-reason",
            "locked",
            "",
            "worktree /path/to/linked-worktree-locked-with-reason",
            "HEAD 3456def3456def3456def3456def3456def3456b",
            "branch refs/heads/locked-with-reason",
            "locked reason why is locked",
            "",
            "worktree /path/to/linked-worktree-prunable",
            "HEAD 1233def1234def1234def1234def1234def1234b",
            "detached",
            "prunable gitdir file points to non-existent location",
            "",
        ])
        let worktrees = try WorktreeListParser.parse(input)
        #expect(worktrees.count == 6)

        #expect(worktrees[0].path == "/path/to/bare-source")
        #expect(worktrees[0].isBare)
        #expect(worktrees[0].headObject == nil)

        #expect(worktrees[1].branch == "refs/heads/master")
        #expect(worktrees[1].branchShortName == "master")
        #expect(worktrees[1].headObject == "abcd1234abcd1234abcd1234abcd1234abcd1234")

        #expect(worktrees[2].isDetached)
        #expect(worktrees[2].branch == nil)

        #expect(worktrees[3].isLocked)
        #expect(worktrees[3].lockReason == nil)

        #expect(worktrees[4].isLocked)
        #expect(worktrees[4].lockReason == "reason why is locked")

        #expect(worktrees[5].isPrunable)
        #expect(worktrees[5].prunableReason == "gitdir file points to non-existent location")
    }

    @Test func pathsWithSpacesSurvive() throws {
        let input = data([
            "worktree /path/with spaces/repo with spaces",
            "HEAD abcd1234abcd1234abcd1234abcd1234abcd1234",
            "branch refs/heads/main",
            "",
        ])
        let worktrees = try WorktreeListParser.parse(input)
        #expect(worktrees.first?.path == "/path/with spaces/repo with spaces")
    }

    @Test func unknownAttributesAreTolerated() throws {
        let input = data([
            "worktree /path/to/wt",
            "HEAD abcd1234abcd1234abcd1234abcd1234abcd1234",
            "branch refs/heads/main",
            "some-future-attribute with a value",
            "",
        ])
        let worktrees = try WorktreeListParser.parse(input)
        #expect(worktrees.count == 1)
        #expect(worktrees.first?.branchShortName == "main")
    }
}
