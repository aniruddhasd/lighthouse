import Foundation
import Testing
@testable import LighthouseAppCore

/// The `build(paths:)` overload builds a plain repo file tree (no status
/// glyphs) from a flat path list — a browser, not a review surface. Same
/// grouping, sorting, and recursive counts as the changed-files tree.
@Suite("FileTreeBuilder.build(paths:)")
struct FileTreeBuilderPathsTests {

    @Test func emptyInputGivesEmptyTree() {
        #expect(FileTreeBuilder.build(paths: []).isEmpty)
    }

    @Test func groupsByDirectoryDirsFirstThenFilesSortedNoStatus() {
        let tree = FileTreeBuilder.build(paths: [
            "src/deep/z.swift", "src/a.swift", "README.md", "with space.txt",
        ])
        // Directories before files, each alphabetical.
        #expect(tree.map(\.name) == ["src", "README.md", "with space.txt"])
        // Files carry no status glyph in browse mode.
        #expect(tree[1].status == nil)
        #expect(tree[2].status == nil)
        let src = tree[0]
        #expect(src.status == nil) // directories never had one
        #expect(src.children?.map(\.name) == ["deep", "a.swift"])
        #expect(src.children?.first { $0.name == "a.swift" }?.status == nil)
    }

    @Test func recursiveFileCountMatchesNestedFiles() {
        let tree = FileTreeBuilder.build(paths: [
            "src/a.swift", "src/deep/x.ts", "src/deep/y.ts", "top.txt",
        ])
        let byName = Dictionary(uniqueKeysWithValues: tree.map { ($0.name, $0) })
        #expect(byName["src"]?.fileCount == 3)
        #expect(byName["top.txt"]?.fileCount == 1)
        let deep = byName["src"]?.children?.first { $0.name == "deep" }
        #expect(deep?.fileCount == 2)
    }

    @Test func directoryIDsAreDistinctFromFileIDs() {
        let tree = FileTreeBuilder.build(paths: ["src/deep/x.ts"])
        let ids = Set(tree.flatMap { $0.directoryIDs() })
        #expect(ids == ["src/", "src/deep/"])
    }
}
