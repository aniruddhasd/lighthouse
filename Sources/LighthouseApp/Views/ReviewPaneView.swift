import SwiftUI
import WebKit
import LighthouseAppCore
import LighthouseGit
import LighthouseTaskEngine

/// Per-(task, repo) review state: owns the watcher, the debounced refresher,
/// the diff pipeline, and the WKWebView. Recreated when the task changes
/// (view identity is .id(task.id)); the watcher swaps when the repo
/// selection changes; everything stops when the pane disappears.
@MainActor @Observable
final class ReviewPaneModel {
    let task: TaskRecord
    private let repos: [RepoConfig]
    private let service: LiveDiffService

    var selectedWorkspaceIndex = 0 {
        didSet { if oldValue != selectedWorkspaceIndex { restartForSelection() } }
    }
    private(set) var tree: [FileTreeNode] = []
    private(set) var untrackedCount = 0
    /// Number of changed (tracked) files in the latest diff — the value the
    /// user sees as the file count; asserted by tests.
    private(set) var changedFileCount = 0
    private(set) var renderError: String?

    let webView: WKWebView
    private let renderDirectory: URL?
    private let navigationGate: LocalOnlyNavigationDelegate
    private var watcher: FileSystemWatcher?
    private var refresher: DiffRefresher?
    /// The most recent refresh task — awaitable by tests so assertions don't
    /// poll on wall-clock (which flakes under parallel-suite contention).
    private(set) var lastRefreshTask: Task<Void, Never>?

    init(task: TaskRecord, repos: [RepoConfig], git: GitClient) {
        self.task = task
        self.repos = repos
        self.git = git
        self.service = LiveDiffService(git: git)

        var directory: URL?
        do {
            directory = try DiffWebViewFactory.makeRenderDirectory()
        } catch {
            renderError = "Diff renderer assets unavailable: \(error)"
        }
        self.renderDirectory = directory
        self.navigationGate = LocalOnlyNavigationDelegate(
            allowedRoot: directory ?? FileManager.default.temporaryDirectory)
        self.webView = DiffWebViewFactory.makeWebView(
            renderDirectory: directory ?? FileManager.default.temporaryDirectory,
            navigationGate: navigationGate)
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

    private var selectedBaseBranch: String? {
        guard let workspace = selectedWorkspace else { return nil }
        return repos.first { $0.id == workspace.repoId }?.baseBranch
    }

    private let git: GitClient

    // MARK: - Lifecycle (pane visible ⇔ watcher running)

    /// Idempotently sets up the watcher (worktree + gitdir) if needed, and
    /// ALWAYS triggers an immediate unconditional refresh. Every entry point
    /// — pane appear, task/repo switch, scenePhase foreground — goes through
    /// here, so a diff missed while the watcher was stopped (backgrounded) or
    /// a change FSEvents never saw self-heals on the next (re)start
    /// (2026-07-13). Refresh does not depend on the watcher existing.
    func start() {
        guard let workspace = selectedWorkspace else { return }
        if refresher == nil {
            let refresher = DiffRefresher { [weak self] in await self?.regenerate() }
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

    /// Manual refresh (header button / Cmd+R) — belt-and-braces for any
    /// missed-event window we haven't imagined.
    func refreshNow() {
        guard let refresher else { start(); return }
        lastRefreshTask = Task { await refresher.refreshNow() }
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
        start()
    }

    func scrollTo(file path: String) {
        let encoded = Data(path.utf8).base64EncodedString()
        webView.evaluateJavaScript("window.lighthouseScrollToFile('\(encoded)')")
    }

    private func regenerate() async {
        guard let workspace = selectedWorkspace, let base = selectedBaseBranch else { return }
        do {
            let diff = try await service.liveDiff(
                workspace: workspace.worktreeURL, baseBranch: base)
            // Tree + counts update FIRST and unconditionally — the file list
            // is useful even if the WKWebView renderer assets are missing.
            tree = FileTreeBuilder.build(entries: diff.entries, untracked: diff.untracked)
            untrackedCount = diff.untracked.count
            changedFileCount = diff.entries.count
            renderError = nil
            if let renderDirectory {
                try DiffWebViewFactory.load(
                    page: DiffPageBuilder.page(diff: diff.patch),
                    into: webView, renderDirectory: renderDirectory)
            }
            ReviewDebug.stage(
                "populated files=\(diff.entries.count) untracked=\(diff.untracked.count)")
        } catch {
            renderError = String(describing: error)
            ReviewDebug.stage("error \(error)")
        }
    }
}

/// Watcher lifecycle contract: the FSEvents watcher runs exactly while this
/// pane is on screen for the SELECTED task and the app is active. Task
/// switches recreate the pane (view identity is the task id) — onDisappear
/// stops the old watcher, onAppear starts the new one; backgrounding the
/// app stops it, foregrounding restarts it. Never more than one watcher.
struct ReviewPaneView: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.scenePhase) private var scenePhase
    let task: TaskRecord
    @State private var model: ReviewPaneModel?

    var body: some View {
        // ZStack, NOT Group: Group is transparent, so modifiers attach to
        // each branch — the ProgressView→content switch re-fired onAppear,
        // recreating the model in an endless loop (caught by the REVIEWPANE
        // gate, 2026-07-13). A real container fires appear once; the guard
        // is belt-and-braces.
        ZStack {
            if let model {
                ReviewPaneContent(model: model)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard model == nil else { return }
            ReviewDebug.stage("appear task=\(task.name)")
            let model = ReviewPaneModel(
                task: task, repos: runtime.model.repos, git: runtime.git)
            self.model = model
            model.start()
        }
        .onDisappear {
            model?.stop()
            model = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model?.start()
            } else {
                model?.stop()
            }
        }
    }
}

/// Stage logging for the REVIEWPANE gate; inert unless a debug env is set.
enum ReviewDebug {
    static let enabled = GeometryDebug.enabled
        || ProcessInfo.processInfo.environment["LIGHTHOUSE_DEBUG_REVIEWPANE"] != nil

