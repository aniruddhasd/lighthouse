import Foundation
import Testing
import LighthouseAdapter
import LighthouseFixtures
import LighthouseGit
import LighthouseTaskEngine
@testable import LighthouseAppCore

@MainActor
@Suite("AppModel (fixture repos)")
final class AppModelTests {
    private let fixtures: FixtureFactory
    private let storeDirectory: URL
    private let model: AppModel

    init() throws {
        fixtures = try FixtureFactory()
        storeDirectory = fixtures.root.appendingPathComponent("store", isDirectory: true)
        model = AppModel(
            store: ConfigStore(directory: storeDirectory),
            socketPath: fixtures.root.appendingPathComponent("attention.sock"),
            adapter: ClaudeCodeAdapter(),
            loginShell: "/bin/zsh")
        try model.load()
    }

    deinit {
        try? fixtures.destroy()
    }

    // MARK: Repo registration — failures first

    @Test func registeringNonexistentPathFails() async throws {
        let ghost = fixtures.root.appendingPathComponent("nope")
        await #expect {
            try await self.model.registerRepo(path: ghost, baseBranch: "main")
        } throws: { error in
            error as? RepoRegistrationError == .pathDoesNotExist(ghost.path)
        }
        #expect(model.repos.isEmpty)
    }

    @Test func registeringNonRepoDirectoryFails() async throws {
        let dir = try fixtures.nonRepoDirectory()
        await #expect {
            try await self.model.registerRepo(path: dir, baseBranch: "main")
        } throws: { error in
            error as? RepoRegistrationError == .notAGitRepository(dir.path)
        }
    }

    @Test func registeringASubdirectoryFails() async throws {
        let repo = try fixtures.cleanRepo()
        let subdir = repo.path.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        await #expect {
            try await self.model.registerRepo(path: subdir, baseBranch: "main")
        } throws: { error in
            guard case .notTheRepositoryRoot(let path, _) = error as? RepoRegistrationError else {
                return false
            }
            return path == subdir.path
        }
    }

    @Test func duplicateRegistrationFails() async throws {
        let repo = try fixtures.cleanRepo()
        try await model.registerRepo(path: repo.path, baseBranch: "main")
        await #expect {
            try await self.model.registerRepo(path: repo.path, baseBranch: "main")
        } throws: { error in
            guard case .alreadyRegistered = error as? RepoRegistrationError else { return false }
            return true
        }
        #expect(model.repos.count == 1)
    }

    @Test func missingBaseBranchFails() async throws {
        let repo = try fixtures.cleanRepo()
        await #expect {
            try await self.model.registerRepo(path: repo.path, baseBranch: "no-such")
        } throws: { error in
            error as? RepoRegistrationError
                == .baseBranchMissing(path: repo.path.path, baseBranch: "no-such")
        }
    }

    @Test func optionLookalikeBaseBranchRejectedAtRegistration() async throws {
        let repo = try fixtures.cleanRepo()
        await #expect {
            try await self.model.registerRepo(path: repo.path, baseBranch: "--output=/tmp/pwn")
        } throws: { error in
            error as? RepoRegistrationError == .invalidBaseBranchName("--output=/tmp/pwn")
        }
        #expect(model.repos.isEmpty)
        // Not persisted either — nothing to load back.
        #expect(try ConfigStore(directory: storeDirectory).load().repos.isEmpty)
    }

    @Test func registrationPersistsAcrossReload() async throws {
        let repo = try fixtures.cleanRepo()
        let registered = try await model.registerRepo(
            path: repo.path, baseBranch: "main", envCopyList: [".env"])

        let reloaded = AppModel(
            store: ConfigStore(directory: storeDirectory),
            socketPath: fixtures.root,
            adapter: ClaudeCodeAdapter(), loginShell: "/bin/zsh")
        try reloaded.load()
        #expect(reloaded.repos == [registered])
    }

    @Test func removingRepoUsedByTaskFails() async throws {
        let repo = try fixtures.cleanRepo()
        let registered = try await model.registerRepo(path: repo.path, baseBranch: "main")
        _ = try await model.createTask(
            name: "uses-repo", branch: "task/uses-repo", repoIds: [registered.id])
        #expect {
            try self.model.removeRepo(id: registered.id)
        } throws: { error in
            error as? RepoRemovalError
                == .usedByTasks(repoId: registered.id, taskNames: ["uses-repo"])
        }
        #expect(model.repos.count == 1)
    }

    // MARK: Task creation through the model

    @Test func creationFailurePropagatesTypedAndPersistsNothing() async throws {
        let repo = try fixtures.cleanRepo()
        let registered = try await model.registerRepo(path: repo.path, baseBranch: "main")
        try fixtures.git(["branch", "task/collide"], in: repo.path)

        await #expect {
            _ = try await self.model.createTask(
                name: "collide", branch: "task/collide", repoIds: [registered.id])
        } throws: { error in
            guard let failure = error as? TaskCreationFailure,
                  case .branchAlreadyExists = failure.cause else { return false }
            return true
        }
        #expect(model.tasks.isEmpty)
        // Nothing persisted either.
        let reloaded = try ConfigStore(directory: storeDirectory).load()
        #expect(reloaded.tasks.isEmpty)
    }

    /// A failure AFTER the engine finished creating (here: the base tip carries
    /// an invalid committed `.claude/settings.local.json`, so hook installation
    /// throws) must tear the engine's worktree + branch back down — otherwise a
    /// retry trips over `branchAlreadyExists` on invisible on-disk debris.
    @Test func postEngineFailureRollsBackWorktreeAndBranch() async throws {
        let repo = try fixtures.cleanRepo()
        // Commit an invalid settings file onto main so the created worktree
        // checks it out and hook install refuses it (existingSettingsInvalid).
        let claudeDir = repo.path.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try "{ not valid json".write(
            to: claudeDir.appendingPathComponent("settings.local.json"),
            atomically: true, encoding: .utf8)
        // Force-add: `.claude/` is commonly in a global/XDG gitignore, which git
        // still honours even with GIT_CONFIG_GLOBAL masked, so a plain add would
        // stage nothing and the commit would be empty.
        _ = try fixtures.git(
            ["add", "-f", ".claude/settings.local.json"], in: repo.path)
        _ = try fixtures.git(["commit", "-m", "poison settings"], in: repo.path)
        let registered = try await model.registerRepo(path: repo.path, baseBranch: "main")

        await #expect {
            _ = try await self.model.createTask(
                name: "poisoned", branch: "task/poisoned", repoIds: [registered.id])
        } throws: { error in
            guard case .existingSettingsInvalid = error as? HookInstallerError else { return false }
            return true
        }

        // Model + store hold nothing.
        #expect(model.tasks.isEmpty)
        #expect(try ConfigStore(directory: storeDirectory).load().tasks.isEmpty)
        // And crucially: no orphaned worktree or branch on disk.
        let destination = TaskEngine.worktreeDestination(
            for: registered, taskName: "poisoned", worktreesRootOverride: nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let branches = try fixtures.git(["branch", "--list", "task/poisoned"], in: repo.path)
        #expect(branches.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        // Debris-free means a retry is possible: register a clean repo path is
        // not needed — recommitting valid settings lets the SAME branch name
        // succeed, proving the branch was really deleted.
        _ = try fixtures.git(["rm", "-f", ".claude/settings.local.json"], in: repo.path)
        _ = try fixtures.git(["commit", "-m", "drop settings"], in: repo.path)
        let (task, _) = try await model.createTask(
            name: "poisoned", branch: "task/poisoned", repoIds: [registered.id])
        #expect(model.tasks == [task])
    }

    @Test func creatingWithNoReposSelectedThrowsRatherThanCrashing() async throws {
        await #expect {
            _ = try await self.model.createTask(
                name: "no-repos", branch: "task/no-repos", repoIds: [])
        } throws: { error in
            guard let engineError = error as? TaskEngineError,
                  case .noReposSelected = engineError else { return false }
            return true
        }
        #expect(model.tasks.isEmpty)
    }

    @Test func createTaskWiresSessionHooksAndPlan() async throws {
        let repoA = try fixtures.cleanRepo()
        let repoB = try fixtures.cleanRepo()
        let a = try await model.registerRepo(path: repoA.path, baseBranch: "main")
        let b = try await model.registerRepo(path: repoB.path, baseBranch: "main")

        let (task, plan) = try await model.createTask(
            name: "cross repo", branch: "task/cross-repo", repoIds: [a.id, b.id])

        // Session ref persisted and pre-assigned in the plan.
        #expect(task.sessionRef == plan.sessionRef)
        #expect(UUID(uuidString: plan.sessionRef) != nil)
        #expect(model.tasks == [task])

        // The typed command: session id, display name, sibling add-dir.
        let command = try #require(plan.typedCommand)
        #expect(plan.arguments == ["-l", "-i"])
        #expect(command.contains("--session-id"))
        #expect(command.contains("-n"))
        #expect(command.contains("'cross repo'"))
        #expect(command.contains("--add-dir"))
        #expect(command.contains(task.workspaces[1].worktreePath))
        #expect(plan.workingDirectory.path == task.workspaces[0].worktreePath)

        // Hooks live in the PRIMARY worktree only (--add-dir loads no
        // sibling .claude config — verified contract fact).
        let primarySettings = task.workspaces[0].worktreeURL
            .appendingPathComponent(".claude/settings.local.json")
        let siblingSettings = task.workspaces[1].worktreeURL
            .appendingPathComponent(".claude/settings.local.json")
        #expect(FileManager.default.fileExists(atPath: primarySettings.path))
        #expect(!FileManager.default.fileExists(atPath: siblingSettings.path))
    }

    @Test func worktreesRootOverrideFlowsIntoCreationAndPersists() async throws {
        let repo = try fixtures.cleanRepo()
        let registered = try await model.registerRepo(path: repo.path, baseBranch: "main")
        let override = fixtures.root.appendingPathComponent("override root", isDirectory: true)
        try model.setWorktreesRootOverride(override.path)

        let (task, _) = try await model.createTask(
            name: "ov", branch: "task/ov", repoIds: [registered.id])
        #expect(task.workspaces[0].worktreePath
            == override.appendingPathComponent("ov/\(repo.path.lastPathComponent)").path)

        let reloaded = AppModel(
            store: ConfigStore(directory: storeDirectory),
            socketPath: fixtures.root,
            adapter: ClaudeCodeAdapter(), loginShell: "/bin/zsh")
        try reloaded.load()
        #expect(reloaded.worktreesRootOverride == override.path)
    }

    @Test func removalThroughModelUpdatesStateAndStore() async throws {
        let repo = try fixtures.cleanRepo()
        let registered = try await model.registerRepo(path: repo.path, baseBranch: "main")
        let (task, _) = try await model.createTask(
            name: "short-lived", branch: "task/short-lived", repoIds: [registered.id])

        try await model.removeTask(task, mode: .refuseIfHazards)
        #expect(model.tasks.isEmpty)
        #expect(model.attention[task.id] == nil)
        let reloaded = try ConfigStore(directory: storeDirectory).load()
        #expect(reloaded.tasks.isEmpty)
    }

    // MARK: UI preferences (Phase 5 — startView / showBeam setters)

    /// The start-view preference persists through ConfigStore and comes back on
    /// a fresh model (mirrors a relaunch). Defaults to "harbor".
    @Test func startViewPreferencePersistsAcrossReload() throws {
        #expect(model.startView == "harbor")
        model.setStartView("focus")
        #expect(model.startView == "focus")

        let reloaded = AppModel(
            store: ConfigStore(directory: storeDirectory),
            socketPath: fixtures.root,
            adapter: ClaudeCodeAdapter(), loginShell: "/bin/zsh")
        try reloaded.load()
        #expect(reloaded.startView == "focus")
    }

    /// The ambient-beam preference persists through ConfigStore and comes back
    /// on a fresh model. Defaults to true (beam on).
    @Test func showBeamPreferencePersistsAcrossReload() throws {
        #expect(model.showBeam == true)
        model.setShowBeam(false)
        #expect(model.showBeam == false)

        let reloaded = AppModel(
            store: ConfigStore(directory: storeDirectory),
            socketPath: fixtures.root,
            adapter: ClaudeCodeAdapter(), loginShell: "/bin/zsh")
        try reloaded.load()
        #expect(reloaded.showBeam == false)
    }

    /// A redundant set is a no-op (mirrors `setTheme`): the value is unchanged
    /// and nothing new is written to churn.
    @Test func redundantPreferenceSetsAreNoOps() throws {
        model.setStartView("harbor") // already the default
        #expect(model.startView == "harbor")
        model.setShowBeam(true)       // already the default
        #expect(model.showBeam == true)

        let reloaded = AppModel(
            store: ConfigStore(directory: storeDirectory),
            socketPath: fixtures.root,
            adapter: ClaudeCodeAdapter(), loginShell: "/bin/zsh")
        try reloaded.load()
        #expect(reloaded.startView == "harbor")
        #expect(reloaded.showBeam == true)
    }

    // MARK: Attention reducer

    private func makeTask(named name: String = "attn") async throws -> TaskRecord {
        let repo = try fixtures.cleanRepo()
        let registered = try await model.registerRepo(path: repo.path, baseBranch: "main")
        return try await model.createTask(
            name: name, branch: AppModel.branchSlug(from: name), repoIds: [registered.id]).task
    }

    @Test func signalsFoldThroughTheStateMachine() async throws {
        let task = try await makeTask()
        model.noteSessionStarted(taskId: task.id)
        #expect(model.attentionState(of: task.id) == .working)

        model.apply(TaskAttentionSignal(
            taskId: task.id, sessionRef: task.sessionRef!, event: .agentNeedsInput))
        #expect(model.attentionState(of: task.id) == .needsInput)

        model.apply(TaskAttentionSignal(
            taskId: task.id, sessionRef: task.sessionRef!, event: .agentStopped))
        #expect(model.attentionState(of: task.id) == .done)
    }

    @Test func unknownTaskSignalsAreIgnored() async throws {
        _ = try await makeTask()
        let before = model.attention
        model.apply(TaskAttentionSignal(
            taskId: UUID(), sessionRef: "ghost", event: .agentNeedsInput))
        #expect(model.attention == before)
    }

    @Test func outOfOrderEventsLandDefined() async throws {
        let task = try await makeTask()
        model.noteSessionStarted(taskId: task.id)
        // Straggling stop after death must not hide the orphaned state.
        model.noteSessionEnded(taskId: task.id)
        model.apply(TaskAttentionSignal(
            taskId: task.id, sessionRef: task.sessionRef!, event: .agentStopped))
        #expect(model.attentionState(of: task.id) == .dirty)
    }

    @Test func attentionStatePersistsAcrossReload() async throws {
        let task = try await makeTask()
        model.noteSessionStarted(taskId: task.id)
        model.apply(TaskAttentionSignal(
            taskId: task.id, sessionRef: task.sessionRef!, event: .agentNeedsInput))

        let reloaded = AppModel(
            store: ConfigStore(directory: storeDirectory),
            socketPath: fixtures.root,
            adapter: ClaudeCodeAdapter(), loginShell: "/bin/zsh")
        try reloaded.load()
        #expect(reloaded.attentionState(of: task.id) == .needsInput)
    }

    // MARK: Load-seed reconciliation of a stale `.working`

    /// Craft a persisted task with a chosen state + sessionRef, write it to the
    /// store, and return a fresh model loaded from disk (mirrors a relaunch).
    private func reloadFrom(state: TaskAttentionState, sessionRef: String?) throws -> (AppModel, UUID) {
        let record = TaskRecord(
            name: "resurrected", branch: "task/resurrected", adapterKind: "claude-code",
            sessionRef: sessionRef, state: state,
            workspaces: [Workspace(
                repoId: UUID(),
                worktreePath: fixtures.root.appendingPathComponent("wt").path,
                mergeState: .unmerged)])
        try ConfigStore(directory: storeDirectory).save(LighthouseConfig(tasks: [record]))
        let reloaded = AppModel(
            store: ConfigStore(directory: storeDirectory),
            socketPath: fixtures.root,
            adapter: ClaudeCodeAdapter(), loginShell: "/bin/zsh")
        try reloaded.load()
        return (reloaded, record.id)
    }

    /// A task last persisted as `.working` (no pty can be live at load) must come
    /// back `.dirty` so Resume and the interrupted-workspace warning both appear.
    /// This FAILS on the unpatched load(), which seeds `.working` verbatim →
    /// canResume == false → the dead-end "No session for this task." pane.
    @Test func loadReconcilesPersistedWorkingToDirty() async throws {
        let (reloaded, taskId) = try reloadFrom(state: .working, sessionRef: "sess-live")
        #expect(reloaded.attentionState(of: taskId) == .dirty)
        let task = try #require(reloaded.tasks.first { $0.id == taskId })
        #expect(reloaded.canResume(task))
    }

    /// Every non-`.working` persisted state is truthful and seeds unchanged.
    @Test func loadLeavesNonWorkingStatesUntouched() async throws {
        for state in [TaskAttentionState.dirty, .done, .needsInput] {
            let (reloaded, taskId) = try reloadFrom(state: state, sessionRef: "sess-\(state.rawValue)")
            #expect(reloaded.attentionState(of: taskId) == state)
        }
    }

    /// The reconciliation lives ONLY at the load seam: a genuine in-session
    /// transition to `.working` via the state machine is never rewritten to
    /// `.dirty`. Guards against the fix leaking into the live pipeline.
    @Test func liveWorkingTransitionIsNotReconciled() async throws {
        let task = try await makeTask()
        model.noteSessionStarted(taskId: task.id) // live → .working
        #expect(model.attentionState(of: task.id) == .working)
        model.apply(TaskAttentionSignal(
            taskId: task.id, sessionRef: task.sessionRef!, event: .agentWorking))
        #expect(model.attentionState(of: task.id) == .working)
    }

    // MARK: Derivations

    @Test func resumeAffordanceMatrix() async throws {
        // Persistent-shell model: resume is available whenever there's a
        // session and the agent is not actively working (the runtime types
        // `claude --resume` into the live shell, or opens a new tab).
        let task = try await makeTask()
        #expect(model.canResume(task))                       // freshly created, done
        model.noteSessionStarted(taskId: task.id)            // launching → working
        #expect(!model.canResume(task))                      // not while working
        model.apply(TaskAttentionSignal(
            taskId: task.id, sessionRef: task.sessionRef!, event: .agentStopped))
        #expect(model.canResume(task))                       // agent idle → resumable
        model.noteSessionEnded(taskId: task.id)              // shell exited → dirty
        #expect(model.canResume(task))                       // still resumable
        // A task with no sessionRef is never resumable.
        var bare = task
        bare.sessionRef = nil
        #expect(!model.canResume(bare))
    }

    @Test func quitConfirmationListsOnlyLiveWorkingTasks() async throws {
        let working = try await makeTask(named: "busy")
        let idle = try await makeTask(named: "idle")
        let deadNotResumed = try await makeTask(named: "dead")

        model.noteSessionStarted(taskId: working.id)
        model.noteSessionStarted(taskId: idle.id)
        model.apply(TaskAttentionSignal(
            taskId: idle.id, sessionRef: idle.sessionRef!, event: .agentStopped))
        model.noteSessionStarted(taskId: deadNotResumed.id)
        model.noteSessionEnded(taskId: deadNotResumed.id)

        #expect(model.tasksBlockingQuit().map(\.id) == [working.id])
    }

    @Test func switcherPutsNeedsInputFirstAndFiltersFuzzily() async throws {
        let alpha = try await makeTask(named: "alpha payments")
        let beta = try await makeTask(named: "beta payments")
        _ = try await makeTask(named: "unrelated chore")

        model.apply(TaskAttentionSignal(
            taskId: beta.id, sessionRef: beta.sessionRef!, event: .agentNeedsInput))

        let all = model.switcherEntries(query: "")
        #expect(all.first?.id == beta.id) // inbox: needs-input first
        #expect(all.count == 3)

        let filtered = model.switcherEntries(query: "payments")
        #expect(filtered.map(\.id) == [beta.id, alpha.id])
        #expect(model.switcherEntries(query: "zzz").isEmpty)
    }
}
