import Foundation
import Observation
import WebKit
import LighthouseAppCore
import LighthouseGit
import LighthouseTaskEngine

/// Owns the single center content-viewer WKWebView plus its load/scroll bridge.
/// One per task; it renders EITHER a diff page or a file page (Phase B: one
/// viewer in the center, not a diff webview buried in a side pane). The
/// lockdown is identical to the diff/conflict panes — a `LocalOnlyNavigation`
/// gate and a render directory holding the vendored diff2html assets (which the
/// file page simply does not reference).
@MainActor @Observable
final class ContentViewerModel {
    /// The live viewer WKWebView — nil ONLY under the unit-test harness. See
    /// `skipWebViewUnderTest`: `swift test` has no NSApplication run loop, so
    /// WebKit's web-content XPC handshake intermittently wedges when many
    /// WKWebViews are created in parallel, deadlocking the whole suite at 0% CPU.
    /// Unit tests assert this model's OBSERVABLE state (hasContent / renderError
    /// / body mode), never real rendering; the DIFFRENDER / FILERENDER runtime
    /// gates exercise the REAL WKWebView in the actual app. So under XCTest we
    /// skip WebKit entirely — the app never hits this path (the env var below is
    /// set only by the test runner, and is absent in the shipped binary and the
    /// gate launches).
    let webView: WKWebView?
    private let renderDirectory: URL?
    private let navigationGate: LocalOnlyNavigationDelegate
    private(set) var renderError: String?
    /// True once any page has been loaded — the empty-viewer placeholder hides
    /// after the first selection.
    private(set) var hasContent = false

