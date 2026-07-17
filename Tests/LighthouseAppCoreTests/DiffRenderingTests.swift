import Foundation
import Testing
import LighthouseGit
@testable import LighthouseAppCore

/// The builder is where untrusted repo content meets HTML: no byte of the
/// diff may appear raw in the page. (The end-to-end DOM proof lives in the
/// DIFFRENDER gate; these tests pin the builder's output shape.)
@Suite("DiffPageBuilder security and shape")
struct DiffPageBuilderTests {

    @Test func hostileContentNeverAppearsRawInHTML() {
        let page = DiffPageBuilder.page(diff: DiffPageBuilder.hostileFixtureDiff)
        // The raw attack strings must be absent from the page source...
        #expect(!page.contains("<script>window.__pwned=true</script>"))
        #expect(!page.contains("onerror=\"window.__pwned=true\""))
        #expect(!page.contains("onclick=\"window.__pwned=true\""))
        #expect(!page.contains("nonce=steal"))
        // ...while the payload IS present, as base64.
        let payload = Data(DiffPageBuilder.hostileFixtureDiff.utf8).base64EncodedString()
        #expect(page.contains(payload))
    }

    @Test func everyByteOfAnyDiffIsBase64Contained() {
        // Property over a nasty corpus: nothing from the diff text leaks
        // into the page outside the base64 blob.
        let corpus = ["</script><script>alert(1)</script>", "\"'`${}\\", "\u{0}\u{7}",
                      "]]><!--", "<iframe src=x>", "😈<style>*{display:none}</style>"]
        for hostile in corpus {
            let diff = "diff --git a/x b/x\n+++ b/x\n@@ -0,0 +1 @@\n+\(hostile)\n"
            let page = DiffPageBuilder.page(diff: diff)
            #expect(!page.contains(hostile), "leaked raw: \(hostile)")
        }
    }

    @Test func cspForbidsAllNetworkSources() {
        let page = DiffPageBuilder.page(diff: "x")
        #expect(page.contains("Content-Security-Policy"))
        #expect(page.contains("default-src 'none'"))
        #expect(!page.contains("http://"), "no network URLs in the page")
        #expect(!page.contains("https://"))
    }

    @Test func scriptsAreLocalAssetPlusNoncedBootstrapOnly() {
        let page = DiffPageBuilder.page(diff: "x")
        #expect(page.contains("<script src=\"diff2html.min.js\"></script>"))
        #expect(page.contains("script-src 'self' 'nonce-"))
        // Nonces differ between builds (no replayable inline script).
        let again = DiffPageBuilder.page(diff: "x")
        func nonce(_ html: String) -> String? {
            html.components(separatedBy: "'nonce-").dropFirst().first?
                .components(separatedBy: "'").first
        }
        #expect(nonce(page) != nonce(again))
    }
}

@Suite("PatchCapper")
struct PatchCapperTests {

    @Test func underCapPassesThroughByteExact() {
        let patch = "diff --git a/a b/a\n+++ b/a\n@@ -0,0 +1 @@\n+hello\n"
        #expect(PatchCapper.cappingFileSections(of: patch, at: 500) == patch)
    }

    @Test func oversizedSectionReplacedOthersUntouched() {
        let small = "diff --git a/small.txt b/small.txt\n+++ b/small.txt\n@@ -0,0 +1 @@\n+ok\n"
        let huge = "diff --git a/huge.txt b/huge.txt\n+++ b/huge.txt\n@@ -0,0 +1 @@\n+"
            + String(repeating: "x", count: 2000) + "\n"
        let capped = PatchCapper.cappingFileSections(of: small + huge, at: 500)
        #expect(capped.contains("+ok"))
        #expect(!capped.contains(String(repeating: "x", count: 2000)))
        #expect(capped.contains("render cap"))
        #expect(capped.contains("huge.txt")) // stub names the file
    }

    @Test func emptyPatchStaysEmpty() {
        #expect(PatchCapper.cappingFileSections(of: "", at: 100) == "")
    }
}

@Suite("FileTreeBuilder")
struct FileTreeBuilderTests {

