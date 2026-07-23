import SwiftUI
import LighthouseAppCore
import LighthouseGit
import LighthouseTaskEngine

/// Per-(task, repo) live-diff engine: owns the FSEvents watcher, the debounced
/// refresher, and the diff pipeline; publishes the changed-files tree, the
/// counts, and the latest patch. It does NOT own a WKWebView any more — the
/// rendered diff now targets the shared center content viewer (Phase B). The
/// watcher/tree/counts self-heal on every (re)start and on FSEvents, per the
/// watcher-lifecycle contract below.
///
/// Recreated when the task changes (the workbench that owns it has identity
/// `.id(task.id)`); the watcher swaps when the repo selection changes;
/// everything stops when the workbench disappears.
@MainActor @Observable
final class ReviewPaneModel {
    /// Snapshotted at creation; `syncWorkspaces` re-reads them after an
    /// "add repo to task" so the picker and diffs pick up the new workspace
    /// without tearing down the whole workbench.
    private(set) var task: TaskRecord
    private(set) var repos: [RepoConfig]
    private let service: LiveDiffService

    var selectedWorkspaceIndex = 0 {
        didSet {
            guard oldValue != selectedWorkspaceIndex else { return }
            restartForSelection()
            onSelectionChanged?()
        }
    }
    /// Invoked after the repo selection changes and the watcher has restarted,
    /// so the owner can reload the other navigator surfaces (Files/History) for
    /// the newly-selected repo. nil in headless tests that drive this directly.
    var onSelectionChanged: (@MainActor () -> Void)?

    private(set) var tree: [FileTreeNode] = []
    private(set) var untrackedCount = 0
    /// Number of changed (tracked) files in the latest diff — the value the
    /// user sees as the file count; asserted by tests and the REVIEWPANE gate.
    private(set) var changedFileCount = 0
    /// The most recent unified patch (diff vs merge base). Consumed by the
    /// workbench to render the diff into the center viewer when a changed file
    /// is picked; nil until the first successful refresh.
    private(set) var latestPatch: String?
    /// Session-only per-(task,repo) directory collapse state; directories are
    /// expanded by default.
    var expansion = TreeExpansionState()
    private(set) var renderError: String?

    /// Which changes to show. Defaults to uncommitted ("what changed right
    /// now"); flipping it re-reads the diff so the tree + patch follow the
    /// scope. Bound directly by the navigator's Uncommitted | vs base toggle.
    var scope: DiffScope = .uncommitted {
        didSet {
            guard oldValue != scope else { return }
            refreshNow()
        }
    }

    private var watcher: FileSystemWatcher?
    private var refresher: DiffRefresher?
    /// Whether the review surface is currently on screen. Remembered (not just
    /// pushed to the refresher) so a refresher recreated by a repo switch
    /// (`restartForSelection`) is born at the right cadence, not the default.
    private var isForeground = false
    /// The most recent refresh task — awaitable by tests so assertions don't
    /// poll on wall-clock (which flakes under parallel-suite contention).
    private(set) var lastRefreshTask: Task<Void, Never>?

    init(task: TaskRecord, repos: [RepoConfig], git: GitClient) {
        self.task = task
        self.repos = repos
        self.git = git
        self.service = LiveDiffService(git: git)
    }

    var workspaces: [(index: Int, workspace: Workspace, repoName: String)] {
        task.workspaces.enumerated().map { index, workspace in
            let name = repos.first { $0.id == workspace.repoId }
                .map { $0.pathURL.lastPathComponent } ?? "repo"
            return (index, workspace, name)
        }
    }

    private var selectedWorkspace: Workspace? {
        task.workspaces.indices.contains(selectedWorkspaceIndex)
            ? task.workspaces[selectedWorkspaceIndex] : nil
    }

    /// Worktree of the currently-selected repo — the root the Files and History
    /// navigator surfaces read from, shared with the diff watcher.
    var selectedWorktreeURL: URL? { selectedWorkspace?.worktreeURL }

    private var selectedBaseBranch: String? {
        guard let workspace = selectedWorkspace else { return nil }
        return repos.first { $0.id == workspace.repoId }?.baseBranch
    }

    private let git: GitClient

    // MARK: - Lifecycle (workbench visible ⇔ watcher running)

