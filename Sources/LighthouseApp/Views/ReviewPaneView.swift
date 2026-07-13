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
    private(set) var renderError: String?

    let webView: WKWebView
    private let renderDirectory: URL?
    private let navigationGate: LocalOnlyNavigationDelegate
    private var watcher: FileSystemWatcher?
    private var refresher: DiffRefresher?

    init(task: TaskRecord, repos: [RepoConfig], git: GitClient) {
        self.task = task
        self.repos = repos
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

    // MARK: - Lifecycle (pane visible ⇔ watcher running)

    func start() {
        guard watcher == nil else { return }
        guard let workspace = selectedWorkspace else { return }
        let refresher = DiffRefresher { [weak self] in
            await self?.regenerate()
        }
        self.refresher = refresher
        watcher = FileSystemWatcher(path: workspace.worktreePath) {
            Task { await refresher.noteChange() }
        }
        Task { await refresher.refreshNow() }
    }

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
        guard let workspace = selectedWorkspace, let base = selectedBaseBranch,
              let renderDirectory else { return }
        do {
            let diff = try await service.liveDiff(
                workspace: workspace.worktreeURL, baseBranch: base)
            let html = DiffPageBuilder.page(diff: diff.patch)
            tree = FileTreeBuilder.build(entries: diff.entries, untracked: diff.untracked)
            untrackedCount = diff.untracked.count
            renderError = nil
            try DiffWebViewFactory.load(
                page: html, into: webView, renderDirectory: renderDirectory)
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
