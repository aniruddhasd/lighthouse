import Foundation
import Testing
@testable import LighthouseGit

/// Pure tests for the `diff --name-status -z` record parser, covering shapes
/// that are awkward to provoke deterministically live (rename scores).
@Suite("name-status parser (synthetic input)")
struct NameStatusParserTests {

    private func data(_ tokens: [String]) -> Data {
        Data(tokens.map { $0 + "\0" }.joined().utf8)
    }

    @Test func statusWithoutPathThrows() {
        #expect(throws: GitClientError.self) {
            _ = try GitClient.parseNameStatus(Data("M\0".utf8))
        }
    }

    @Test func renameMissingTargetThrows() {
        #expect(throws: GitClientError.self) {
            _ = try GitClient.parseNameStatus(data(["R100", "only-source.txt"]))
        }
    }

    @Test func emptyDiffYieldsNoEntries() throws {
        #expect(try GitClient.parseNameStatus(Data()) == [])
    }

    @Test func mixedRecordsIncludingRenameAndSpaces() throws {
        let entries = try GitClient.parseNameStatus(data([
            "A", "added file.txt",
            "M", "changed.txt",
            "D", "removed.txt",
            "R087", "old place.txt", "new place.txt",
        ]))
        #expect(entries == [
            DiffEntry(change: .added, path: "added file.txt"),
            DiffEntry(change: .modified, path: "changed.txt"),
            DiffEntry(change: .deleted, path: "removed.txt"),
            DiffEntry(change: .renamed(score: 87), path: "new place.txt", originalPath: "old place.txt"),
        ])
    }

    @Test func unknownStatusLetterIsCarriedVerbatim() throws {
        let entries = try GitClient.parseNameStatus(data(["X", "weird.txt"]))
        #expect(entries == [DiffEntry(change: .other("X"), path: "weird.txt")])
    }
}
