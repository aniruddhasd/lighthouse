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
/// per-task session liveness, and the orchestration of TaskEngine + adapter
/// for creation/resume/removal. Deliberately free of any UI import — every
/// rule here is unit-tested. The UI layer owns SwiftTerm and feeds this model
/// session lifecycle via `noteSessionStarted` / `noteSessionEnded`.
@MainActor @Observable
public final class AppModel {
    public private(set) var repos: [RepoConfig] = []
    public private(set) var tasks: [TaskRecord] = []
    /// Task ids with a live pty right now — maintained by the session layer.
    /// This is the ONE honest, Lighthouse-observed status signal (it spawns and
    /// reaps the shell itself); everything the UI shows as "active" derives from
    /// it, not from agent hooks. Semantic status is user-set free text
    /// (`TaskRecord.status`).
    public private(set) var liveSessions: Set<UUID> = []
    /// When each task last started/ended a session — session-only, drives the
    /// "most recent first" ordering and the Harbor card's relative-time slot.
    private var lastActivity: [UUID: Date] = [:]
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
    private let prCheckout: PullRequestCheckout
    private let adapter: any AgentAdapter
    private let loginShell: String

    public init(
        store: ConfigStore,
        adapter: any AgentAdapter,
        git: GitClient = GitClient(),
        cloner: RepoCloner = RepoCloner(),
        prCheckout: PullRequestCheckout = PullRequestCheckout(),
        loginShell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.adapter = adapter
        self.git = git
        self.cloner = cloner
        self.prCheckout = prCheckout
        self.engine = TaskEngine(git: git)
        self.loginShell = loginShell
        self.now = now
    }

