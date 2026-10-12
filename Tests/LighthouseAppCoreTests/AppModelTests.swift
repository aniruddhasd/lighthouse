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

    @Test func createTaskWiresSessionAndPlan() async throws {
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
        #expect(!model.isSessionLive(task.id))
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
            adapter: ClaudeCodeAdapter(), loginShell: "/bin/zsh")
        try reloaded.load()
        #expect(reloaded.startView == "harbor")
        #expect(reloaded.showBeam == true)
    }

    /// The terminal font size persists across a reload and defaults to the
    /// config default.
    @Test func terminalFontSizePersistsAcrossReload() throws {
        #expect(model.terminalFontSize == LighthouseConfig.defaultTerminalFontSize)
        model.setTerminalFontSize(11)
        #expect(model.terminalFontSize == 11)

        let reloaded = AppModel(
            store: ConfigStore(directory: storeDirectory),
            adapter: ClaudeCodeAdapter(), loginShell: "/bin/zsh")
        try reloaded.load()
        #expect(reloaded.terminalFontSize == 11)
    }

    /// The setter clamps out-of-range values to `terminalFontRange` — a huge or
    /// tiny request never yields an unreadable terminal, and the clamped value
    /// is what persists.
    @Test func terminalFontSizeClampsToRange() throws {
        model.setTerminalFontSize(999)
        #expect(model.terminalFontSize == AppModel.terminalFontRange.upperBound)
        model.setTerminalFontSize(1)
        #expect(model.terminalFontSize == AppModel.terminalFontRange.lowerBound)

        let reloaded = AppModel(
            store: ConfigStore(directory: storeDirectory),
            adapter: ClaudeCodeAdapter(), loginShell: "/bin/zsh")
        try reloaded.load()
        #expect(reloaded.terminalFontSize == AppModel.terminalFontRange.lowerBound)
    }

    // MARK: Session liveness (the one honest status signal)

    private func makeTask(named name: String = "attn") async throws -> TaskRecord {
        let repo = try fixtures.cleanRepo()
        let registered = try await model.registerRepo(path: repo.path, baseBranch: "main")
        return try await model.createTask(
            name: name, branch: AppModel.branchSlug(from: name), repoIds: [registered.id]).task
    }

    /// noteSessionStarted/Ended maintain `liveSessions` — the only automatic
    /// signal. There is no agent-status inference and no persistence of it.
    @Test func sessionLivenessTracksStartAndEnd() async throws {
        let task = try await makeTask()
        #expect(!model.isSessionLive(task.id))
        model.noteSessionStarted(taskId: task.id)
        #expect(model.isSessionLive(task.id))
        model.noteSessionEnded(taskId: task.id)
        #expect(!model.isSessionLive(task.id))
    }

    /// A start for an unknown task id is ignored (guards the removal race).
    @Test func startForUnknownTaskIsIgnored() async throws {
        model.noteSessionStarted(taskId: UUID())
        #expect(model.liveSessions.isEmpty)
    }

    /// Liveness is session-only: nothing about it is persisted, so a fresh model
    /// (a relaunch) reads every task as not-live.
    @Test func livenessIsNeverPersisted() async throws {
        let task = try await makeTask()
        model.noteSessionStarted(taskId: task.id)

        let reloaded = AppModel(
            store: ConfigStore(directory: storeDirectory),
            adapter: ClaudeCodeAdapter(), loginShell: "/bin/zsh")
        try reloaded.load()
        #expect(!reloaded.isSessionLive(task.id))
    }

    // MARK: Free-text status

    /// The user's free-text status is trimmed, persists, and survives a reload.
    @Test func statusIsSetTrimmedAndPersisted() async throws {
        let task = try await makeTask()
        model.setStatus("  waiting on review  ", for: task.id)
        #expect(model.tasks.first { $0.id == task.id }?.status == "waiting on review")

        let reloaded = AppModel(
            store: ConfigStore(directory: storeDirectory),
            adapter: ClaudeCodeAdapter(), loginShell: "/bin/zsh")
        try reloaded.load()
        #expect(reloaded.tasks.first { $0.id == task.id }?.status == "waiting on review")
    }

    /// Hiding a task drops it from ⌘K, persists across a reload, and unhiding
    /// brings it back.
    @Test func hidingExcludesFromSwitcherAndPersists() async throws {
        let task = try await makeTask(named: "secret")
        #expect(task.hidden == false)
        #expect(model.switcherEntries(query: "").contains { $0.id == task.id })

        model.setTaskHidden(true, for: task.id)
        #expect(model.tasks.first { $0.id == task.id }?.hidden == true)
        #expect(!model.switcherEntries(query: "").contains { $0.id == task.id })
        #expect(model.switcherEntries(query: "secret").isEmpty) // not even by name

        let reloaded = AppModel(
            store: ConfigStore(directory: storeDirectory),
            adapter: ClaudeCodeAdapter(), loginShell: "/bin/zsh")
        try reloaded.load()
        #expect(reloaded.tasks.first { $0.id == task.id }?.hidden == true)

        model.setTaskHidden(false, for: task.id)
        #expect(model.switcherEntries(query: "").contains { $0.id == task.id })
    }

    /// The per-task base-branch override is trimmed, persists across a reload,
    /// and an empty value clears it back to the repo default.
    @Test func baseOverrideSetsPersistsAndClears() async throws {
        let task = try await makeTask()
        let repoId = task.workspaces[0].repoId
        func override(in m: AppModel) -> String?? {
            m.tasks.first { $0.id == task.id }?.workspaces[0].baseOverride
        }
        #expect(override(in: model) == .some(nil)) // default: no override

        model.setWorkspaceBaseOverride(taskId: task.id, repoId: repoId, base: "  develop  ")
        #expect(override(in: model) == "develop") // trimmed

        let reloaded = AppModel(
            store: ConfigStore(directory: storeDirectory),
            adapter: ClaudeCodeAdapter(), loginShell: "/bin/zsh")
        try reloaded.load()
        #expect(override(in: reloaded) == "develop") // survived relaunch

        model.setWorkspaceBaseOverride(taskId: task.id, repoId: repoId, base: "   ")
        #expect(override(in: model) == .some(nil)) // empty clears it
    }

    // MARK: Derivations

    /// Resume needs a stored session and NO live session (a live one is already
    /// open — go to it, don't resume). A task with no sessionRef never resumes.
    @Test func resumeAffordanceMatrix() async throws {
        let task = try await makeTask()
        #expect(model.canResume(task))            // has sessionRef, not live
        model.noteSessionStarted(taskId: task.id)
        #expect(!model.canResume(task))           // live → go to it
        model.noteSessionEnded(taskId: task.id)
        #expect(model.canResume(task))            // ended → resumable again
        var bare = task
        bare.sessionRef = nil
        #expect(!model.canResume(bare))           // no session ref → never
    }

    /// Any task with a live session blocks quit; ended/never-started do not.
    @Test func quitConfirmationListsEveryLiveSession() async throws {
        let live = try await makeTask(named: "busy")
        _ = try await makeTask(named: "idle")
        let ended = try await makeTask(named: "ended")

        model.noteSessionStarted(taskId: live.id)
        model.noteSessionStarted(taskId: ended.id)
        model.noteSessionEnded(taskId: ended.id)

        #expect(model.tasksBlockingQuit().map(\.id) == [live.id])
    }

    /// ⌘K search fuzzy-filters by name; empty query returns the standard order.
    @Test func switcherFiltersFuzzilyByName() async throws {
        let alpha = try await makeTask(named: "alpha payments")
        let beta = try await makeTask(named: "beta payments")
        _ = try await makeTask(named: "unrelated chore")

        #expect(model.switcherEntries(query: "").count == 3)
        let filtered = model.switcherEntries(query: "payments").map(\.id)
        #expect(Set(filtered) == Set([alpha.id, beta.id]))
        #expect(model.switcherEntries(query: "zzz").isEmpty)
    }

    /// The standard task order puts live sessions first, then most-recent.
    @Test func orderedTasksPutsLiveSessionsFirst() async throws {
        _ = try await makeTask(named: "one")
        let two = try await makeTask(named: "two")
        model.noteSessionStarted(taskId: two.id)
        #expect(model.orderedTasks().first?.id == two.id)
    }

    /// The keyboard-navigation primitive: wraps both ends, seeds sensibly from
    /// no selection, and is nil only when there's nothing to step through.
    @Test func stepTaskWrapsAndSeeds() {
        let a = UUID(), b = UUID(), c = UUID()
        let ids = [a, b, c]
        // forward / back from a real position
        #expect(AppModel.stepTask(ids: ids, from: a, delta: 1) == b)
        #expect(AppModel.stepTask(ids: ids, from: b, delta: -1) == a)
        // wrap at both ends
        #expect(AppModel.stepTask(ids: ids, from: c, delta: 1) == a)
        #expect(AppModel.stepTask(ids: ids, from: a, delta: -1) == c)
        // no selection: +1 → first, -1 → last
        #expect(AppModel.stepTask(ids: ids, from: nil, delta: 1) == a)
        #expect(AppModel.stepTask(ids: ids, from: nil, delta: -1) == c)
        // an id not in the list is treated as "no selection"
        #expect(AppModel.stepTask(ids: ids, from: UUID(), delta: 1) == a)
        // single element wraps to itself; empty is nil
        #expect(AppModel.stepTask(ids: [a], from: a, delta: 1) == a)
        #expect(AppModel.stepTask(ids: [], from: nil, delta: 1) == nil)
    }

    // MARK: - Clone & register (spec option D) — failures first

    @Test func cloneWithEmptyURLRejectedBeforeCloning() async throws {
        await #expect {
            try await self.model.cloneAndRegister(
                remoteURL: "   ", destinationParent: self.fixtures.root)
        } throws: { error in
            error as? RepoRegistrationError == .invalidRemoteURL("   ")
        }
        #expect(model.repos.isEmpty)
    }

    @Test func cloneWithOptionLookalikeURLRejected() async throws {
        await #expect {
            try await self.model.cloneAndRegister(
                remoteURL: "--upload-pack=/tmp/pwn", destinationParent: self.fixtures.root)
        } throws: { error in
            error as? RepoRegistrationError == .invalidRemoteURL("--upload-pack=/tmp/pwn")
        }
        #expect(model.repos.isEmpty)
    }

    @Test func cloneIntoExistingDestinationRefused() async throws {
        let source = try fixtures.cleanRepo()
        // A folder already occupying the derived destination name.
        let occupied = fixtures.root.appendingPathComponent(
            source.path.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)

        await #expect {
            try await self.model.cloneAndRegister(
                remoteURL: source.path.path, destinationParent: self.fixtures.root)
        } throws: { error in
            error as? RepoRegistrationError == .destinationExists(path: occupied.path)
        }
        #expect(model.repos.isEmpty)
    }

    @Test func cloneIntoMissingParentRejectedBeforeCloning() async throws {
        let source = try fixtures.cleanRepo()
        let ghostParent = fixtures.root.appendingPathComponent("no-such-parent")
        await #expect {
            try await self.model.cloneAndRegister(
                remoteURL: source.path.path, destinationParent: ghostParent)
        } throws: { error in
            error as? RepoRegistrationError == .pathDoesNotExist(ghostParent.path)
        }
    }

    // MARK: - Clone & register — happy path

    @Test func cloneAndRegisterClonesThenRegisters() async throws {
        let source = try fixtures.cleanRepo()
        let parent = fixtures.root.appendingPathComponent("clones", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let registered = try await model.cloneAndRegister(
            remoteURL: source.path.path, destinationParent: parent)

        // Registered against the freshly-cloned working tree, base auto-detected.
        let expectedPath = parent.appendingPathComponent(source.path.lastPathComponent)
            .resolvingSymlinksInPath().path
        #expect(registered.path == expectedPath)
        #expect(registered.baseBranch == "main")
        #expect(model.repos.map(\.id) == [registered.id])
        // Survives a reload — it is an ordinary registration.
        #expect(try ConfigStore(directory: storeDirectory).load().repos.count == 1)
    }

    @Test func cloneAndRegisterRespectsFolderNameOverride() async throws {
        let source = try fixtures.cleanRepo()
        let parent = fixtures.root.appendingPathComponent("clones2", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let registered = try await model.cloneAndRegister(
            remoteURL: source.path.path, destinationParent: parent, folderName: "renamed")

        #expect(registered.path.hasSuffix("/renamed"))
        #expect(FileManager.default.fileExists(atPath: registered.path))
    }

    // MARK: - repoName derivation

    // MARK: - PR task naming

    @Test func prTaskNameSanitizesTitleAndHonorsOverride() {
        let info = PullRequestInfo(number: 14, title: "fix: cache/eviction bug")
        // Default: PR title, path-safe (slashes → dashes).
        #expect(AppModel.taskName(fromPR: info, override: nil) == "fix: cache-eviction bug")
        // Override wins when non-empty.
        #expect(AppModel.taskName(fromPR: info, override: "my task") == "my task")
        #expect(AppModel.taskName(fromPR: info, override: "  ") == "fix: cache-eviction bug")
        // A title that sanitizes to nothing falls back to pr-<N>.
        #expect(AppModel.taskName(
            fromPR: PullRequestInfo(number: 7, title: "   "), override: nil) == "pr-7")
    }

    // MARK: - Scratch terminal (repo-less, ephemeral)

    /// A scratch task carries NO workspaces (the terminal-only discriminator),
    /// names itself after the directory, stashes the path in `branch`, and is
    /// ephemeral — a reload (mirroring relaunch) must not bring it back.
    @Test func scratchTaskIsWorkspaceLessAndNeverPersisted() async throws {
        let dir = try fixtures.nonRepoDirectory()
        let scratch = model.createScratchTask(directory: dir)

        #expect(scratch.workspaces.isEmpty)
        #expect(scratch.branch == dir.path)
        #expect(scratch.name == dir.lastPathComponent)
        #expect(model.tasks.map(\.id) == [scratch.id])
        #expect(!model.isSessionLive(scratch.id))

        // Ephemeral: nothing on disk, gone after a reload.
        #expect(try ConfigStore(directory: storeDirectory).load().tasks.isEmpty)
        let reloaded = AppModel(
            store: ConfigStore(directory: storeDirectory),
            adapter: ClaudeCodeAdapter(), loginShell: "/bin/zsh")
        try reloaded.load()
        #expect(reloaded.tasks.isEmpty)
    }

    /// A scratch terminal opened at $HOME is labelled "Home", not ".".
    @Test func scratchTaskAtHomeIsLabelledHome() {
        let scratch = model.createScratchTask(
            directory: FileManager.default.homeDirectoryForCurrentUser)
        #expect(scratch.name == "Home")
    }

    /// Removing a scratch task drops it from the model and clears its attention
    /// entry — with no engine/worktree work, since it owns nothing on disk.
    @Test func removeScratchTaskDropsItFromTheModel() throws {
        let dir = try fixtures.nonRepoDirectory()
        let scratch = model.createScratchTask(directory: dir)
        #expect(model.tasks.count == 1)

        model.removeScratchTask(scratch.id)
        #expect(model.tasks.isEmpty)
        #expect(!model.isSessionLive(scratch.id))
    }

    @Test func repoNameStripsGitSuffixAcrossURLShapes() {
        #expect(AppModel.repoName(fromURL: "git@github.com:org/repo.git") == "repo")
        #expect(AppModel.repoName(fromURL: "https://github.com/org/repo.git") == "repo")
        #expect(AppModel.repoName(fromURL: "https://github.com/org/repo") == "repo")
        #expect(AppModel.repoName(fromURL: "https://github.com/org/repo/") == "repo")
        #expect(AppModel.repoName(fromURL: "git@host:repo.git") == "repo")
        #expect(AppModel.repoName(fromURL: "") == nil)
        #expect(AppModel.repoName(fromURL: "/") == nil)
    }
}
