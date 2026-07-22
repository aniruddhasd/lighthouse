import Foundation
import Observation
import LighthouseAdapter
import LighthouseGit
import LighthouseTaskEngine

public enum RepoRegistrationError: Error, Sendable, Equatable {
    case pathDoesNotExist(String)
    case notAGitRepository(String)
    /// The path is inside a repo but is not its root — registering a subdir
    /// would make every worktree/merge computation subtly wrong.
    case notTheRepositoryRoot(path: String, actualRoot: String)
    case alreadyRegistered(path: String)
    /// The base branch name is not a syntactically valid git ref (e.g. it
    /// begins with `-` and would ride into git's option parser). Rejected at
    /// registration so it can never be persisted, quite apart from the
    /// `--end-of-options` guard in every GitClient invocation.
    case invalidBaseBranchName(String)
    case baseBranchMissing(path: String, baseBranch: String)
    /// The remote URL is empty, option-lookalike (leading `-`), or yields no
    /// usable folder name. Rejected before any clone runs.
    case invalidRemoteURL(String)
    /// The clone's target directory already exists — refuse rather than clone
    /// into or over it. The caller decides whether to register it as-is.
    case destinationExists(path: String)
}

public enum RepoRemovalError: Error, Sendable, Equatable {
    /// Repos referenced by tasks can't be removed out from under them.
    case usedByTasks(repoId: UUID, taskNames: [String])
    case unknownRepo(UUID)
}

extension Comparable {
    /// Clamps the value into `range` (below → lowerBound, above → upperBound).
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// The app's observable core: config-backed repo registry and task list,
/// per-task attention state, and the orchestration of TaskEngine + adapter
/// for creation/resume/removal. Deliberately free of any UI import — every
/// rule here is unit-tested. The UI layer owns SwiftTerm and the socket
/// listener and feeds this model via `apply(_:)` / `noteSession…`.
@MainActor @Observable
public final class AppModel {
    public private(set) var repos: [RepoConfig] = []
    public private(set) var tasks: [TaskRecord] = []
    /// Live attention state per task (seeded from persisted TaskRecord.state).
    public private(set) var attention: [UUID: TaskAttentionState] = [:]
    /// When each task entered its current attention state — drives the inbox
    /// "oldest-blocked first" ordering. Session-only.
    private var attentionSince: [UUID: Date] = [:]
    /// Task ids with a live pty right now — maintained by the session layer.
    public private(set) var liveSessions: Set<UUID> = []
    /// First-run setup flags (config schema v3).
    public private(set) var hasCompletedSetup = false
    public private(set) var notificationsHintDismissed = false
    /// Persisted UI preferences (config schema v4), all wired to the UI: `theme`
    /// drives the runtime theme, `startView` seeds the landing view at launch,
    /// `showBeam` gates the ambient Harbor beam (Preferences, Phase 5). Raw
    /// strings/bool so this UI-free layer needs no SwiftUI.
    public private(set) var theme: String = "beacon"
    public private(set) var startView: String = "harbor"
    public private(set) var showBeam: Bool = true
    /// Terminal font point size (config schema v5), wired to every SwiftTerm
    /// session and adjustable from Preferences. Kept in `terminalFontRange`.
    public private(set) var terminalFontSize: Double = LighthouseConfig.defaultTerminalFontSize
    /// Sane bounds for the terminal font size — the Preferences control and the
    /// setter both clamp to this.
    public static let terminalFontRange: ClosedRange<Double> = 9...24
    /// Injectable clock so ordering tests are deterministic.
    private let now: @Sendable () -> Date
    /// Debug-only tasks/repos (geometry + review probes): visible to the
    /// UI, never persisted.
    private var ephemeralTaskIds: Set<UUID> = []
    private var ephemeralRepoIds: Set<UUID> = []

    /// Global worktrees-root override (config schema v2). nil = per-repo
    /// default: `<repo parent>/lighthouse-worktrees/<task>/<repo>`.
    public private(set) var worktreesRootOverride: String?

    private let store: ConfigStore
    private let engine: TaskEngine
    private let git: GitClient
    private let cloner: RepoCloner
    private let adapter: any AgentAdapter
    private let socketPath: URL
    private let loginShell: String

