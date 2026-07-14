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
}

public enum RepoRemovalError: Error, Sendable, Equatable {
    /// Repos referenced by tasks can't be removed out from under them.
    case usedByTasks(repoId: UUID, taskNames: [String])
    case unknownRepo(UUID)
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
    private let adapter: any AgentAdapter
    private let socketPath: URL
    private let loginShell: String

    public init(
        store: ConfigStore,
        socketPath: URL,
        adapter: any AgentAdapter,
        git: GitClient = GitClient(),
        loginShell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.socketPath = socketPath
        self.adapter = adapter
        self.git = git
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
            notificationsHintDismissed: notificationsHintDismissed))
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

        let primary = task.workspaces[0].worktreeURL
        try await adapter.prepareWorkspaceAttention(in: primary, socketPath: socketPath)

        let plan = try adapter.launchPlan(for: sessionSpec(for: task))
        task.sessionRef = plan.sessionRef
        tasks.append(task)
        attention[task.id] = task.state
        try persist()
        return (task, plan)
    }

    /// Resume plan for a task with a stored sessionRef. Resuming an id whose
    /// history is gone fails fast and visibly in the terminal ("No
    /// conversation found with session ID", exit 1 — verified live).
    public func resumePlan(for task: TaskRecord) throws -> LaunchPlan? {
        guard let ref = task.sessionRef else { return nil }
        return try adapter.resumePlan(for: sessionSpec(for: task), sessionRef: ref)
    }

    private func sessionSpec(for task: TaskRecord) -> SessionSpec {
        let worktrees = task.workspaces.map(\.worktreeURL)
        return SessionSpec(
            primaryWorktree: worktrees[0],
            additionalWorktrees: Array(worktrees.dropFirst()),
            loginShell: loginShell,
            displayName: task.name)
    }

    public func unmergedWork(for task: TaskRecord) async throws -> [UnmergedWorkItem] {
        try await engine.unmergedWork(in: task, repos: repos)
    }

    @discardableResult
    public func removeTask(
        _ task: TaskRecord, mode: TaskRemovalMode
    ) async throws -> TaskRemovalReport {
        let report = try await engine.removeTask(task, repos: repos, mode: mode)
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
