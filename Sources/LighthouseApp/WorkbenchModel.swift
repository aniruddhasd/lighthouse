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
    let webView: WKWebView
    private let renderDirectory: URL?
    private let navigationGate: LocalOnlyNavigationDelegate
    private(set) var renderError: String?
    /// True once any page has been loaded — the empty-viewer placeholder hides
    /// after the first selection.
    private(set) var hasContent = false

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
        self.webView = DiffWebViewFactory.makeWebView(
            renderDirectory: root, navigationGate: navigationGate)
    }

    /// Loads a viewer request; for a diff with a scroll target, scrolls to it
    /// once the page's bridge is installed.
    func apply(_ request: ViewerRequest) {
        guard let renderDirectory else { return }
        do {
            try DiffWebViewFactory.load(
                page: request.html, into: webView, renderDirectory: renderDirectory)
            hasContent = true
            renderError = nil
            if let file = request.scrollToFile { scrollTo(file: file) }
        } catch {
            renderError = String(describing: error)
        }
    }

    /// The diff page installs `window.lighthouseScrollToFile` after diff2html
    /// runs; the file load is async, so poll briefly for the bridge before
    /// calling it (a bare one-shot eval raced the load and silently no-opped).
    private func scrollTo(file path: String) {
        let encoded = Data(path.utf8).base64EncodedString()
        Task { @MainActor in
            for _ in 0..<40 {
                if await bridgeReady() {
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

    private func bridgeReady() async -> Bool {
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

    /// Center stage: terminal by default; a navigator selection swaps to the
    /// viewer, an explicit control/keystroke swaps back.
    var centerMode: CenterStageMode = .terminal
    var navigatorMode: NavigatorMode = .changes
    /// Per-task navigator visibility (UI-only; not persisted).
    var navigatorVisible = true

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

    func start() { review.start() }
    func stop() { review.stop() }

    // MARK: Center-stage swap

    func showViewer() { centerMode = .viewer }
    func showTerminal() { centerMode = .terminal }
    func toggleCenter() { centerMode = centerMode.toggled }

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

    /// Changes: render the whole live diff and scroll to the picked file.
    func selectChangedFile(_ path: String) async {
        await review.awaitRefresh()
        guard let patch = review.latestPatch else { return }
        viewer.apply(NavigatorPresenter.changesSelection(patch: patch, file: path))
        centerMode = .viewer
    }

    /// Files: render the picked file (binary/too-large → safe placeholders).
    func selectFile(_ path: String) async {
        guard let url = review.selectedWorktreeURL else { return }
        do {
            let contents = try await git.fileContents(worktree: url, relativePath: path)
            viewer.apply(NavigatorPresenter.fileSelection(contents: contents, filename: path))
        } catch {
            // A read fault (traversal, missing) becomes an escaped message page,
            // never a crash.
            viewer.apply(.file(html: FilePageBuilder.page(
                content: "Could not open \(path): \(error)", filename: path)))
        }
        centerMode = .viewer
    }

    /// History: render the picked commit's diff.
    func selectCommit(_ commit: CommitSummary) async {
        guard let url = review.selectedWorktreeURL else { return }
        do {
            let patch = try await git.commitDiff(worktree: url, hash: commit.hash)
            viewer.apply(NavigatorPresenter.commitSelection(patch: patch))
        } catch {
            viewer.apply(.file(html: FilePageBuilder.page(
                content: "Could not load commit \(commit.shortHash): \(error)",
                filename: commit.shortHash)))
        }
        centerMode = .viewer
    }
}
