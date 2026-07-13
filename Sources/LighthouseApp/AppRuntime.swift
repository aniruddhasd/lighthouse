import AppKit
import Foundation
import Observation
import LighthouseAdapter
import LighthouseAppCore
import LighthouseGit
import LighthouseTaskEngine

/// Composition root: builds the model, the attention socket, and the session
/// registry; pumps socket signals into the model; owns UI-level state that
/// isn't worth persisting (selection, switcher visibility, last error).
@MainActor @Observable
final class AppRuntime {
    let model: AppModel
    let registry = SessionRegistry()
    /// Routes wheel events over terminals into mouse reports when the TUI
    /// owns the mouse (see LighthouseTerminalView).
    private let wheelMonitor = WheelReportMonitor()
    /// Single GitClient shared by the model and the review pane.
    let git = GitClient()
    private let listener: AttentionSocketListener
    private let adapter = ClaudeCodeAdapter()

    var selectedTaskId: UUID?
    var switcherPresented = false
    /// Active merge-back walk for the selected task, when one is running.
    var mergeWalk: MergeWalkController?
    /// Surfaced verbatim in the UI — always the full typed description.
    var lastError: String?
    /// Set when the attention socket could not start: sessions still run,
    /// badges degrade to unknown (spec §8 fail-safe) — but say so visibly.
    var attentionDegraded: String?

