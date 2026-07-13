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

        try await model.removeTask(task, mode: .refuseIfUnmerged)
        #expect(model.tasks.isEmpty)
        #expect(model.attention[task.id] == nil)
        let reloaded = try ConfigStore(directory: storeDirectory).load()
        #expect(reloaded.tasks.isEmpty)
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