    public init(
        store: ConfigStore,
        socketPath: URL,
        adapter: any AgentAdapter,
        git: GitClient = GitClient(),
        cloner: RepoCloner = RepoCloner(),
        loginShell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.socketPath = socketPath
        self.adapter = adapter
        self.git = git
        self.cloner = cloner
        self.engine = TaskEngine(git: git)
        self.loginShell = loginShell
        self.now = now
    }

    /// Loads persisted state. Attention seeds from each task's stored state,
    /// reconciled through `reconciledLoadState` (see below).
    public func load() throws {
        let config = try store.load()
        repos = config.repos
        // A task last persisted as `.working` can never be truthful at load:
        // terminal controllers are in-memory only and die with the app, so no
        // pty can be live the instant we start. Left as `.working`, canResume
        // returns false (no Resume button) and the `.dirty` warning is skipped,
        // leaving a dead-end "No session for this task." pane (2026-07-14, found
        // in acceptance testing). Fold it to `.dirty` at the load seam — the
        // same state the live `.sessionDied` transition yields — so Resume and
        // the interrupted-workspace warning both appear. Live `.working`
        // transitions run through AttentionStateMachine and are untouched.
        tasks = config.tasks.map { record in
            var record = record
            record.state = Self.reconciledLoadState(record.state)
            return record
        }
        worktreesRootOverride = config.worktreesRootOverride
        hasCompletedSetup = config.hasCompletedSetup
        notificationsHintDismissed = config.notificationsHintDismissed
        theme = config.theme
        startView = config.startView
        showBeam = config.showBeam
        // Clamp on load too: a hand-edited config can carry an out-of-range size.
        terminalFontSize = config.terminalFontSize.clamped(to: Self.terminalFontRange)
        attention = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.state) })
        attentionSince = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, now()) })
    }

    /// Pure load-seed reconciliation: a persisted `.working` folds to `.dirty`
    /// (no pty is live at load, so the agent that was "working" is gone —
    /// exactly the live `.sessionDied` outcome); every other state is truthful
    /// and passes through. Load-time only — live transitions go through
    /// `AttentionStateMachine`, never here.
    nonisolated static func reconciledLoadState(
        _ persisted: TaskAttentionState
    ) -> TaskAttentionState {
        persisted == .working ? .dirty : persisted
    }

    public func markSetupCompleted() {
        hasCompletedSetup = true
        try? persist()
    }

    public func dismissNotificationsHint() {
        notificationsHintDismissed = true
        try? persist()
    }

    /// Persists the chosen UI theme (raw "beacon"/"native"). Best-effort like
    /// the other preference writes — the next save catches up on failure.
    public func setTheme(_ value: String) {
        guard theme != value else { return }
        theme = value
        try? persist()
    }

    /// Persists the preferred landing view (raw "harbor"/"focus"), consumed at
    /// the next launch (AppRuntime seeds `nav` from it). Best-effort, no-op on a
    /// redundant set — mirrors `setTheme`.
    public func setStartView(_ value: String) {
        guard startView != value else { return }
        startView = value
        try? persist()
    }

    /// Persists the ambient-beam preference; the Harbor beam reads `showBeam`
    /// live, so the change takes effect immediately. Best-effort, no-op on a
    /// redundant set — mirrors `setTheme`.
    public func setShowBeam(_ value: Bool) {
        guard showBeam != value else { return }
        showBeam = value
        try? persist()
    }

    /// Persists the terminal font size (clamped to `terminalFontRange`). The
    /// session layer applies it to every live terminal on change; best-effort,
    /// no-op on a redundant set — mirrors `setShowBeam`.
    public func setTerminalFontSize(_ value: Double) {
        let clamped = value.clamped(to: Self.terminalFontRange)
        guard terminalFontSize != clamped else { return }
        terminalFontSize = clamped
        try? persist()
    }

    public func setWorktreesRootOverride(_ path: String?) throws {
        worktreesRootOverride = path
        try persist()
    }

    /// Inserts a task that exists only for this process (e.g. the geometry
    /// probe). It renders like any task but is excluded from every save.
    public func insertEphemeralTask(_ task: TaskRecord) {
        ephemeralTaskIds.insert(task.id)
        tasks.append(task)
        attention[task.id] = task.state
    }

    /// Debug-only sibling of insertEphemeralTask for the repo the probe's
    /// workspace points at — visible to the UI, excluded from every save.
    public func insertEphemeralRepo(_ repo: RepoConfig) {
        ephemeralRepoIds.insert(repo.id)
        repos.append(repo)
    }

    private func persist() throws {
        try store.save(LighthouseConfig(
            repos: repos.filter { !ephemeralRepoIds.contains($0.id) },
            tasks: tasks.filter { !ephemeralTaskIds.contains($0.id) },
            worktreesRootOverride: worktreesRootOverride,
            hasCompletedSetup: hasCompletedSetup,
            notificationsHintDismissed: notificationsHintDismissed,
            theme: theme,
            startView: startView,
            showBeam: showBeam,
            terminalFontSize: terminalFontSize))
    }

    // MARK: - Repo registry

    @discardableResult
    public func registerRepo(
        path: URL, baseBranch: String, setupScript: String? = nil, envCopyList: [String]? = nil
    ) async throws -> RepoConfig {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RepoRegistrationError.pathDoesNotExist(path.path)
        }
        guard try await git.isInsideWorkTree(at: path) else {
            throw RepoRegistrationError.notAGitRepository(path.path)
        }
        // Reject option-lookalikes explicitly: `git check-ref-format
        // refs/heads/<name>` accepts a leading-dash name (the `refs/heads/`
        // prefix hides it), so isValidBranchName alone would pass
        // "--output=…". The leading-dash guard is the real option-injection
        // block; isValidBranchName covers the rest of ref syntax.
        guard !baseBranch.hasPrefix("-"), try await git.isValidBranchName(baseBranch) else {
            throw RepoRegistrationError.invalidBaseBranchName(baseBranch)
        }
        let root = try await git.topLevel(of: path)
        let canonicalPath = path.resolvingSymlinksInPath().path
        let canonicalRoot = root.resolvingSymlinksInPath().path
        guard canonicalPath == canonicalRoot else {
            throw RepoRegistrationError.notTheRepositoryRoot(
                path: path.path, actualRoot: root.path)
        }
        guard !repos.contains(where: {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == canonicalRoot
        }) else {
            throw RepoRegistrationError.alreadyRegistered(path: path.path)
        }
        guard try await git.branchExists(baseBranch, in: root) else {
            throw RepoRegistrationError.baseBranchMissing(path: path.path, baseBranch: baseBranch)
        }

        let repo = RepoConfig(
            path: canonicalRoot, baseBranch: baseBranch,
            setupScript: setupScript, envCopyList: envCopyList)
        repos.append(repo)
        try persist()
        return repo
    }

    /// Clones `remoteURL` into `destinationParent/<name>` and registers the
    /// result — the "download for keeps" path (spec option D). Lighthouse does
    /// NOT own the clone: it lands in a directory the user chose and removal
    /// never deletes it, exactly as if they had cloned it by hand. After the
    /// clone this is byte-for-byte the normal `registerRepo` flow, so every
    /// downstream guard (git root, base branch exists, not already registered)
    /// still applies.
    ///
    /// All cheap pre-flight (URL, folder name, parent, destination) runs BEFORE
    /// the expensive clone, so a bad request fails instantly. `folderName`
    /// overrides the name derived from the URL; the base branch is auto-detected
    /// from the fresh clone.
    @discardableResult
    public func cloneAndRegister(
        remoteURL: String,
        destinationParent: URL,
        folderName: String? = nil,
        setupScript: String? = nil,
        envCopyList: [String]? = nil
    ) async throws -> RepoConfig {
        let url = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading `-` would ride into git's option parser; `--` fences it in
        // RepoCloner, but rejecting it here keeps a nonsense URL out entirely.
        guard !url.isEmpty, !url.hasPrefix("-") else {
            throw RepoRegistrationError.invalidRemoteURL(remoteURL)
        }
        let requested = folderName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = (requested?.isEmpty == false ? requested : Self.repoName(fromURL: url)),
              // No path separators or dot-segments: the name is a single
              // component appended to a directory the user chose — never a way
              // to escape it.
              !name.contains("/"), name != ".", name != ".." else {
            throw RepoRegistrationError.invalidRemoteURL(remoteURL)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destinationParent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RepoRegistrationError.pathDoesNotExist(destinationParent.path)
        }
        let destination = destinationParent.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw RepoRegistrationError.destinationExists(path: destination.path)
        }

        try await cloner.clone(url: url, into: destination)
        let baseBranch = await suggestBaseBranch(at: destination)
        return try await registerRepo(
            path: destination, baseBranch: baseBranch,
            setupScript: setupScript, envCopyList: envCopyList)
    }

    /// The folder name a clone URL lands in: the last path component with any
    /// trailing `.git` and slashes stripped. Handles both scp-style
    /// (`git@host:org/repo.git`) and URL-style (`https://host/org/repo.git`)
    /// remotes; returns nil when nothing usable remains.
    public static func repoName(fromURL url: String) -> String? {
        var s = Substring(url)
        while s.hasSuffix("/") { s = s.dropLast() }
        if let slash = s.lastIndex(of: "/") {
            s = s[s.index(after: slash)...]
        } else if let colon = s.lastIndex(of: ":") {
            s = s[s.index(after: colon)...]
        }
        if s.hasSuffix(".git") { s = s.dropLast(4) }
        return s.isEmpty ? nil : String(s)
    }

    /// Suggests a base branch for a not-yet-registered clone: its current
    /// branch, else the first of the common defaults that exists.
    public func suggestBaseBranch(at path: URL) async -> String {
        if let current = (try? await git.currentBranch(in: path)) ?? nil { return current }
        for candidate in ["main", "develop", "master", "trunk"] {
            if (try? await git.branchExists(candidate, in: path)) == true { return candidate }
        }
        return "main"
    }

    public func updateRepo(_ updated: RepoConfig) throws {
        guard let index = repos.firstIndex(where: { $0.id == updated.id }) else {
            throw RepoRemovalError.unknownRepo(updated.id)
        }
        repos[index] = updated
        try persist()
    }

    public func removeRepo(id: UUID) throws {
        guard repos.contains(where: { $0.id == id }) else {
            throw RepoRemovalError.unknownRepo(id)
        }
        let users = tasks.filter { $0.workspaces.contains { $0.repoId == id } }
        guard users.isEmpty else {
            throw RepoRemovalError.usedByTasks(repoId: id, taskNames: users.map(\.name))
        }
        repos.removeAll { $0.id == id }
        try persist()
    }

    // MARK: - Task lifecycle

    /// Atomic creation (engine) + attention wiring (hooks in the PRIMARY
    /// worktree — `--add-dir` loads no sibling `.claude/` config, verified) +
    /// a ready-to-spawn LaunchPlan with the pre-assigned session id
    /// persisted as the task's sessionRef. Errors propagate typed
    /// (TaskCreationFailure carries cause + rollback account) — the UI
    /// formats them honestly, it never invents a generic message.
    public func createTask(
        name: String, branch: String, repoIds: [UUID]
    ) async throws -> (task: TaskRecord, plan: LaunchPlan) {
        guard !repoIds.isEmpty else { throw TaskEngineError.noReposSelected }
        let selected = try repoIds.map { id in
            guard let repo = repos.first(where: { $0.id == id }) else {
                throw TaskEngineError.unknownRepo(repoId: id)
            }
            return repo
        }
        var task = try await engine.createTask(
            name: name, branch: branch, adapterKind: adapter.kind,
            repos: selected,
            worktreesRootOverride: worktreesRootOverride.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            })

        // The engine created worktrees + branches and rolled back only failures
        // INSIDE createTask. Everything below (hook wiring, launch-plan build,
        // persist) can still throw — e.g. a repo whose base tip carries an
        // invalid committed `.claude/settings.local.json` makes
        // prepareWorkspaceAttention throw. Without a teardown here those
        // worktrees/branches are left on disk but unrecorded in config, and a
        // retry then fails with `branchAlreadyExists` over invisible debris.
        do {
            guard let primary = task.workspaces.first?.worktreeURL else {
                throw TaskEngineError.taskHasNoWorkspaces(taskId: task.id)
            }
            try await adapter.prepareWorkspaceAttention(in: primary, socketPath: socketPath)

            let plan = try adapter.launchPlan(for: try sessionSpec(for: task))
            task.sessionRef = plan.sessionRef
            tasks.append(task)
            attention[task.id] = task.state
            try persist()
            return (task, plan)
        } catch {
            tasks.removeAll { $0.id == task.id }
            attention.removeValue(forKey: task.id)
            await rollBackFailedCreation(task)
            throw error
        }
    }

    /// In-place creation: the session runs in each selected repo's OWN checkout
    /// (no worktree, no branch) — for investigation/learning. Attention hooks
    /// ARE installed into the primary repo's `.claude/settings.local.json`
    /// (merge semantics, git-excluded, reversed on removal) so the session still
    /// drives the attention pipeline. Post-engine wiring failures roll back by
    /// uninstalling those hooks — nothing on disk was branched or copied.
    public func createInPlaceTask(
        name: String, repoIds: [UUID]
    ) async throws -> (task: TaskRecord, plan: LaunchPlan) {
        guard !repoIds.isEmpty else { throw TaskEngineError.noReposSelected }
        let selected = try repoIds.map { id in
            guard let repo = repos.first(where: { $0.id == id }) else {
                throw TaskEngineError.unknownRepo(repoId: id)
            }
            return repo
        }
        var task = try await engine.createInPlaceTask(
            name: name, adapterKind: adapter.kind, repos: selected)

        do {
            guard let primary = task.workspaces.first?.worktreeURL else {
                throw TaskEngineError.taskHasNoWorkspaces(taskId: task.id)
            }
            try await adapter.prepareWorkspaceAttention(in: primary, socketPath: socketPath)

            let plan = try adapter.launchPlan(for: try sessionSpec(for: task))
            task.sessionRef = plan.sessionRef
            tasks.append(task)
            attention[task.id] = task.state
            try persist()
            return (task, plan)
        } catch {
            tasks.removeAll { $0.id == task.id }
            attention.removeValue(forKey: task.id)
            await removeInPlaceAttention(for: task)
            throw error
        }
    }

    // MARK: - Adding workspaces to an already-running task

    /// Adds a NEW worktree (on `branch`, cut from the repo's base) to an existing
    /// task so it also tracks that repo — "now also work on repo B here". The
    /// task's already-running session is untouched; this only extends what
    /// Lighthouse tracks (review pane, merge, removal).
    @discardableResult
    public func addWorktree(
        toTask taskId: UUID, repoId: UUID, branch: String
    ) async throws -> Workspace {
        let (index, task, repo) = try locate(taskId: taskId, repoId: repoId)
        let workspace = try await engine.addWorktreeWorkspace(
            to: task, repo: repo, branch: branch,
            worktreesRootOverride: worktreesRootOverride.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            })
        try appendWorkspace(workspace, toTaskAt: index)
        return workspace
    }

    /// Tracks a registered repo's CURRENT checkout in-place — captures whatever
    /// the agent already changed there. Tracked only: never merged back, never
    /// destroyed on removal.
    @discardableResult
    public func trackInPlace(toTask taskId: UUID, repoId: UUID) async throws -> Workspace {
        let (index, task, repo) = try locate(taskId: taskId, repoId: repoId)
        let workspace = try await engine.inPlaceWorkspace(for: repo, addingTo: task)
        try appendWorkspace(workspace, toTaskAt: index)
        return workspace
    }

    /// Adopts an existing worktree the agent created (matched to a registered
    /// repo by its `worktree list`) as a tracked workspace of the task.
    @discardableResult
    public func adoptWorktree(toTask taskId: UUID, directory: URL) async throws -> Workspace {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else {
            throw TaskEngineError.unknownTask(taskId: taskId)
        }
        let workspace = try await engine.adoptWorktreeWorkspace(
            at: directory, addingTo: tasks[index], repos: repos)
        try appendWorkspace(workspace, toTaskAt: index)
        return workspace
    }

    /// Registered repos NOT already tracked by `task` — the candidates a
    /// worktree/in-place add can choose from.
    public func reposAddableTo(_ task: TaskRecord) -> [RepoConfig] {
        repos.filter { repo in !task.workspaces.contains { $0.repoId == repo.id } }
    }

    private func locate(
        taskId: UUID, repoId: UUID
    ) throws -> (index: Int, task: TaskRecord, repo: RepoConfig) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else {
            throw TaskEngineError.unknownTask(taskId: taskId)
        }
        guard let repo = repos.first(where: { $0.id == repoId }) else {
            throw TaskEngineError.unknownRepo(repoId: repoId)
        }
        return (index, tasks[index], repo)
    }

    private func appendWorkspace(_ workspace: Workspace, toTaskAt index: Int) throws {
        tasks[index].workspaces.append(workspace)
        try persist()
    }

    /// Removes Lighthouse's attention hooks from every in-place workspace's real
    /// repo `.claude/settings.local.json`. For worktree tasks the whole worktree
    /// dir is deleted, taking the hooks with it — but an in-place repo is never
    /// deleted, so its hooks must be uninstalled explicitly or they would
    /// linger. Best-effort: a failure here must never block task removal.
    private func removeInPlaceAttention(for task: TaskRecord) async {
        for workspace in task.workspaces where workspace.isInPlace {
            guard let repo = repos.first(where: { $0.id == workspace.repoId }) else { continue }
            try? await adapter.removeWorkspaceAttention(from: repo.pathURL)
        }
    }

    /// Best-effort teardown of a task the engine created but whose post-engine
    /// wiring failed. Force-destroys regardless of hazards — the task was never
    /// live, so leaving its worktree/branch would only orphan on-disk debris a
    /// retry trips over. Any failure here is swallowed: the caller is already
    /// rethrowing the original, more informative error, and a lingering artifact
    /// is strictly better surfaced through that than masked by a rollback error.
    private func rollBackFailedCreation(_ task: TaskRecord) async {
        let hazards = (try? await engine.removalHazards(in: task, repos: repos)) ?? []
        _ = try? await engine.removeTask(
            task, repos: repos, mode: .destroy(RemovalConfirmation(destroying: hazards)))
    }

    /// Resume plan for a task with a stored sessionRef. Resuming an id whose
    /// history is gone fails fast and visibly in the terminal ("No
    /// conversation found with session ID", exit 1 — verified live).
    public func resumePlan(for task: TaskRecord) throws -> LaunchPlan? {
        guard let ref = task.sessionRef else { return nil }
        // The single `try` covers both the throwing sessionSpec and resumePlan.
        return try adapter.resumePlan(for: sessionSpec(for: task), sessionRef: ref)
    }

    private func sessionSpec(for task: TaskRecord) throws -> SessionSpec {
        let worktrees = task.workspaces.map(\.worktreeURL)
        guard let primary = worktrees.first else {
            throw TaskEngineError.taskHasNoWorkspaces(taskId: task.id)
        }
        return SessionSpec(
            primaryWorktree: primary,
            additionalWorktrees: Array(worktrees.dropFirst()),
            loginShell: loginShell,
            displayName: task.name)
    }

    public func removalHazards(for task: TaskRecord) async throws -> [RemovalHazard] {
        try await engine.removalHazards(in: task, repos: repos)
    }

    @discardableResult
    public func removeTask(
        _ task: TaskRecord, mode: TaskRemovalMode
    ) async throws -> TaskRemovalReport {
        let report = try await engine.removeTask(task, repos: repos, mode: mode)
        // Worktree tasks lose their hooks when the worktree dir is deleted;
        // in-place tasks keep their repo, so uninstall our hooks explicitly.
        await removeInPlaceAttention(for: task)
        tasks.removeAll { $0.id == task.id }
        attention.removeValue(forKey: task.id)
        liveSessions.remove(task.id)
        try persist()
        return report
    }

    // MARK: - Attention

    /// Reducer for socket signals: folds the event through the state machine.
    /// Unknown tasks are ignored (the listener already dropped unknown
    /// sessions; this guards the id-level race after task removal).
    /// Applies a socket signal; returns the resulting transition (if the
    /// state changed) so the runtime can decide on a notification.
    @discardableResult
    public func apply(_ signal: TaskAttentionSignal) -> AttentionTransition? {
        applyEvent(signal.event, to: signal.taskId)
    }

    @discardableResult
    public func noteSessionStarted(taskId: UUID) -> AttentionTransition? {
        guard tasks.contains(where: { $0.id == taskId }) else { return nil }
        liveSessions.insert(taskId)
        return applyEvent(.agentWorking, to: taskId)
    }

    /// Pty death (process exited, window closed the fd, crash) — distinct
    /// from the SessionEnd hook, which may or may not have arrived first;
    /// both fold to the same defined state.
    @discardableResult
    public func noteSessionEnded(taskId: UUID) -> AttentionTransition? {
        liveSessions.remove(taskId)
        return applyEvent(.sessionDied, to: taskId)
    }

    @discardableResult
    private func applyEvent(_ event: AttentionEvent, to taskId: UUID) -> AttentionTransition? {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return nil }
        let current = attention[taskId] ?? tasks[index].state
        let next = AttentionStateMachine.nextState(from: current, on: event)
        guard next != current else { return nil }
        attention[taskId] = next
        attentionSince[taskId] = now()
        tasks[index].state = next
        try? persist() // state persistence is best-effort; next save catches up
        return AttentionTransition(taskId: taskId, event: event, oldState: current, newState: next)
    }

    /// Number of tasks currently needing input — the dock badge count.
    public var needsInputCount: Int {
        tasks.reduce(0) { $0 + (attentionState(of: $1.id) == .needsInput ? 1 : 0) }
    }

    public func attentionState(of taskId: UUID) -> TaskAttentionState {
        attention[taskId] ?? .done
    }

    /// When a task entered its current attention state (its last transition),
    /// or nil if unknown. Honest data for the Harbor card's relative-time slot
    /// — `attentionSince` was private; the Harbor UI needs a read accessor and
    /// this exposes exactly the recorded value (never a fabricated time).
    public func attentionSince(of taskId: UUID) -> Date? {
        attentionSince[taskId]
    }

    /// Records that every workspace of a task merged into base — the task is
    /// done (spec §2.5). Marks each workspace merged and persists.
    public func markMerged(taskId: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        for wsIndex in tasks[index].workspaces.indices {
            tasks[index].workspaces[wsIndex].mergeState = .merged
        }
        try? persist()
    }

    /// Records the current per-workspace merge states of a paused/partial
    /// walk so partially-merged is visible after the walk object is gone.
    public func updateMergeStates(taskId: UUID, merged: [UUID], conflicted: [UUID]) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        for wsIndex in tasks[index].workspaces.indices {
            let repoId = tasks[index].workspaces[wsIndex].repoId
            if merged.contains(repoId) {
                tasks[index].workspaces[wsIndex].mergeState = .merged
            } else if conflicted.contains(repoId) {
                tasks[index].workspaces[wsIndex].mergeState = .conflicted
            }
        }
        try? persist()
    }

    // MARK: - Derivations for the UI

    /// A task can be resumed whenever it has a persisted session and the agent
    /// is not actively working. With persistent shells the pty outlives
    /// Claude, so "no live pty" is no longer the signal — the runtime resumes
    /// by typing `claude --resume` into the live shell (or a fresh tab).
    public func canResume(_ task: TaskRecord) -> Bool {
        task.sessionRef != nil && attentionState(of: task.id) != .working
    }

    /// Quitting kills in-flight agent work (pty death); these tasks make the
    /// quit confirmation mandatory (spec §3).
    public func tasksBlockingQuit() -> [TaskRecord] {
        tasks.filter { liveSessions.contains($0.id) && attentionState(of: $0.id) == .working }
    }

    private func inboxItem(_ task: TaskRecord) -> InboxItem {
        InboxItem(
            id: task.id, name: task.name, state: attentionState(of: task.id),
            since: attentionSince[task.id] ?? .distantPast)
    }

    /// The authoritative "what needs me" order (spec §6 step 7): needs-input
    /// (oldest-blocked first), then working, dirty, done. Used by the Cmd+K
    /// inbox with no query.
    public func inboxOrder() -> [TaskRecord] {
        let byId = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        return InboxOrder.ordered(tasks.map(inboxItem)).compactMap { byId[$0.id] }
    }

    /// The Harbor grid order (spec §5.1): needs → working → idle → stale.
    /// DISTINCT from `inboxOrder()` (⌘K keeps its needs→working→dirty→done).
    /// The active filter chip is applied by the view over this ordered list.
    public func harborOrder() -> [TaskRecord] {
        let byId = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        return HarborOrder.ordered(tasks.map(inboxItem)).compactMap { byId[$0.id] }
    }

    /// Cmd+K entries: with no query, the authoritative inbox order; with a
    /// query, fuzzy-filtered but still needs-input-first (inbox semantics),
    /// then by match quality, then name.
    public func switcherEntries(query: String) -> [TaskRecord] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return inboxOrder() }
        let scored: [(TaskRecord, Int)] = tasks.compactMap { task in
            FuzzyMatcher.score(query: query, candidate: task.name).map { (task, $0) }
        }
        return scored.sorted { lhs, rhs in
            let lhsNeedsInput = attentionState(of: lhs.0.id) == .needsInput
            let rhsNeedsInput = attentionState(of: rhs.0.id) == .needsInput
            if lhsNeedsInput != rhsNeedsInput { return lhsNeedsInput }
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.name.localizedCompare(rhs.0.name) == .orderedAscending
        }.map(\.0)
    }

    /// Branch prefill from a task name: "Fix Payments  API!" → "task/fix-payments-api".
    nonisolated public static func branchSlug(from name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
        var slug = ""
        var lastWasDash = true // suppress leading dash
        for character in folded {
            if character.isLetter || character.isNumber {
                slug.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "task/new" : "task/\(slug)"
    }
}