    @Test func emptyInputsGiveEmptyTree() {
        #expect(FileTreeBuilder.build(entries: [], untracked: []).isEmpty)
    }

    @Test func groupsByDirectoryDirsFirstThenFilesSorted() {
        let entries = [
            DiffEntry(change: .modified, path: "src/deep/z.swift"),
            DiffEntry(change: .added, path: "src/a.swift"),
            DiffEntry(change: .deleted, path: "README.md"),
        ]
        let tree = FileTreeBuilder.build(entries: entries, untracked: ["src/new file.swift"])

        #expect(tree.map(\.name) == ["src", "README.md"]) // dir before file
        let src = tree[0]
        #expect(src.children?.map(\.name) == ["deep", "a.swift", "new file.swift"])
        let statuses = Dictionary(uniqueKeysWithValues:
            (src.children ?? []).compactMap { node in node.status.map { (node.name, $0) } })
        #expect(statuses["a.swift"] == "A")
        #expect(statuses["new file.swift"] == "?")
        #expect(tree[1].status == "D")
    }

    @Test func untrackedAlreadyTrackedIsNotDuplicated() {
        let entries = [DiffEntry(change: .added, path: "x.txt")]
        let tree = FileTreeBuilder.build(entries: entries, untracked: ["x.txt"])
        #expect(tree.count == 1)
        #expect(tree[0].status == "A")
    }

    @Test func renameShowsTargetPath() {
        let entries = [DiffEntry(change: .renamed(score: 90), path: "new/name.txt",
                                 originalPath: "old/name.txt")]
        let tree = FileTreeBuilder.build(entries: entries, untracked: [])
        #expect(tree[0].name == "new")
        #expect(tree[0].children?[0].status == "R")
    }

    @Test func recursiveFileCountForNestedDirs() {
        // src/{a.swift, deep/{x.ts, y.ts}}, __tests__/t.test.tsx
        let entries = [
            DiffEntry(change: .modified, path: "src/a.swift"),
            DiffEntry(change: .added, path: "src/deep/x.ts"),
            DiffEntry(change: .added, path: "src/deep/y.ts"),
            DiffEntry(change: .added, path: "__tests__/t.test.tsx"),
        ]
        let tree = FileTreeBuilder.build(entries: entries, untracked: [])
        let byName = Dictionary(uniqueKeysWithValues: tree.map { ($0.name, $0) })
        #expect(byName["__tests__"]?.fileCount == 1) // the collapsed-dir badge case
        #expect(byName["src"]?.fileCount == 3)        // a.swift + deep/{x,y}
        let deep = byName["src"]?.children?.first { $0.name == "deep" }
        #expect(deep?.fileCount == 2)
        // Files count as 1.
        #expect(byName["src"]?.children?.first { $0.name == "a.swift" }?.fileCount == 1)
    }

    @Test func directoryIDsListsEveryNestedDir() {
        let entries = [DiffEntry(change: .added, path: "src/deep/x.ts")]
        let tree = FileTreeBuilder.build(entries: entries, untracked: [])
        let ids = Set(tree.flatMap { $0.directoryIDs() })
        #expect(ids == ["src/", "src/deep/"])
    }
}

@Suite("TreeExpansionState")
struct TreeExpansionStateTests {

    @Test func directoriesAreExpandedByDefault() {
        let state = TreeExpansionState()
        #expect(state.isExpanded("src/"))
        #expect(state.isExpanded("anything/"))
        #expect(state.collapsedIDs.isEmpty)
    }

    @Test func collapseAndToggleTrackOnlyExplicitFolds() {
        var state = TreeExpansionState()
        state.setExpanded(false, for: "__tests__/")
        #expect(!state.isExpanded("__tests__/"))
        #expect(state.isExpanded("src/"))
        state.toggle("__tests__/")
        #expect(state.isExpanded("__tests__/"))
        state.toggle("src/")
        #expect(!state.isExpanded("src/"))
    }