    /// Set by XCTest/swift-testing runners, never by the app or the runtime
    /// gates (which launch the real binary). The single seam that keeps live
    /// WebKit out of the headless unit-test process.
    static let skipWebViewUnderTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        var directory: URL?
        do {
            directory = try DiffWebViewFactory.makeRenderDirectory()
        } catch {
            renderError = "Content renderer assets unavailable: \(error)"
        }
        self.renderDirectory = directory
        let root = directory ?? FileManager.default.temporaryDirectory
        self.navigationGate = LocalOnlyNavigationDelegate(allowedRoot: root)
        self.webView = Self.skipWebViewUnderTest
            ? nil
            : DiffWebViewFactory.makeWebView(renderDirectory: root, navigationGate: navigationGate)
    }

    /// Loads a viewer request; for a diff with a scroll target, scrolls to it
    /// once the page's bridge is installed.
    func apply(_ request: ViewerRequest) {
        guard let renderDirectory else { return }
        // No WKWebView under the test harness: still record the observable state
        // the tests assert (a page's content is present, prior error cleared) —
        // the successful-load outcome, without touching WebKit.
        guard let webView else {
            hasContent = true
            renderError = nil
            return
        }
        do {
            try DiffWebViewFactory.load(
                page: request.html, into: webView, renderDirectory: renderDirectory)
            hasContent = true
            renderError = nil
            if let file = request.scrollToFile { scrollTo(file: file, in: webView) }
            if let line = request.scrollToLine { scrollTo(line: line, in: webView) }
            // Hand keyboard focus to the viewer so arrow keys / page-up-down
            // scroll the freshly opened content without a click first — the
            // ⌘P/⌘F flows dismiss their palette and would otherwise leave focus
            // nowhere. Deferred one runloop so the palette has torn down and the
            // web view is in the window's responder chain.
            DispatchQueue.main.async { webView.window?.makeFirstResponder(webView) }
        } catch {
            renderError = String(describing: error)
        }
    }

    /// The file page installs `window.lighthouseScrollToLine` at the end of its
    /// bootstrap; poll briefly for it (same race as the diff bridge) before
    /// asking it to scroll to and highlight the ⌘F target line.
    private func scrollTo(line: Int, in webView: WKWebView) {
        Task { @MainActor in
            for _ in 0..<40 {
                let ready = await Self.functionReady("lighthouseScrollToLine", in: webView)
                if ready {
                    webView.evaluateJavaScript(
                        "window.lighthouseScrollToLine(\(line))", completionHandler: nil)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Scroll the ALREADY-loaded file page to `line` without reloading — used by
    /// repeated in-file ⌘F jumps, where reloading the same page would race the
    /// scroll bridge (the outgoing page answers the poll, then the reload snaps
    /// back to the top). The bridge is already installed, so this lands cleanly.
    func scrollToLine(_ line: Int) {
        guard let webView else { return }
        scrollTo(line: line, in: webView)
        // Same focus hand-off as a full load, so arrow keys scroll the file
        // immediately after an in-file ⌘F jump without a click first.
        DispatchQueue.main.async { webView.window?.makeFirstResponder(webView) }
    }

    /// Scroll the ALREADY-loaded changes diff to `path` without reloading — used
    /// when a second changed file is picked from the tree. The whole diff is one
    /// page, so reloading it to show a different file both wastes work and races
    /// the scroll bridge back to the first file (the "clicking a file jumps to
    /// the top" bug). Same no-reload fix as `scrollToLine`.
    func scrollToFile(_ path: String) {
        guard let webView else { return }
        scrollTo(file: path, in: webView)
        DispatchQueue.main.async { webView.window?.makeFirstResponder(webView) }
    }

    private static func functionReady(_ name: String, in webView: WKWebView) async -> Bool {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(
                "typeof window.\(name) === 'function'"
            ) { value, _ in continuation.resume(returning: (value as? Bool) ?? false) }
        }
    }

    /// The diff page installs `window.lighthouseScrollToFile` after diff2html
    /// runs; the file load is async, so poll briefly for the bridge before
    /// calling it (a bare one-shot eval raced the load and silently no-opped).
    private func scrollTo(file path: String, in webView: WKWebView) {
        let encoded = Data(path.utf8).base64EncodedString()
        Task { @MainActor in
            for _ in 0..<40 {
                if await Self.bridgeReady(in: webView) {
                    // Callback overload (nil handler) — in this async context the
                    // bare form resolves to the `async throws` overload.
                    webView.evaluateJavaScript(
                        "window.lighthouseScrollToFile('\(encoded)')", completionHandler: nil)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private static func bridgeReady(in webView: WKWebView) async -> Bool {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(
                "typeof window.lighthouseScrollToFile === 'function'"
            ) { value, _ in continuation.resume(returning: (value as? Bool) ?? false) }
        }
    }
}

/// Per-task workbench: the observable brain behind the detail layout. It ties
/// the live-diff engine (Changes + watcher), the lazy Files/History surfaces,
/// the single center viewer, and the two view-modes (center stage, navigator)
/// together, and turns a navigator selection into a viewer render + a swap to
/// the viewer. All decision logic lives here (SwiftUI layout is not headlessly
/// testable — documented scar), so the NAVIGATOR gate and unit tests drive it
/// directly.
@MainActor @Observable
final class WorkbenchModel {
    let task: TaskRecord
    let review: ReviewPaneModel
    let viewer = ContentViewerModel()

    /// The Focus center body (spec §3.4): the persistent Terminal/Summary mode
    /// plus the transient file-viewer overlay that wins when active. All the
    /// transition rules live in the pure `FocusBodyState`; this model just holds
    /// it and exposes intent-named mutators the views/keystrokes call.
    var bodyState = FocusBodyState()
    var navigatorMode: NavigatorMode = .changes
    /// Per-task navigator visibility (UI-only; not persisted). The navigator is
    /// now an on-demand overlay (spec §5.2), so it starts CLOSED — the terminal
    /// is the full-bleed hero until the user opens it (◨ / ⌘\). Its transitions
    /// also drive the live-diff refresh cadence: while it's closed nobody is
    /// watching the changed-file tree, so the diff pipeline runs on the slow
    /// background debounce and stops competing with terminal drawing.
    var navigatorVisible = false {
        didSet {
            guard oldValue != navigatorVisible else { return }
            review.setForeground(navigatorVisible)
        }
    }

    /// The pane the body actually shows — the ZStack renders exactly this.
    var effectiveBody: FocusBody { bodyState.effective }

    /// The path/label of the current viewer selection, for the viewer header
    /// (spec §5.2). Real (the selected path / short hash), never fabricated.
    private(set) var viewerTitle: String?

    /// Repo-relative path of the file currently shown in the viewer, or nil when
    /// the viewer holds something that is not a single file (a commit diff, or
    /// nothing yet). Drives ⌘F's in-file search scope.
    private(set) var currentFilePath: String?

    // MARK: File editing (simple native editor)

    /// The current viewer content is a single editable text file (set by
    /// `selectFile`; false for diffs, binaries, too-large files).
    private(set) var currentFileEditable = false
    /// In edit mode: the read-only page is replaced by a native text editor.
    private(set) var isEditing = false
    /// The editable buffer (bound by the editor view).
    var editText = ""
    /// File contents as loaded into the editor — the baseline for Cancel and for
    /// the on-disk staleness check at save time.
    private var editBaseline = ""
    private(set) var editError: String?
    /// The file changed on disk (e.g. the agent edited it) since editing began —
    /// Save shows an Overwrite/Reload choice instead of clobbering silently.
    private(set) var editConflict = false

    /// Whether the Edit affordance should show for the current viewer content.
    var canEditCurrentFile: Bool {
        currentFileEditable && currentFilePath != nil && !isEditing
    }

    // Files surface (browser tree, lazy).
    private(set) var files: [FileTreeNode] = []
    private(set) var filesError: String?
    private var filesLoaded = false
    /// Session-only collapse state for the Files browser tree (separate from
    /// the changed-files tree's expansion).
    var filesExpansion = TreeExpansionState()

    // History surface (commit list, lazy).
    private(set) var commits: [CommitSummary] = []
    private(set) var historyError: String?
    private var historyLoaded = false

    private let git: GitClient

    init(task: TaskRecord, repos: [RepoConfig], git: GitClient) {
        self.task = task
        self.git = git
        self.review = ReviewPaneModel(task: task, repos: repos, git: git)
        self.review.onSelectionChanged = { [weak self] in self?.repoChanged() }
    }

    // MARK: Lifecycle (delegates to the live-diff engine)

    func start() {
        review.start()
        // Match cadence to current visibility — the navigator starts closed, so
        // the initial (one-shot) populate still runs, then bursts go slow until
        // it's opened.
        review.setForeground(navigatorVisible)
    }
    func stop() { review.stop() }

    /// Re-syncs the review pane after a workspace was added to this task while
    /// the workbench is live (add-repo-to-task), so the new repo appears in the
    /// picker without recreating the workbench.
    func syncTask(_ task: TaskRecord, repos: [RepoConfig]) {
        review.syncWorkspaces(task: task, repos: repos)
    }

    // MARK: Center body (spec §3.4 — rules live in FocusBodyState)

    /// The Terminal/Summary segmented control. Switching mode clears any active
    /// viewer (a mode switch exits the viewer).
    func setBodyMode(_ mode: BodyMode) { bodyState.setMode(mode) }

    /// ⌘J / the viewer's Terminal button: close the viewer, return to whichever
    /// mode was active (Focus-only; the keystroke is gated to Focus).
    func showTerminal() { bodyState.closeViewer() }
    func closeViewer() { bodyState.closeViewer() }

    // MARK: Repo (workspace) selection — shared across all three surfaces

    var selectedWorkspaceIndex: Int {
        get { review.selectedWorkspaceIndex }
        set { review.selectedWorkspaceIndex = newValue } // fires repoChanged() via callback
    }

    private func repoChanged() {
        filesLoaded = false; files = []; filesError = nil
        filesExpansion = TreeExpansionState()
        historyLoaded = false; commits = []; historyError = nil
        ensureLoaded(for: navigatorMode)
    }

    // MARK: Files-tree expansion (mutating helpers so the recursive row's
    // closures can drive session collapse state on this reference type).

    func isFileExpanded(_ id: String) -> Bool { filesExpansion.isExpanded(id) }
    func setFileExpanded(_ expanded: Bool, _ id: String) {
        filesExpansion.setExpanded(expanded, for: id)
    }

    // MARK: Lazy surface loading

    func ensureLoaded(for mode: NavigatorMode) {
        switch mode {
        case .changes: break // driven by the live watcher, always running
        case .files: if !filesLoaded { Task { await loadFiles() } }
        case .history: if !historyLoaded { Task { await loadHistory() } }
        }
    }

    /// Flat, tracked-plus-untracked path list for the ⌘P finder — fetched fresh
    /// each open (cheap `git ls-files`) so a just-created file is findable. An
    /// I/O fault yields an empty list, never a crash.
    func fileFinderPaths() async -> [String] {
        guard let url = review.selectedWorktreeURL else { return [] }
        return (try? await git.listFiles(worktree: url)) ?? []
    }

    /// ⌘F content search over the active worktree (tracked files). Throws on a
    /// bad pattern / missing folder so the overlay can show git's reason; an
    /// empty pattern or no worktree yields no matches.
    func contentSearch(pattern: String, regex: Bool, folder: String?) async throws -> [GrepMatch] {
        guard let url = review.selectedWorktreeURL else { return [] }
        return try await git.grep(
            worktree: url, pattern: pattern, regex: regex,
            caseSensitive: false, folder: folder)
    }

    /// Local branches of the selected repo — the candidate list for the base
    /// picker in the Summary tab. Loaded lazily; empty on failure.
    private(set) var availableBranches: [String] = []
    /// The branch the selected worktree is currently on (its HEAD), for display
    /// in the Summary tab. nil when detached or unknown.
    private(set) var worktreeBranch: String?

    /// Loads the base-picker candidates AND the worktree's current branch — the
    /// branch names the Summary tab shows. Cheap; safe to call on appear.
    func loadBranchInfo() async {
        guard let url = review.selectedWorktreeURL else {
            availableBranches = []; worktreeBranch = nil; return
        }
        availableBranches = await git.listBranches(in: url)
        worktreeBranch = try? await git.currentBranch(in: url)
    }

    /// Sets the diff base branch for the selected workspace: updates the live
    /// diff and persists the per-task override through the model (survives a
    /// relaunch). `persist` receives the selected workspace's repo id.
    func setBase(_ base: String?, persist: (_ repoId: UUID, _ base: String?) -> Void) {
        let repoId = review.selectedRepoId
        review.setBase(base)
        if let repoId { persist(repoId, base) }
    }

    func loadFiles() async {
        guard let url = review.selectedWorktreeURL else { return }
        filesLoaded = true
        do {
            let paths = try await git.listFiles(worktree: url)
            files = FileTreeBuilder.build(paths: paths)
            filesError = nil
        } catch {
            filesError = String(describing: error)
            files = []
        }
    }

    func loadHistory(limit: Int = 100) async {
        guard let url = review.selectedWorktreeURL else { return }
        historyLoaded = true
        do {
            commits = try await git.commitLog(worktree: url, limit: limit)
            historyError = nil
        } catch {
            historyError = String(describing: error)
            commits = []
        }
    }

    // MARK: Selection → center viewer (async I/O here, pure mapping in the
    // presenter). Each selection promotes the viewer into the center stage.

    /// The changes-diff patch currently rendered in the viewer, if any. When the
    /// next file pick is within this same diff, we scroll rather than reload —
    /// the whole diff is one page (see `scrollToFile`). Cleared whenever the
    /// viewer loads something else (a file page, a commit diff).
    private var shownChangesPatch: String?

    /// Changes: render the whole live diff and scroll to the picked file. If the
    /// diff for the current patch is already showing, just scroll to the file —
    /// no reload — so picking files doesn't snap back to the top.
    func selectChangedFile(_ path: String) async {
        exitEditing()
        currentFileEditable = false // a diff is not an editable single file
        await review.awaitRefresh()
        guard let patch = review.latestPatch else { return }
        if shownChangesPatch == patch {
            viewer.scrollToFile(path)
        } else {
            viewer.apply(NavigatorPresenter.changesSelection(patch: patch, file: path))
            shownChangesPatch = patch
        }
        viewerTitle = path
        currentFilePath = path
        bodyState.activateViewer()
    }

    /// Files: render the picked file (binary/too-large → safe placeholders).
    /// `line`, when set (the ⌘F content-search jump), scrolls to and highlights
    /// that 1-based line once the page loads.
    func selectFile(_ path: String, line: Int? = nil) async {
        guard let url = review.selectedWorktreeURL else { return }
        // Already showing this file (repeated in-file ⌘F jump): just scroll —
        // reloading the identical page races the scroll bridge back to the top.
        if path == currentFilePath, let line {
            viewer.scrollToLine(line)
            bodyState.activateViewer()
            return
        }
        exitEditing()
        do {
            let contents = try await git.fileContents(worktree: url, relativePath: path)
            // Only a real text file is editable — not binaries or oversized files.
            if case .text = contents { currentFileEditable = true } else { currentFileEditable = false }
            viewer.apply(NavigatorPresenter.fileSelection(
                contents: contents, filename: path, scrollToLine: line))
        } catch {
            currentFileEditable = false
            // A read fault (traversal, missing) becomes an escaped message page,
            // never a crash.
            viewer.apply(.file(html: FilePageBuilder.page(
                content: "Could not open \(path): \(error)", filename: path), scrollToLine: nil))
        }
        viewerTitle = path
        currentFilePath = path
        shownChangesPatch = nil  // the viewer now holds a file, not the diff
        bodyState.activateViewer()
    }

    /// History: render the picked commit's diff.
    func selectCommit(_ commit: CommitSummary) async {
        exitEditing()
        currentFileEditable = false // a commit diff is not an editable file
        guard let url = review.selectedWorktreeURL else { return }
        do {
            let patch = try await git.commitDiff(worktree: url, hash: commit.hash)
            viewer.apply(NavigatorPresenter.commitSelection(patch: patch))
        } catch {
            viewer.apply(.file(html: FilePageBuilder.page(
                content: "Could not load commit \(commit.shortHash): \(error)",
                filename: commit.shortHash), scrollToLine: nil))
        }
        viewerTitle = commit.shortHash
        currentFilePath = nil  // a commit diff is not a single file
        shownChangesPatch = nil  // a commit diff is not the changes diff
        bodyState.activateViewer()
    }

    // MARK: File editing

    /// Enter edit mode for the current file: re-read it fresh from disk (so the
    /// editor starts from the current bytes) and swap in the native editor.
    func beginEditing() async {
        guard let path = currentFilePath, let url = review.selectedWorktreeURL else { return }
        do {
            guard case .text(let contents) = try await git.fileContents(
                worktree: url, relativePath: path) else {
                editError = "This file can't be edited here."
                return
            }
            editText = contents
            editBaseline = contents
            editError = nil
            editConflict = false
            isEditing = true
        } catch {
            editError = "Could not open \(path) for editing: \(error)"
        }
    }

    /// Save the buffer to disk. If the file changed underneath us (the agent
    /// touched it), surface a conflict instead of clobbering — the view then
    /// offers Overwrite / Reload.
    func saveEdits() async {
        guard isEditing, let path = currentFilePath, let url = review.selectedWorktreeURL else { return }
        // Staleness: compare the current on-disk bytes to what we loaded.
        if case .text(let onDisk) = try? await git.fileContents(worktree: url, relativePath: path),
           onDisk != editBaseline {
            editConflict = true
            return
        }
        await writeAndExit(path: path, url: url)
    }

    /// Overwrite despite an on-disk change (the conflict banner's choice).
    func overwriteEdits() async {
        guard isEditing, let path = currentFilePath, let url = review.selectedWorktreeURL else { return }
        await writeAndExit(path: path, url: url)
    }

    /// Discard local edits and reload the file's current on-disk contents into
    /// the editor (the conflict banner's other choice).
    func reloadForEditing() async {
        editConflict = false
        await beginEditing()
    }

    private func writeAndExit(path: String, url: URL) async {
        do {
            try await git.writeFile(worktree: url, relativePath: path, contents: editText)
            editConflict = false
            exitEditing()
            // Re-render the (now saved) file so the read-only viewer is current;
            // the live-diff watcher also picks the change up on its own.
            await selectFile(path)
        } catch {
            editError = "Could not save \(path): \(error)"
        }
    }

    /// Leave edit mode without saving (Cancel, or any new selection).
    func exitEditing() {
        isEditing = false
        editText = ""
        editBaseline = ""
        editError = nil
        editConflict = false
    }
}