    /// Idempotently sets up the watcher (worktree + gitdir) if needed, and
    /// ALWAYS triggers an immediate unconditional refresh. Every entry point
    /// — workbench appear, task/repo switch, scenePhase foreground — goes
    /// through here, so a diff missed while the watcher was stopped
    /// (backgrounded) or a change FSEvents never saw self-heals on the next
    /// (re)start (2026-07-13). Refresh does not depend on the watcher existing.
    func start() {
        guard let workspace = selectedWorkspace else { return }
        if refresher == nil {
            // Born at the remembered cadence so a repo switch while the
            // navigator is closed stays on the slow background debounce.
            let interval = isForeground
                ? DiffRefresher.defaultDebounce : DiffRefresher.backgroundDebounce
            let refresher = DiffRefresher(interval: interval) {
                [weak self] in await self?.regenerate()
            }
            self.refresher = refresher
        }
        let refresher = self.refresher!
        if watcher == nil {
            // Watch the worktree AND its per-worktree gitdir (for commits
            // that touch no worktree file). The gitdir resolves async; the
            // immediate refresh below does not wait for it.
            let worktreePath = workspace.worktreePath
            Task { [weak self] in
                var paths = [worktreePath]
                if let gitdir = try? await self?.git.gitDirectory(
                    in: URL(fileURLWithPath: worktreePath, isDirectory: true)) {
                    paths.append(gitdir.path)
                }
                guard let self, self.watcher == nil else { return }
                self.watcher = FileSystemWatcher(paths: paths) {
                    Task { await refresher.noteChange() }
                }
            }
        }
        lastRefreshTask = Task { await refresher.refreshNow() }
    }

    /// Switches the refresh cadence to match whether the review surface is
    /// actually on screen. Hidden → slow (background) debounce, so the diff
    /// pipeline stops stealing main-thread cycles from terminal drawing while
    /// the user types heads-down. Visible → fast debounce AND an immediate
    /// refresh, so a just-revealed tree is current rather than up to a
    /// background-interval stale. No-op before `start()` creates the refresher;
    /// `start()` re-applies the current visibility itself.
    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        let refresher = self.refresher
        let interval = foreground
            ? DiffRefresher.defaultDebounce : DiffRefresher.backgroundDebounce
        Task { await refresher?.setInterval(interval) }
        if foreground { refreshNow() }
    }

    /// Manual refresh (header button / Cmd+R) — belt-and-braces for any
    /// missed-event window we haven't imagined.
    func refreshNow() {
        guard let refresher else { start(); return }
        lastRefreshTask = Task { await refresher.refreshNow() }
    }

    /// Re-reads the task/repos after a workspace was added elsewhere
    /// (add-repo-to-task). The addition APPENDS, so the current selection index
    /// still points at the same workspace and its watcher is unchanged — only
    /// the repo picker gains the new entry. Selecting it later sets up its own
    /// watcher via `restartForSelection`.
    func syncWorkspaces(task: TaskRecord, repos: [RepoConfig]) {
        self.task = task
        self.repos = repos
    }

    /// Test hook: await the most recent refresh to completion.
    func awaitRefresh() async { await lastRefreshTask?.value }

    func stop() {
        watcher?.stop()
        watcher = nil
        let refresher = refresher
        Task { await refresher?.stop() }
        self.refresher = nil
    }

    private func restartForSelection() {
        stop()
        tree = []
        latestPatch = nil
        start()
    }

    private func regenerate() async {
        guard let workspace = selectedWorkspace, let base = selectedBaseBranch else { return }
        do {
            let diff = try await service.diff(
                workspace: workspace.worktreeURL, baseBranch: base, scope: scope)
            // Tree + counts + patch update FIRST and unconditionally — the file
            // list is useful even before anything renders in the center.
            let newTree = FileTreeBuilder.build(entries: diff.entries, untracked: diff.untracked)
            tree = newTree
            // Preserve the user's collapses across the rebuild; drop entries
            // for directories that no longer exist in the diff.
            expansion.prune(toDirectoryIDs: newTree.flatMap { $0.directoryIDs() })
            untrackedCount = diff.untracked.count
            changedFileCount = diff.entries.count
            latestPatch = diff.patch
            renderError = nil
            ReviewDebug.stage(
                "populated files=\(diff.entries.count) untracked=\(diff.untracked.count)")
        } catch {
            renderError = String(describing: error)
            ReviewDebug.stage("error \(error)")
        }
    }
}

/// Stage logging for the REVIEWPANE / NAVIGATOR gates; inert unless a debug env
/// is set.
enum ReviewDebug {
    static let enabled = GeometryDebug.enabled
        || ProcessInfo.processInfo.environment["LIGHTHOUSE_DEBUG_REVIEWPANE"] != nil
        || ProcessInfo.processInfo.environment["LIGHTHOUSE_DEBUG_NAVIGATOR"] != nil

    static func stage(_ message: String) {
        guard enabled else { return }
        FileHandle.standardOutput.write(Data("REVIEWPANE-STAGE \(message)\n".utf8))
    }
}
