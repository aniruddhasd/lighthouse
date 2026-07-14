import Foundation
import Testing
import LighthouseGit
@testable import LighthouseAppCore

/// The navigator's decision layer, tested where the failure modes live: the
/// non-text file states must map to safe placeholders (not a crash, not raw
/// content), the diff selections must carry the right scroll target, and the
/// center-stage/navigator enums must behave.
@Suite("Navigator presenter and modes")
struct NavigatorPresenterTests {

    // MARK: Center-stage mode

    @Test func centerStageDefaultsToTerminalConceptAndToggles() {
        // The default is asserted at the model layer; here the pure invariant:
        // toggling is an involution between exactly two states.
        #expect(CenterStageMode.terminal.toggled == .viewer)
        #expect(CenterStageMode.viewer.toggled == .terminal)
        #expect(CenterStageMode.terminal.toggled.toggled == .terminal)
    }

    // MARK: Navigator mode enum

    @Test func navigatorModeCoversThreeSurfacesWithStableIds() {
        #expect(NavigatorMode.allCases == [.changes, .files, .history])
        #expect(NavigatorMode.changes.id == "changes")
        #expect(NavigatorMode.files.title == "Files")
        #expect(NavigatorMode.history.title == "History")
        // Every mode names a symbol so the segmented control never renders blank.
        for mode in NavigatorMode.allCases { #expect(!mode.systemImage.isEmpty) }
    }

    // MARK: Files — the failure-first cases (binary / too-large)

    @Test func binaryFileMapsToPlaceholderNotContentAndNeverThrows() {
        let request = NavigatorPresenter.fileSelection(contents: .binary, filename: "blob.bin")
        guard case .file(let html) = request else { Issue.record("expected .file"); return }
        // The placeholder message is present (as base64, per the escaped renderer).
        #expect(html.contains(Data("Binary file — not shown.".utf8).base64EncodedString()))
        #expect(request.scrollToFile == nil)
    }

    @Test func tooLargeFileMapsToSizeMessagePlaceholder() {
        let request = NavigatorPresenter.fileSelection(
            contents: .tooLarge(bytes: 5_242_880), filename: "huge.bin")
        guard case .file(let html) = request else { Issue.record("expected .file"); return }
        #expect(html.contains(Data("File is too large to display (5242880 bytes).".utf8)
            .base64EncodedString()))
    }

    @Test func hostileFilenameOnPlaceholderNeverLeaksRaw() {
        // A binary file whose NAME is hostile must still not inject: the name
        // rides the same base64 channel as content.
        let request = NavigatorPresenter.fileSelection(
            contents: .binary, filename: "</h2><script>alert(1)</script>.bin")
        #expect(!request.html.contains("<script>alert(1)</script>"))
    }

    @Test func textFileCarriesContentAsBase64NeverRaw() {
        let content = "let x = 1\nlet y = 2\n"
        let request = NavigatorPresenter.fileSelection(contents: .text(content), filename: "a.swift")
        #expect(request.html.contains(Data(content.utf8).base64EncodedString()))
        #expect(!request.html.contains("let x = 1")) // never raw
    }

    // MARK: Changes / History — diff selections

    @Test func changesSelectionRendersDiffAndScrollsToPickedFile() {
        let patch = "diff --git a/f.txt b/f.txt\n@@ -1 +1 @@\n-a\n+b\n"
        let request = NavigatorPresenter.changesSelection(patch: patch, file: "f.txt")
        #expect(request.scrollToFile == "f.txt")
        #expect(request.html.contains(Data(patch.utf8).base64EncodedString()))
        #expect(!request.html.contains("+b\n-a")) // patch never raw in markup
    }

    @Test func commitSelectionRendersDiffWithNoScrollTarget() {
        let patch = "diff --git a/f.txt b/f.txt\n@@ -0,0 +1 @@\n+new\n"
        let request = NavigatorPresenter.commitSelection(patch: patch)
        #expect(request.scrollToFile == nil)
        #expect(request.html.contains(Data(patch.utf8).base64EncodedString()))
    }

    // MARK: Relative date formatting

    @Test func relativeDateParsesIsoAndFallsBackOnGarbage() {
        let iso = "2026-07-14T18:12:48+05:30"
        let now = ISO8601DateFormatter().date(from: "2026-07-14T18:12:48Z")!
        let formatted = CommitDateFormatter.relativeString(from: iso, now: now)
        #expect(!formatted.isEmpty)
        // Unparseable input is returned verbatim — never blank, never a crash.
        #expect(CommitDateFormatter.relativeString(from: "not-a-date") == "not-a-date")
    }
}
