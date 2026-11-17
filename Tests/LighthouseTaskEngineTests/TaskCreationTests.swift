import Foundation
import Testing
import LighthouseFixtures
import LighthouseGit
@testable import LighthouseTaskEngine

/// Atomic creation and rollback (spec §2.2, guardrail 6, §7 proof).
/// Broken cases first; the injected failures are real: failing setup
/// scripts, pre-existing branches, and a setup script that sabotages an
/// earlier repo's worktree to make rollback itself fail.
@Suite("TaskEngine.createTask (fixture repos)")
final class TaskCreationTests {
    private let fixtures: FixtureFactory
    private let worktreesRoot: URL
    private let git = GitClient()
    private let engine: TaskEngine

    init() throws {
        fixtures = try FixtureFactory()
        worktreesRoot = fixtures.root.appendingPathComponent("worktrees", isDirectory: true)
        engine = TaskEngine(git: git)
    }

    deinit {
        try? fixtures.destroy()
    }

    // MARK: Helpers

    private func repoConfig(
        _ repo: FixtureRepo, setupScript: String? = nil, envCopyList: [String]? = nil
    ) -> RepoConfig {
        RepoConfig(
            path: repo.path.path, baseBranch: repo.defaultBranch,
            setupScript: setupScript, envCopyList: envCopyList)
    }

    private func writeExecutable(_ body: String, named name: String, in repo: FixtureRepo) throws {
        let url = repo.path.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Zero-debris assertion: only the main worktree, and no task branch.
    private func assertPristine(_ repo: FixtureRepo, branch: String) async throws {
        let worktrees = try await git.listWorktrees(in: repo.path)
        #expect(worktrees.count == 1, "unexpected worktrees in \(repo.path.path)")
        #expect(try await git.branchExists(branch, in: repo.path) == false,
                "branch \(branch) left behind in \(repo.path.path)")
    }

    private func creationFailure(
        _ body: @escaping () async throws -> TaskRecord
    ) async throws -> TaskCreationFailure {
        var caught: TaskCreationFailure?
        do {
            _ = try await body()
        } catch let failure as TaskCreationFailure {
            caught = failure
        }
        return try #require(caught, "expected TaskCreationFailure")
    }

    // MARK: Injected failures (spec §7: repo N of M leaves zero debris)

    @Test func failingSetupScriptAtRepo3of3RollsBackEverything() async throws {
        let r1 = try fixtures.cleanRepo()
        let r2 = try fixtures.cleanRepo()
        let r3 = try fixtures.cleanRepo()
        try writeExecutable("echo doomed >&2\nexit 7", named: "setup.sh", in: r3)

        let failure = try await creationFailure {
            try await self.engine.createTask(
                name: "atomic-test", branch: "task/atomic", adapterKind: "claude-code",
                repos: [self.repoConfig(r1), self.repoConfig(r2),
                        self.repoConfig(r3, setupScript: "setup.sh")],
                worktreesRootOverride: self.worktreesRoot)
        }

        guard case .setupScriptFailed(let repoPath, _, let exitCode, let stderr) = failure.cause else {
            Issue.record("wrong cause: \(failure.cause)")
            return
        }
        #expect(repoPath == r3.path.path)
        #expect(exitCode == 7)
        #expect(stderr.contains("doomed"))
        guard case .completed(let removed) = failure.rollback else {
            Issue.record("expected completed rollback, got \(failure.rollback)")
            return
        }
        // Repo 3's own worktree was created before its script failed.
        #expect(removed.count == 3)
        for repo in [r1, r2, r3] {
            try await assertPristine(repo, branch: "task/atomic")
        }
    }

