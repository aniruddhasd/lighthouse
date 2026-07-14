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
        notifications.onSelectTask = { [weak self] id in self?.selectedTaskId = id }
        // First-run setup auto-opens when there are no repos and setup was
        // never completed; always re-runnable from Help.
        setupPresented = model.repos.isEmpty && !model.hasCompletedSetup
        // NSApp does not exist yet during App.init — anything touching NSApp
        // (dock badge) or UN* must run AFTER launch, on the main actor, once
        // NSApplication.main() is up. (A dock-badge write in init crashed on
        // a nil NSApp — 2026-07-14.)
        Task { @MainActor in
            notifications.configure()
            updateDockBadge()
            refreshNotificationStatus()
        }
        Task { await runAttentionPipeline() }
        setUpGeometryProbeIfRequested()
        runDiffRenderCheckIfRequested()
        runMergeWalkCheckIfRequested()
        runNotificationCheckIfRequested()
    }

    /// Whether the first-run setup sheet is showing.
    var setupPresented = false
    /// Whether notification authorization is known-denied (drives the
    /// one-time, dismissible inbox hint).
    private(set) var notificationsDenied = false

    /// The dismissible "notifications are off" inbox hint: shown once, when
    /// denied and there are tasks, until the user dismisses it.
    var notificationsHintVisible: Bool {
        notificationsDenied && !model.notificationsHintDismissed && !model.tasks.isEmpty
    }

    func dismissNotificationsHint() { model.dismissNotificationsHint() }

    private func refreshNotificationStatus() {
        Task { @MainActor in
            notificationsDenied = await notifications.authorizationStatus() == .denied
        }
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

    /// A SetupModel wired to this runtime's services. Fresh each time the
    /// sheet opens so checks re-run cleanly.
    func makeSetupModel() -> SetupModel {
        SetupModel(
            git: git, loginShell: loginShell, socketPath: listener.socketURL,
            notifications: notifications,
            makeListener: { dir in AttentionSocketListener(directory: dir, adapter: ClaudeCodeAdapter()) })
    }

    func finishSetup() {
        model.markSetupCompleted()
        setupPresented = false
        refreshNotificationStatus()
    }

    /// Help → Run Setup Checks (re-runnable any time).
    func openSetup() { setupPresented = true }

    /// LIGHTHOUSE_DEBUG_NOTIFY=<output-file>: drives a real attention
    /// transition on a probe task that is NOT currently viewed and writes the
    /// decision + UN* enqueue result to the file (a file, not stdout, so
    /// capture is reliable regardless of launch method). MUST be launched via
    /// `open` — UNUserNotificationCenter.current() SIGTRAPs when the binary is
    /// direct-exec'd (LaunchServices hasn't registered the app). It does NOT
    /// call requestAuthorization (that shows a blocking modal); `center.add`
    /// enqueues without authorization. Banner DISPLAY still needs the user's
    /// grant — the gate asserts the decision + enqueue path only, honestly.
    private func runNotificationCheckIfRequested() {
        guard let outPath = ProcessInfo.processInfo.environment["LIGHTHOUSE_DEBUG_NOTIFY"],
              !outPath.isEmpty else { return }
        Task { @MainActor in
            var lines: [String] = []
            func log(_ m: String) {
                lines.append("NOTIFY-STAGE \(m)")
                try? lines.joined(separator: "\n").appending("\n")
                    .write(toFile: outPath, atomically: true, encoding: .utf8)
            }
            let taskId = UUID()
            let transition = AttentionTransition(
                taskId: taskId, event: .agentNeedsInput, oldState: .working, newState: .needsInput)
            log("decision=\(NotificationDecider.decide(transition, isCurrentlyViewed: false).map(\.rawValue) ?? "nil")")
            log("suppressed-when-viewed=\(NotificationDecider.decide(transition, isCurrentlyViewed: true) == nil)")
            // UN* init happens here; under `open` it is safe.
            let enqueued = notifications.post(kind: .needsInput, taskId: taskId, taskName: "notify-probe")
            log("enqueued=\(enqueued)")
            log("done")
        }
    }

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
        registry.open(taskId: probe.id, tabId: TabID.agent, plan: plan) { _, _ in }
        tabs[probe.id] = [TerminalTab(id: TabID.agent, title: "Agent", isAgent: true)]
        focusedTab[probe.id] = TabID.agent
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
            let transition = model.apply(signal)
            handleTransition(transition)
        }
    }

    let notifications = NotificationService()

    /// Whether the user is currently looking at a task: app active AND that
    /// task selected. Notifications fire only when a signal would be MISSED.
    private func isCurrentlyViewed(_ taskId: UUID) -> Bool {
        NSApp.isActive && selectedTaskId == taskId
    }

    /// Decides (pure) then posts a notification for an attention transition,
    /// and refreshes the dock badge. Called for every transition — socket
    /// signals and session start/stop alike.
    func handleTransition(_ transition: AttentionTransition?) {
        if let transition,
           let kind = NotificationDecider.decide(
               transition, isCurrentlyViewed: isCurrentlyViewed(transition.taskId)),
           let task = model.tasks.first(where: { $0.id == transition.taskId }) {
            notifications.post(kind: kind, taskId: task.id, taskName: task.name)
        }
        updateDockBadge()
    }

    /// Dock badge = number of needs-input tasks; cleared when zero. Uses
    /// NSApplication.shared (always valid) — the `NSApp` global is nil until
    /// the app instance is first created, which crashed a dock-badge write in
    /// App.init (2026-07-14); this and deferring the first call past init fix it.
    func updateDockBadge() {
        let count = model.needsInputCount
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    // MARK: - Terminal tabs (UI-only, not persisted; die with the app)

    /// Ordered terminal tabs per task; the first is always the agent tab.
    var tabs: [UUID: [TerminalTab]] = [:]
    /// Focused tab per task.
    var focusedTab: [UUID: UUID] = [:]

    private func loginShellURL(for task: TaskRecord) -> URL? {
        guard let workspace = task.workspaces.first else { return nil }
        return workspace.worktreeURL
    }

    // MARK: - Task + session flows

    func createTaskAndStartSession(name: String, branch: String, repoIds: [UUID]) async {
        do {
            let (task, plan) = try await model.createTask(
                name: name, branch: branch, repoIds: repoIds)
            await listener.register(sessionRef: plan.sessionRef, taskId: task.id)
            startAgentSession(taskId: task.id, plan: plan)
            selectedTaskId = task.id
        } catch let failure as TaskCreationFailure {
            lastError = FailureDescriber.describe(failure)
        } catch let error as TaskEngineError {
            lastError = FailureDescriber.describe(error)
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Resume `claude --resume <id>`. If the agent shell is still alive (Claude
    /// exited to the prompt), the command is TYPED into it; otherwise a fresh
    /// agent shell tab is opened and the command typed there. A dead/unknown
    /// id fails visibly inside the terminal ("No conversation found…") — the
    /// shell survives, so the user is not trapped.
    func resumeSession(for task: TaskRecord) {
        do {
            guard let plan = try model.resumePlan(for: task) else {
                lastError = "\(task.name) has no stored session to resume."
                return
            }
            if let controller = registry.agentController(taskId: task.id), controller.isRunning,
               let command = plan.typedCommand {
                registry.runCommand(taskId: task.id, tabId: TabID.agent, command: command)
                handleTransition(model.noteSessionStarted(taskId: task.id))
            } else {
                startAgentSession(taskId: task.id, plan: plan) // calls noteSessionStarted
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    private func startAgentSession(taskId: UUID, plan: LaunchPlan) {
        registry.open(taskId: taskId, tabId: TabID.agent, plan: plan) { [weak self] key, _ in
            // The agent SHELL exited (user typed `exit`) — the tab is gone.
            // Not the agent-end signal (that is the SessionEnd hook); this
            // keeps liveSessions accurate and removes the tab.
            self?.handleTerminalExit(key)
        }
        tabs[taskId, default: []].removeAll { $0.id == TabID.agent }
        tabs[taskId, default: []].insert(TerminalTab(id: TabID.agent, title: "Agent", isAgent: true), at: 0)
        focusedTab[taskId] = TabID.agent
        handleTransition(model.noteSessionStarted(taskId: taskId))
    }

    /// Cmd+T: a plain persistent login shell in the task's primary worktree —
    /// no hooks, no session, no attention effect; dies with the app.
    func openShellTab(for task: TaskRecord) {
        guard let cwd = loginShellURL(for: task) else { return }
        let tabId = UUID()
        let plan = LaunchPlan(
            executable: loginShell, arguments: ["-l", "-i"], environment: [:],
            workingDirectory: cwd, sessionRef: "", typedCommand: nil)
        registry.open(taskId: task.id, tabId: tabId, plan: plan) { [weak self] key, _ in
            self?.handleTerminalExit(key)
        }
        let existing = tabs[task.id]?.filter { !$0.isAgent }.count ?? 0
        tabs[task.id, default: []].append(
            TerminalTab(id: tabId, title: "shell \(existing + 1)", isAgent: false))
        focusedTab[task.id] = tabId
    }

    /// Cmd+W: close the focused non-agent tab (the agent tab is closed only
    /// via task removal / explicit confirmation elsewhere).
    func closeFocusedTab(for taskId: UUID) {
        guard let focused = focusedTab[taskId], focused != TabID.agent else { return }
        closeTab(taskId: taskId, tabId: focused)
    }

    func closeTab(taskId: UUID, tabId: UUID) {
        registry.closeTab(taskId: taskId, tabId: tabId)
        tabs[taskId]?.removeAll { $0.id == tabId }
        if focusedTab[taskId] == tabId {
            focusedTab[taskId] = tabs[taskId]?.first?.id
        }
    }

    private func handleTerminalExit(_ key: TabKey) {
        if key.tabId == TabID.agent {
            handleTransition(model.noteSessionEnded(taskId: key.taskId))
        }
        tabs[key.taskId]?.removeAll { $0.id == key.tabId }
        if focusedTab[key.taskId] == key.tabId {
            focusedTab[key.taskId] = tabs[key.taskId]?.first?.id
        }
    }

    func removeTask(_ task: TaskRecord, mode: TaskRemovalMode) async -> Bool {
        do {
            if let ref = task.sessionRef {
                await listener.unregister(sessionRef: ref)
            }
            registry.discardTask(taskId: task.id)
            tabs[task.id] = nil
            focusedTab[task.id] = nil
            _ = try await model.removeTask(task, mode: mode)
            if selectedTaskId == task.id { selectedTaskId = nil }
            updateDockBadge() // a needs-input task may have gone away
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
