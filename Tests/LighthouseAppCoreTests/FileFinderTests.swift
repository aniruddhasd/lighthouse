import Foundation
import Testing
@testable import LighthouseAppCore

/// Ranking for the ⌘P quick-open. No-match and edge behaviour first, then the
/// ordering guarantees the UI relies on.
@Suite("FileFinder ranking")
struct FileFinderTests {
    private let paths = [
        "Sources/LighthouseAppCore/AppModel.swift",
        "Sources/LighthouseAppCore/NavigationState.swift",
        "Sources/LighthouseTaskEngine/Models.swift",
        "Sources/LighthouseApp/Views/FocusView.swift",
        "models/config.json",   // "model" hits the DIRECTORY, not the basename
        "README.md",
    ]

    // MARK: No-match

    @Test func nonSubsequenceQueryReturnsNothing() {
        #expect(FileFinder.rank(query: "zxqv", paths: paths).isEmpty)
    }

    // MARK: Basename beats path-only

    /// "model" is in the DIRECTORY segment of `models/config.json` (its basename
    /// `config.json` has no "model") and in the basenames `AppModel.swift` /
    /// `Models.swift`. The basename matches must rank above the directory-only
    /// one.
    @Test func basenameMatchOutranksDirectoryOnlyMatch() {
        let result = FileFinder.rank(query: "model", paths: paths)
        let dirOnly = "models/config.json"
        let dirIndex = result.firstIndex(of: dirOnly)
        #expect(dirIndex != nil)  // still a match — via the full path
        let appModelIndex = result.firstIndex(of: "Sources/LighthouseAppCore/AppModel.swift")!
        let modelsIndex = result.firstIndex(of: "Sources/LighthouseTaskEngine/Models.swift")!
        #expect(appModelIndex < dirIndex!)
        #expect(modelsIndex < dirIndex!)
    }

    /// Exact basename query surfaces that file at the very top.
    @Test func exactBasenameRanksFirst() {
        #expect(FileFinder.rank(query: "FocusView", paths: paths).first
            == "Sources/LighthouseApp/Views/FocusView.swift")
        #expect(FileFinder.rank(query: "readme", paths: paths).first == "README.md")
    }

    // MARK: Empty query + limit

    @Test func emptyQueryReturnsStablePrefix() {
        let all = FileFinder.rank(query: "", paths: paths, limit: 50)
        #expect(all.count == paths.count)
        // Deterministic: shortest path first, then lexicographic.
        #expect(all.first == "README.md")
        // Same input, same output — no dependence on call order.
        #expect(FileFinder.rank(query: "", paths: paths.reversed(), limit: 50) == all)
    }

    @Test func limitIsRespected() {
        #expect(FileFinder.rank(query: "", paths: paths, limit: 2).count == 2)
        #expect(FileFinder.rank(query: "s", paths: paths, limit: 3).count <= 3)
    }

    @Test func caseInsensitive() {
        #expect(FileFinder.rank(query: "APPMODEL", paths: paths).first
            == "Sources/LighthouseAppCore/AppModel.swift")
    }
}