    @Test func preexistingBranchAtRepo2of3FailsBeforeTouchingRepo2() async throws {
        let r1 = try fixtures.cleanRepo()
        let r2 = try fixtures.cleanRepo()
        let r3 = try fixtures.cleanRepo()
        // The collision: repo 2 already has the branch, pointing somewhere real.
        try fixtures.git(["branch", "task/collide"], in: r2.path)
        let preexistingTip = try await git.revParse("task/collide", in: r2.path)

        let failure = try await creationFailure {
            try await self.engine.createTask(
                name: "collide-2", branch: "task/collide", adapterKind: "claude-code",
                repos: [self.repoConfig(r1), self.repoConfig(r2), self.repoConfig(r3)],
                worktreesRootOverride: self.worktreesRoot)
        }

        guard case .branchAlreadyExists(let repoPath, let branch) = failure.cause else {
            Issue.record("wrong cause: \(failure.cause)")
            return
        }
        #expect(repoPath == r2.path.path)
        #expect(branch == "task/collide")

        // Repo 1 was rolled back; repo 3 never touched.
        try await assertPristine(r1, branch: "task/collide")
        try await assertPristine(r3, branch: "task/collide")
        // Repo 2's PRE-EXISTING branch is exactly where it was — rollback
        // never touches what this attempt didn't create.
        #expect(try await git.branchExists("task/collide", in: r2.path))
        #expect(try await git.revParse("task/collide", in: r2.path) == preexistingTip)
        #expect(try await git.listWorktrees(in: r2.path).count == 1)
    }

    @Test func preexistingBranchAtRepo3of3RollsBackRepos1And2() async throws {
        let r1 = try fixtures.cleanRepo()
        let r2 = try fixtures.cleanRepo()
        let r3 = try fixtures.cleanRepo()
        try fixtures.git(["branch", "task/collide3"], in: r3.path)

        let failure = try await creationFailure {
            try await self.engine.createTask(
                name: "collide-3", branch: "task/collide3", adapterKind: "claude-code",
                repos: [self.repoConfig(r1), self.repoConfig(r2), self.repoConfig(r3)],
                worktreesRootOverride: self.worktreesRoot)
        }

        guard case .branchAlreadyExists = failure.cause else {
            Issue.record("wrong cause: \(failure.cause)")
            return
        }
        guard case .completed(let removed) = failure.rollback else {
            Issue.record("expected completed rollback, got \(failure.rollback)")
            return
        }
        #expect(removed.count == 2)
        try await assertPristine(r1, branch: "task/collide3")
        try await assertPristine(r2, branch: "task/collide3")
        #expect(try await git.branchExists("task/collide3", in: r3.path))
    }

    @Test func rollbackFailureReportsDebrisLoudly() async throws {
        let r1 = try fixtures.cleanRepo()
        let r2 = try fixtures.cleanRepo()
        // Sabotage: repo 2's setup script locks repo 1's freshly created
        // worktree, then fails. Rollback's forced removal of a locked
        // worktree fails (git requires -f -f), and the branch stays checked
        // out there — deterministic partial-rollback debris.
        let wt1 = worktreesRoot
            .appendingPathComponent("sabotage", isDirectory: true)
            .appendingPathComponent(r1.path.lastPathComponent, isDirectory: true)
        try writeExecutable(
            "/usr/bin/git -C \"\(r1.path.path)\" worktree lock \"\(wt1.path)\"\nexit 1",
            named: "sabotage.sh", in: r2)

        let failure = try await creationFailure {
            try await self.engine.createTask(
                name: "sabotage", branch: "task/sabotage", adapterKind: "claude-code",
                repos: [self.repoConfig(r1), self.repoConfig(r2, setupScript: "sabotage.sh")],
                worktreesRootOverride: self.worktreesRoot)
        }

        guard case .setupScriptFailed = failure.cause else {
            Issue.record("wrong cause: \(failure.cause)")
            return
        }
        guard case .incomplete(let removed, let debris) = failure.rollback else {
            Issue.record("rollback failure was swallowed: \(failure.rollback)")
            return
        }
        // Repo 2's own artifacts came out; repo 1's are reported as debris.
        #expect(removed.map(\.repoPath) == [r2.path.path])
        #expect(debris.count == 1)
        #expect(debris.first?.repoPath == r1.path.path)
        #expect(debris.first?.branch == "task/sabotage")
        #expect(debris.first?.failure.isEmpty == false)
    }

    // MARK: Pre-flight failures (no mutation anywhere)