    /// Loads persisted state. No session is live the instant we start (terminal
    /// controllers are in-memory and die with the app), so `liveSessions` begins
    /// empty and every task reads as inactive until a session is launched.
    public func load() throws {
        let config = try store.load()
        repos = config.repos
        tasks = config.tasks
        worktreesRootOverride = config.worktreesRootOverride
        hasCompletedSetup = config.hasCompletedSetup
        notificationsHintDismissed = config.notificationsHintDismissed
        theme = config.theme
        startView = config.startView
        showBeam = config.showBeam
        // Clamp on load too: a hand-edited config can carry an out-of-range size.
        terminalFontSize = config.terminalFontSize.clamped(to: Self.terminalFontRange)
        lastActivity = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, now()) })
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
        lastActivity[task.id] = now()
    }

    /// Debug-only sibling of insertEphemeralTask for the repo the probe's
    /// workspace points at — visible to the UI, excluded from every save.
    public func insertEphemeralRepo(_ repo: RepoConfig) {
        ephemeralRepoIds.insert(repo.id)
        repos.append(repo)
    }

    // MARK: - Scratch terminal (repo-less)

    /// Creates a repo-less scratch-terminal task: NO workspaces (so no diff /
    /// review surface — `workspaces.isEmpty` is the UI's "terminal-only"
    /// discriminator), and ephemeral (reuses `insertEphemeralTask`, so it is
    /// excluded from every save and dies with the app). `directory` is stored in
    /// `branch` purely so the header/card can show where the shell is; there is
    /// no branch semantics for a shell. `adapterKind` is "scratch" as a marker.
    @discardableResult
    public func createScratchTask(directory: URL) -> TaskRecord {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let label = directory.standardizedFileURL.path == home
            ? "Home" : directory.lastPathComponent
        let task = TaskRecord(
            name: label.isEmpty ? "Scratch" : label,
            branch: directory.path, adapterKind: "scratch",
            sessionRef: nil, workspaces: [])
        insertEphemeralTask(task)
        return task
    }

    /// Tears a scratch task out of the model. No engine / worktree work — a
    /// scratch task owns nothing on disk — so this never touches `store`.
    public func removeScratchTask(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        ephemeralTaskIds.remove(id)
        lastActivity.removeValue(forKey: id)
        liveSessions.remove(id)
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

    /// Atomic creation (engine) + a ready-to-spawn LaunchPlan with the
    /// pre-assigned session id persisted as the task's sessionRef. Errors
    /// propagate typed (TaskCreationFailure carries cause + rollback account) —
    /// the UI formats them honestly, it never invents a generic message.
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
        // INSIDE createTask. The launch-plan build + persist below can still
        // throw; without a teardown here those worktrees/branches would be left
        // on disk but unrecorded, and a retry would fail with branchAlreadyExists
        // over invisible debris.
        do {
            let plan = try adapter.launchPlan(for: try sessionSpec(for: task))
            task.sessionRef = plan.sessionRef
            tasks.append(task)
            lastActivity[task.id] = now()
            try persist()
            return (task, plan)
        } catch {
            tasks.removeAll { $0.id == task.id }
            lastActivity.removeValue(forKey: task.id)
            await rollBackFailedCreation(task)
            throw error
        }
    }

    /// In-place creation: the session runs in each selected repo's OWN checkout
    /// (no worktree, no branch) — for investigation/learning. Nothing on disk is
    /// branched or copied, so a post-engine failure just drops the record.
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
            let plan = try adapter.launchPlan(for: try sessionSpec(for: task))
            task.sessionRef = plan.sessionRef
            tasks.append(task)
            lastActivity[task.id] = now()
            try persist()
            return (task, plan)
        } catch {
            tasks.removeAll { $0.id == task.id }
            lastActivity.removeValue(forKey: task.id)
            throw error
        }
    }

    /// Creates a task from a GitHub pull request: a worktree checked out on the
    /// PR's head (local branch `pr-<N>`, tracking the PR so commits push back).
    /// `reference` is a PR number or URL. A NETWORK op — resolves + fetches via
    /// `gh`. On any failure the (possibly empty) worktree is rolled back, so a
    /// retry never trips over debris.
    public func createTaskFromPR(
        reference: String, repoId: UUID, name: String? = nil
    ) async throws -> (task: TaskRecord, plan: LaunchPlan) {
        guard let repo = repos.first(where: { $0.id == repoId }) else {
            throw TaskEngineError.unknownRepo(repoId: repoId)
        }
        let info = try await prCheckout.resolve(reference: reference, in: repo.pathURL)
        let taskName = Self.taskName(fromPR: info, override: name)
        let localBranch = PullRequestCheckout.localBranch(for: info.number)
        let destination = TaskEngine.worktreeDestination(
            for: repo, taskName: taskName,
            worktreesRootOverride: worktreesRootOverride.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            })
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw TaskEngineError.worktreeDestinationOccupied(path: destination.path)
        }

        // Detached worktree first, then `gh pr checkout` INSIDE it (network).
        // Any failure past the worktree creation removes it before rethrowing.
        try await git.addDetachedWorktree(at: destination, from: "HEAD", in: repo.pathURL)
        do {
            try await prCheckout.checkout(
                reference: reference, localBranch: localBranch, in: destination)
        } catch {
            try? await git.removeWorktree(
                at: destination, in: repo.pathURL,
                mode: .forceDiscardingChanges(
                    justification: "PR checkout failed; removing the empty worktree"))
            // gh may have created the local branch before failing; drop it so a
            // retry doesn't trip over an existing `pr-<N>`.
            try? await git.deleteBranch(localBranch, force: true, in: repo.pathURL)
            throw error
        }

        var task = TaskRecord(
            name: taskName, branch: localBranch, adapterKind: adapter.kind,
            sessionRef: nil,
            workspaces: [Workspace(
                repoId: repo.id, worktreePath: destination.path, mergeState: .unmerged)])
        do {
            let plan = try adapter.launchPlan(for: try sessionSpec(for: task))
            task.sessionRef = plan.sessionRef
            tasks.append(task)
            lastActivity[task.id] = now()
            try persist()
            return (task, plan)
        } catch {
            tasks.removeAll { $0.id == task.id }
            lastActivity.removeValue(forKey: task.id)
            await rollBackFailedCreation(task)
            throw error
        }
    }

    /// The task's display name: an explicit override, else the PR title made
    /// path-safe (it becomes a worktree directory component), falling back to
    /// `pr-<N>` when nothing usable remains.
    static func taskName(fromPR info: PullRequestInfo, override: String?) -> String {
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        let safe = info.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (safe.isEmpty || safe == "." || safe == "..") ? "pr-\(info.number)" : safe
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
        tasks.removeAll { $0.id == task.id }
        lastActivity.removeValue(forKey: task.id)
        liveSessions.remove(task.id)
        try persist()
        return report
    }

    // MARK: - Session liveness (the one honest, hook-free status signal)

    /// Records that a live pty exists for this task (the session layer calls
    /// this when it spawns the shell). No agent-status inference — Lighthouse
    /// only knows a session is LIVE, never what the agent is doing.
    public func noteSessionStarted(taskId: UUID) {
        guard tasks.contains(where: { $0.id == taskId }) else { return }
        liveSessions.insert(taskId)
        lastActivity[taskId] = now()
    }

    /// Records that the pty died (process exited, fd closed, crash).
    public func noteSessionEnded(taskId: UUID) {
        liveSessions.remove(taskId)
        lastActivity[taskId] = now()
    }

    /// Whether a session is live for this task right now — the sole basis for
    /// every "active" affordance (the live dot, quit-safety, resume-gating).
    public func isSessionLive(_ taskId: UUID) -> Bool {
        liveSessions.contains(taskId)
    }

    /// When the task last started/ended a session, or nil if never — honest data
    /// for the Harbor card's relative-time slot (never a fabricated time).
    public func lastActivity(of taskId: UUID) -> Date? {
        lastActivity[taskId]
    }

    /// Sets the user's free-text status on a task and persists it. Trimmed;
    /// empty clears it. This is the only thing that changes a task's status now.
    public func setStatus(_ status: String, for taskId: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tasks[index].status != trimmed else { return }
        tasks[index].status = trimmed
        try? persist() // best-effort; next save catches up
    }

    /// Overrides the "vs base" diff base branch for one task's workspace
    /// (identified by its repo). `base` nil/empty reverts to the repo default.
    /// Persisted so the choice survives a relaunch.
    public func setWorkspaceBaseOverride(taskId: UUID, repoId: UUID, base: String?) {
        guard let ti = tasks.firstIndex(where: { $0.id == taskId }),
              let wi = tasks[ti].workspaces.firstIndex(where: { $0.repoId == repoId }) else { return }
        let trimmed = base?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard tasks[ti].workspaces[wi].baseOverride != normalized else { return }
        tasks[ti].workspaces[wi].baseOverride = normalized
        try? persist() // best-effort; next save catches up
    }

    // MARK: - Derivations for the UI

    /// A task can be resumed whenever it has a persisted session and no session
    /// is currently live (a live session is already open — go to it, don't
    /// resume). The runtime resumes by typing `claude --resume` into a shell.
    public func canResume(_ task: TaskRecord) -> Bool {
        task.sessionRef != nil && !liveSessions.contains(task.id)
    }

    /// Quitting kills in-flight agent work (pty death); any task with a live
    /// session makes the quit confirmation mandatory.
    public func tasksBlockingQuit() -> [TaskRecord] {
        tasks.filter { liveSessions.contains($0.id) }
    }

    /// The one task order, used by both the Harbor grid and ⌘K: live sessions
    /// first, then most-recent activity, then name, then id — a deterministic
    /// total order (there is no attention hierarchy to sort by any more).
    public func orderedTasks() -> [TaskRecord] {
        tasks.sorted(by: taskPrecedes)
    }

    /// The id reached by stepping `delta` (±1) through `ids` from `current`,
    /// wrapping at both ends — the keyboard task-navigation primitive. From no
    /// selection, `+1` lands on the first and `-1` on the last. Returns nil only
    /// when `ids` is empty. Pure, so the wrap/seed edge cases are unit-tested.
    public static func stepTask(ids: [UUID], from current: UUID?, delta: Int) -> UUID? {
        guard !ids.isEmpty else { return nil }
        let index = current.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : 0)
        let next = ((index + delta) % ids.count + ids.count) % ids.count
        return ids[next]
    }

    private func taskPrecedes(_ a: TaskRecord, _ b: TaskRecord) -> Bool {
        let aLive = liveSessions.contains(a.id), bLive = liveSessions.contains(b.id)
        if aLive != bLive { return aLive }
        let aAt = lastActivity[a.id] ?? .distantPast, bAt = lastActivity[b.id] ?? .distantPast
        if aAt != bAt { return aAt > bAt }
        let byName = a.name.localizedCompare(b.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return a.id.uuidString < b.id.uuidString
    }

    /// Cmd+K entries: with no query, the standard task order; with a query,
    /// fuzzy-filtered by match quality, then name.
    public func switcherEntries(query: String) -> [TaskRecord] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return orderedTasks() }
        let scored: [(TaskRecord, Int)] = tasks.compactMap { task in
            FuzzyMatcher.score(query: query, candidate: task.name).map { (task, $0) }
        }
        return scored.sorted { lhs, rhs in
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