    static func stage(_ message: String) {
        guard enabled else { return }
        FileHandle.standardOutput.write(Data("REVIEWPANE-STAGE \(message)\n".utf8))
    }
}

private struct ReviewPaneContent: View {
    @Bindable var model: ReviewPaneModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Repo", selection: $model.selectedWorkspaceIndex) {
                    ForEach(model.workspaces, id: \.index) { entry in
                        Text(entry.repoName).tag(entry.index)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
                Text("diff vs base · live")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button { model.refreshNow() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh diff (⌘R)")
                // Cmd+R while the review pane is focused.
                Button("", action: { model.refreshNow() })
                    .keyboardShortcut("r", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .padding(6)
            Divider()
            HSplitView {
                fileTree
                    .frame(minWidth: 150, idealWidth: 200, maxWidth: 360, maxHeight: .infinity)
                DiffWebViewHost(webView: model.webView)
                    .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = model.renderError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(4)
            }
        }
    }

    @ViewBuilder
    private var fileTree: some View {
        if model.tree.isEmpty {
            ContentUnavailableView(
                "No changes",
                systemImage: "checkmark.circle",
                description: Text("Nothing differs from base yet."))
        } else {
            List {
                OutlineGroup(model.tree, children: \.children) { node in
                    HStack(spacing: 6) {
                        if node.isFile {
                            Text(node.status ?? "·")
                                .font(.system(.caption2, design: .monospaced).bold())
                                .foregroundStyle(statusColor(node.status))
                                .frame(width: 14)
                        } else {
                            Image(systemName: "folder")
                                .font(.caption)
                        }
                        Text(node.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if node.isFile { model.scrollTo(file: node.id) }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func statusColor(_ status: String?) -> Color {
        switch status {
        case "A", "?": return .green
        case "D": return .red
        case "M", "T": return .orange
        case "R", "C": return .blue
        default: return .secondary
        }
    }
}