    @Test func nonexistentRepoPathAtPosition2RollsBackPosition1() async throws {
        let r1 = try fixtures.cleanRepo()
        let ghost = RepoConfig(
            path: fixtures.root.appendingPathComponent("does-not-exist").path,
            baseBranch: "main")

        let failure = try await creationFailure {
            try await self.engine.createTask(
                name: "ghost", branch: "task/ghost", adapterKind: "claude-code",
                repos: [self.repoConfig(r1), ghost],
                worktreesRootOverride: self.worktreesRoot)
        }
        guard case .repoNotFound(let path) = failure.cause else {
            Issue.record("wrong cause: \(failure.cause)")
            return
        }
        #expect(path == ghost.path)
        guard case .completed = failure.rollback else {
            Issue.record("expected completed rollback, got \(failure.rollback)")
            return
        }
        try await assertPristine(r1, branch: "task/ghost")
    }

    @Test func nonRepoDirectoryFailsBeforeAnyMutation() async throws {
        let notRepo = try fixtures.nonRepoDirectory()
        let failure = try await creationFailure {
            try await self.engine.createTask(
                name: "notrepo", branch: "task/notrepo", adapterKind: "claude-code",
                repos: [RepoConfig(path: notRepo.path, baseBranch: "main")],
                worktreesRootOverride: self.worktreesRoot)
        }
        guard case .repoNotFound = failure.cause else {
            Issue.record("wrong cause: \(failure.cause)")
            return
        }
        guard case .notNeeded = failure.rollback else {
            Issue.record("nothing was created, rollback should be notNeeded")
            return
        }
    }

    @Test func missingBaseBranchFailsBeforeAnyMutation() async throws {
        let r1 = try fixtures.cleanRepo()
        var config = repoConfig(r1)
        config.baseBranch = "no-such-base"

        let failure = try await creationFailure {
            try await self.engine.createTask(
                name: "nobase", branch: "task/nobase", adapterKind: "claude-code",
                repos: [config], worktreesRootOverride: self.worktreesRoot)
        }
        guard case .baseBranchMissing(let repoPath, let base) = failure.cause else {
            Issue.record("wrong cause: \(failure.cause)")
            return
        }
        #expect(repoPath == r1.path.path)
        #expect(base == "no-such-base")
        try await assertPristine(r1, branch: "task/nobase")
    }

    @Test func invalidTaskNameRejected() async throws {
        let r1 = try fixtures.cleanRepo()
        let failure = try await creationFailure {
            try await self.engine.createTask(
                name: "bad/name", branch: "task/ok", adapterKind: "claude-code",
                repos: [self.repoConfig(r1)], worktreesRootOverride: self.worktreesRoot)
        }
        guard case .invalidTaskName = failure.cause else {
            Issue.record("wrong cause: \(failure.cause)")
            return
        }
    }

    @Test func invalidBranchNameRejectedByCheckRefFormat() async throws {
        let r1 = try fixtures.cleanRepo()
        let failure = try await creationFailure {
            try await self.engine.createTask(
                name: "okname", branch: "bad name", adapterKind: "claude-code",
                repos: [self.repoConfig(r1)], worktreesRootOverride: self.worktreesRoot)
        }
        guard case .invalidBranchName("bad name") = failure.cause else {
            Issue.record("wrong cause: \(failure.cause)")
            return
        }
        try await assertPristine(r1, branch: "bad name")
    }