    /// LIGHTHOUSE_CONFIG_DIR overrides the config+socket location — used by
    /// scripted checks so they never touch the real config or unlink a live
    /// instance's socket.
    static func defaultConfigDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["LIGHTHOUSE_CONFIG_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lighthouse", isDirectory: true)
    }

    init(configDirectory: URL = AppRuntime.defaultConfigDirectory()) {
        // Socket at the config-directory ROOT: unix socket paths cap at ~104
        // bytes (sun_path), so no nesting.
        listener = AttentionSocketListener(directory: configDirectory, adapter: adapter)
        model = AppModel(
            store: ConfigStore(directory: configDirectory),
            socketPath: listener.socketURL,
            adapter: adapter,
            git: git)
        do {
            try model.load()
        } catch {
            lastError = "Could not load config: \(error)"
        }
        Task { await runAttentionPipeline() }
        setUpGeometryProbeIfRequested()
        runDiffRenderCheckIfRequested()
        runMergeWalkCheckIfRequested()
    }

    private let loginShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

    /// Begins a merge-back walk for `task` over `orderedRepoIds` (default:
    /// creation order). The UI shows the conflict pane when it pauses.
    func startMergeWalk(for task: TaskRecord, orderedRepoIds: [UUID]) async {
        let controller = MergeWalkController(
            task: task, repos: model.repos, orderedRepoIds: orderedRepoIds,
            git: git, session: registry, loginShell: loginShell)
        mergeWalk = controller
        await controller.start()
        // A clean walk finishes immediately: reflect done, drop the pane.
        if case .completed = controller.state {
            model.markMerged(taskId: task.id)
            mergeWalk = nil
        }
    }

    func endMergeWalk() { mergeWalk = nil }

    /// LIGHTHOUSE_DEBUG_MERGEWALK=<clone-with-conflict>: drives a full
    /// merge-back cycle in the real app over a scripted conflicting repo —
    /// run → assert paused-conflicted → resolve every text file whole-file
    /// (current) via the transform API → complete → assert completed. Logs
    /// each stage for Scripts/smoke-run.sh to assert.
    private var mergeWalkKeepAlive: MergeWalkController?
    private func runMergeWalkCheckIfRequested() {
        guard let clonePath = ProcessInfo.processInfo.environment["LIGHTHOUSE_DEBUG_MERGEWALK"]
        else { return }
        Task { @MainActor in
            func log(_ m: String) {
                FileHandle.standardOutput.write(Data("MERGEWALK-STAGE \(m)\n".utf8))
            }
            let repo = RepoConfig(path: clonePath, baseBranch: "main")
            let task = TaskRecord(
                name: "mergewalk-probe", branch: "task", adapterKind: "debug",
                sessionRef: nil, state: .done,
                workspaces: [Workspace(repoId: repo.id, worktreePath: clonePath, mergeState: .unmerged)])
            let controller = MergeWalkController(
                task: task, repos: [repo], orderedRepoIds: [repo.id],
                git: git, session: registry, loginShell: loginShell)
            mergeWalkKeepAlive = controller
            await controller.start()
            guard controller.isPausedConflicted else {
                log("unexpected-state \(controller.state)"); return
            }
            log("paused conflicted=\(controller.conflicts.count)")
            for conflict in controller.conflicts {
                if case .text = conflict.kind {
                    await controller.resolveWholeFileText(path: conflict.path, side: .current)
                }
            }
            log("resolved remaining=\(controller.conflicts.count)")
            await controller.completeCurrentRepo()
            if case .completed = controller.state {
                log("completed")
            } else {
                log("not-completed \(controller.state)")
            }
        }
    }

    /// LIGHTHOUSE_DEBUG_DIFFRENDER=1: renders the hostile fixture diff
    /// through the REAL pipeline (page builder → vendored assets → locked
    /// WKWebView) and logs the page's own DOM assertions — the offscreen
    /// web process runs without a visible window. Scripts/smoke-run.sh
    /// asserts the results (the escape proof no unit test can give).
    private var diffRenderKeepAlive: [AnyObject] = []
    private func runDiffRenderCheckIfRequested() {
        guard ProcessInfo.processInfo.environment["LIGHTHOUSE_DEBUG_DIFFRENDER"] == "1" else { return }
        do {
            let directory = try DiffWebViewFactory.makeRenderDirectory()
            let gate = LocalOnlyNavigationDelegate(allowedRoot: directory) { message in
                FileHandle.standardOutput.write(Data("DIFFRENDER result \(message)\n".utf8))
            }
            let webView = DiffWebViewFactory.makeWebView(
                renderDirectory: directory, navigationGate: gate)
            diffRenderKeepAlive = [webView, gate]
            let page = DiffPageBuilder.page(
                diff: DiffPageBuilder.hostileFixtureDiff, debugChecks: true)
            try DiffWebViewFactory.load(page: page, into: webView, renderDirectory: directory)
            FileHandle.standardOutput.write(Data("DIFFRENDER-STAGE loaded\n".utf8))
        } catch {
            FileHandle.standardOutput.write(Data("DIFFRENDER-STAGE failed \(error)\n".utf8))
        }
    }

    /// LIGHTHOUSE_DEBUG_GEOMETRY=1: select an ephemeral probe task running a
    /// harmless /bin/cat pty so the terminal pane renders without any agent,
    /// then resize the window once so the geometry check observes two sizes.
    /// The probe never persists and never marks the session "working", so
    /// quit stays unconfirmed and the user's config is untouched.
    private func setUpGeometryProbeIfRequested() {
        guard GeometryDebug.enabled else { return }
        // LIGHTHOUSE_DEBUG_REVIEWPANE=<repo path> gives the probe task a real
        // workspace (an outside-created fixture repo on branch "task",
        // base "main") so the review pane renders populated in the gate.
        var workspaces: [Workspace] = []
        if let repoPath = ProcessInfo.processInfo.environment["LIGHTHOUSE_DEBUG_REVIEWPANE"] {
            let repo = RepoConfig(path: repoPath, baseBranch: "main")
            model.insertEphemeralRepo(repo)
            workspaces = [Workspace(
                repoId: repo.id, worktreePath: repoPath, mergeState: .unmerged)]
        }
        let probe = TaskRecord(
            name: "geometry-probe", branch: "debug/geometry-probe",
            adapterKind: "debug", sessionRef: nil, state: .done, workspaces: workspaces)
        model.insertEphemeralTask(probe)
        let plan = LaunchPlan(
            executable: "/bin/cat", arguments: [], environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory,
            sessionRef: "geometry-probe")
        _ = registry.start(taskId: probe.id, plan: plan) { _, _ in }
        selectedTaskId = probe.id
        // The scripted resize is event-driven from the first real layout
        // pass (GeometryResizeDriver) — a wall-clock timer here raced window
        // creation in other launch contexts and silently no-opped.
    }

    private func runAttentionPipeline() async {
        do {
            try await listener.start()
        } catch {
            attentionDegraded =
                "Attention socket failed to start (\(error)). Sessions still work; badges won't update."
            return
        }
        for task in model.tasks {
            if let ref = task.sessionRef {
                await listener.register(sessionRef: ref, taskId: task.id)
            }
        }
        let stream = await listener.signals()
        for await signal in stream {
            model.apply(signal)
        }
    }

    // MARK: - Task + session flows

    func createTaskAndStartSession(name: String, branch: String, repoIds: [UUID]) async {
        do {
            let (task, plan) = try await model.createTask(
                name: name, branch: branch, repoIds: repoIds)
            await listener.register(sessionRef: plan.sessionRef, taskId: task.id)
            startSession(taskId: task.id, plan: plan)
            selectedTaskId = task.id
        } catch let failure as TaskCreationFailure {
            lastError = FailureDescriber.describe(failure)
        } catch let error as TaskEngineError {
            lastError = FailureDescriber.describe(error)
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Resume: `claude --resume <id>`. A dead/unknown id fails fast and
    /// visibly inside the terminal (verified: "No conversation found…",
    /// exit 1) — the exit lands as sessionDied, and resume stays available.
    func resumeSession(for task: TaskRecord) {
        do {
            guard let plan = try model.resumePlan(for: task) else {
                lastError = "\(task.name) has no stored session to resume."
                return
            }
            startSession(taskId: task.id, plan: plan)
        } catch {
            lastError = String(describing: error)
        }
    }

    private func startSession(taskId: UUID, plan: LaunchPlan) {
        _ = registry.start(taskId: taskId, plan: plan) { [weak self] id, _ in
            self?.model.noteSessionEnded(taskId: id)
        }
        model.noteSessionStarted(taskId: taskId)
    }

    func removeTask(_ task: TaskRecord, mode: TaskRemovalMode) async -> Bool {
        do {
            if let ref = task.sessionRef {
                await listener.unregister(sessionRef: ref)
            }
            registry.discard(taskId: task.id)
            _ = try await model.removeTask(task, mode: mode)
            if selectedTaskId == task.id { selectedTaskId = nil }
            return true
        } catch let error as TaskEngineError {
            lastError = FailureDescriber.describe(error)
            return false
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    /// Called on the way out (applicationWillTerminate): unlink the socket.
    /// Ptys die with the app; conversation context survives via --resume.
    nonisolated func shutdown() {
        listener.stop()
    }
}