    @Test func collapseStateSurvivesRebuildWithSamePaths() {
        // The user collapses a dir; the diff regenerates with the same dirs;
        // prune must NOT re-expand it.
        var state = TreeExpansionState()
        state.setExpanded(false, for: "__tests__/")
        state.prune(toDirectoryIDs: ["src/", "__tests__/", "src/deep/"])
        #expect(!state.isExpanded("__tests__/"), "user's collapse was lost on rebuild")
        #expect(state.isExpanded("src/"))
    }

    @Test func collapseStateDropsForDisappearedPaths() {
        var state = TreeExpansionState()
        state.setExpanded(false, for: "old-dir/")
        state.setExpanded(false, for: "__tests__/")
        // old-dir/ no longer in the diff.
        state.prune(toDirectoryIDs: ["__tests__/", "src/"])
        #expect(state.collapsedIDs == ["__tests__/"])
        // A brand-new dir at the same name later starts expanded (no stale state).
        #expect(state.isExpanded("old-dir/"))
    }
}

@Suite("DiffRefresher")
struct DiffRefresherTests {
    /// Counts invocations; each run holds for `holdMs` to simulate slow diffs.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func eventStormCoalescesToOneRun() async throws {
        let counter = Counter()
        let refresher = DiffRefresher(interval: .milliseconds(80)) {
            counter.increment()
        }
        for _ in 0..<200 {
            await refresher.noteChange()
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(counter.count == 1, "storm produced \(counter.count) runs")
    }

    @Test func eventsDuringARunProduceExactlyOneFollowUp() async throws {
        let counter = Counter()
        let refresher = DiffRefresher(interval: .milliseconds(30)) {
            counter.increment() // counts at ENTRY, then holds: a slow diff
            try? await Task.sleep(for: .milliseconds(250))
        }
        await refresher.noteChange()
        // Poll until the first run has actually ENTERED (fixed sleeps race
        // task scheduling under parallel test load).
        for _ in 0..<100 where counter.count == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(counter.count == 1)
        for _ in 0..<50 {
            await refresher.noteChange() // storm mid-run
        }
        try await Task.sleep(for: .milliseconds(900))
        #expect(counter.count == 2, "latest-wins violated: \(counter.count) runs")
    }

    @Test func stopCancelsPendingWork() async throws {
        let counter = Counter()
        let refresher = DiffRefresher(interval: .milliseconds(100)) {
            counter.increment()
        }
        await refresher.noteChange()
        await refresher.stop()
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.count == 0)
        await refresher.noteChange() // after stop: inert
        try await Task.sleep(for: .milliseconds(200))
        #expect(counter.count == 0)
    }

    @Test func refreshNowRunsWithoutDebounceDelay() async throws {
        let counter = Counter()
        let refresher = DiffRefresher(interval: .seconds(5)) {
            counter.increment()
        }
        await refresher.refreshNow()
        #expect(counter.count == 1) // did not wait 5s
    }
}

@Suite("ConflictPageBuilder security")
struct ConflictPageBuilderTests {

    @Test func hostileBlockContentNeverAppearsRawInHTML() {
        let page = ConflictPageBuilder.page(path: "evil.txt", blocks: ConflictPageBuilder.hostileBlocks)
        #expect(!page.contains("<script>window.__pwned=true</script>"))
        #expect(!page.contains("onerror=\"window.__pwned=true\""))
        #expect(!page.contains("nonce=steal"))
        // Content is present only inside the base64 payload.
        #expect(page.contains("default-src 'none'"))
        #expect(!page.contains("http://"))
        #expect(!page.contains("https://"))
    }

    @Test func pathIsAlsoBase64NotRaw() {
        let page = ConflictPageBuilder.page(
            path: "</h2><script>alert(1)</script>", blocks: [])
        #expect(!page.contains("<script>alert(1)</script>"))
    }

    @Test func nonceDiffersPerBuild() {
        func nonce(_ html: String) -> String? {
            html.components(separatedBy: "'nonce-").dropFirst().first?
                .components(separatedBy: "'").first
        }
        #expect(nonce(ConflictPageBuilder.page(path: "a", blocks: []))
                != nonce(ConflictPageBuilder.page(path: "a", blocks: [])))
    }
}