    @Test func occupiedWorktreeDestinationRejectedBeforeMutation() async throws {
        let r1 = try fixtures.cleanRepo()
        let destination = worktreesRoot
            .appendingPathComponent("occupied", isDirectory: true)
            .appendingPathComponent(r1.path.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let failure = try await creationFailure {
            try await self.engine.createTask(
                name: "occupied", branch: "task/occupied", adapterKind: "claude-code",
                repos: [self.repoConfig(r1)], worktreesRootOverride: self.worktreesRoot)
        }
        guard case .worktreeDestinationOccupied(let path) = failure.cause else {
            Issue.record("wrong cause: \(failure.cause)")
            return
        }
        #expect(path == destination.path)
        try await assertPristine(r1, branch: "task/occupied")
    }

    @Test func missingEnvSourceFailsThatRepoBeforeItsMutation() async throws {
        let r1 = try fixtures.cleanRepo()
        let failure = try await creationFailure {
            try await self.engine.createTask(
                name: "noenv", branch: "task/noenv", adapterKind: "claude-code",
                repos: [self.repoConfig(r1, envCopyList: [".env"])],
                worktreesRootOverride: self.worktreesRoot)
        }
        guard case .envCopySourceMissing(_, let entry) = failure.cause else {
            Issue.record("wrong cause: \(failure.cause)")
            return
        }
        #expect(entry == ".env")
        try await assertPristine(r1, branch: "task/noenv")
    }

    @Test func envEntryEscapingRepoRootRejected() async throws {
        let r1 = try fixtures.cleanRepo()
        let failure = try await creationFailure {
            try await self.engine.createTask(
                name: "escape", branch: "task/escape", adapterKind: "claude-code",
                repos: [self.repoConfig(r1, envCopyList: ["../outside.env"])],
                worktreesRootOverride: self.worktreesRoot)
        }
        guard case .invalidEnvCopyEntry(let entry, _) = failure.cause else {
            Issue.record("wrong cause: \(failure.cause)")
            return
        }
        #expect(entry == "../outside.env")
    }

    @Test func missingSetupScriptFailsBeforeMutation() async throws {
        let r1 = try fixtures.cleanRepo()
        let failure = try await creationFailure {
            try await self.engine.createTask(
                name: "noscript", branch: "task/noscript", adapterKind: "claude-code",
                repos: [self.repoConfig(r1, setupScript: "nope.sh")],
                worktreesRootOverride: self.worktreesRoot)
        }
        guard case .setupScriptNotFound = failure.cause else {
            Issue.record("wrong cause: \(failure.cause)")
            return
        }
        try await assertPristine(r1, branch: "task/noscript")
    }

    // MARK: Happy path

    @Test func twoRepoCreationWithEnvCopyAndSetupScript() async throws {
        let r1 = try fixtures.cleanRepo()
        let r2 = try fixtures.cleanRepo()
        let envContent = "API_URL=http://localhost:9999\nTOKEN=fixture-not-a-real-secret\n"
        try Data(envContent.utf8).write(to: r1.path.appendingPathComponent(".env"))
        // The script proves both cwd = workspace AND env-copy-before-script.
        try writeExecutable(
            "test -f .env || exit 3\ntouch setup-ran", named: "setup.sh", in: r1)

        let task = try await engine.createTask(
            name: "payments-fix", branch: "task/payments-fix", adapterKind: "claude-code",
            repos: [
                repoConfig(r1, setupScript: "setup.sh", envCopyList: [".env"]),
                repoConfig(r2),
            ],
            worktreesRootOverride: worktreesRoot)

        #expect(task.name == "payments-fix")
        #expect(task.branch == "task/payments-fix")
        #expect(task.adapterKind == "claude-code")
        #expect(task.sessionRef == nil)
        #expect(task.status.isEmpty)
        #expect(task.workspaces.count == 2)
        #expect(task.workspaces.allSatisfy { $0.mergeState == .unmerged })

        for (workspace, repo) in zip(task.workspaces, [r1, r2]) {
            #expect(workspace.repoId != UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
            let status = try await git.status(in: workspace.worktreeURL)
            #expect(status.head == .branch("task/payments-fix"))
            // Worktree starts at the LOCAL base tip.
            #expect(try await git.headCommit(in: workspace.worktreeURL)
                == (try await git.revParse(repo.defaultBranch, in: repo.path)))
        }

        // Env file copied byte-identical; setup marker present.
        let ws1 = task.workspaces[0].worktreeURL
        #expect(try Data(contentsOf: ws1.appendingPathComponent(".env")) == Data(envContent.utf8))
        #expect(FileManager.default.fileExists(atPath: ws1.appendingPathComponent("setup-ran").path))
    }
}
