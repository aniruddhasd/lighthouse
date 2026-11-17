import AppKit
import Foundation
import Testing
import LighthouseFixtures
import LighthouseGit
import LighthouseTaskEngine
@testable import LighthouseApp

/// Regression tests for the stale-diff bug (2026-07-13): a change the FSEvents
/// watcher never saw (a commit-only mutation, which writes only to the
/// per-worktree gitdir) left the pane showing an old diff forever. Two fixes:
/// every (re)start refreshes unconditionally (self-heal), and the watcher now
/// covers the gitdir too (so bare commits fire a refresh).
@MainActor
@Suite("Review pane refresh", .serialized)
final class ReviewRefreshTests {
    private let fixtures: FixtureFactory
    private let git = GitClient()

    init() throws { fixtures = try FixtureFactory() }
    deinit { try? fixtures.destroy() }

    /// A registered clone on `develop` with a linked `task` worktree that has
    /// two tracked files modified vs the merge base. Returns (repo, worktree).
    private func taskWorktree() throws -> (repo: RepoConfig, worktree: URL) {
        let main = try fixtures.cleanRepo(defaultBranch: "develop", commitCount: 1)
        // Two tracked files on develop.
        try Data("a1\n".utf8).write(to: main.path.appendingPathComponent("a.txt"))
        try Data("b1\n".utf8).write(to: main.path.appendingPathComponent("b.txt"))
        try fixtures.git(["add", "."], in: main.path)
        try fixtures.git(["commit", "-m", "seed"], in: main.path)
        // Linked worktree on a task branch.
        let worktree = main.path.deletingLastPathComponent().appendingPathComponent("wt-\(UUID().uuidString.prefix(6))")
        try fixtures.git(["worktree", "add", "-b", "task", worktree.path, "develop"], in: main.path)
        // Modify both files in the worktree (2 changed files vs develop).
        try Data("a2\n".utf8).write(to: worktree.appendingPathComponent("a.txt"))
        try Data("b2\n".utf8).write(to: worktree.appendingPathComponent("b.txt"))
        let repo = RepoConfig(path: main.path.path, baseBranch: "develop")
        return (repo, worktree)
    }

    private func makeModel(repo: RepoConfig, worktree: URL) -> ReviewPaneModel {
        let task = TaskRecord(
            name: "t", branch: "task", adapterKind: "debug", sessionRef: nil,
            workspaces: [Workspace(repoId: repo.id, worktreePath: worktree.path, mergeState: .unmerged)])
        return ReviewPaneModel(task: task, repos: [repo], git: git)
    }

    /// Deterministic: await the model's in-flight refresh, then read the
    /// count. No wall-clock polling — immune to parallel-suite contention.
    private func refreshedFileCount(_ model: ReviewPaneModel) async -> Int {
        await model.awaitRefresh()
        return model.changedFileCount
    }

    /// For the inherently-async watcher path (FSEvents → debounce → refresh):
    /// poll with a generous deadline.
    private func waitForFileCount(_ model: ReviewPaneModel, _ expected: Int, deadline: Duration = .seconds(20)) async -> Int {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < deadline {
            if model.changedFileCount == expected { return expected }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return model.changedFileCount
    }

    /// Commits a brand-new file on the task branch IN THE WORKTREE — a
    /// mutation the worktree-only watcher would miss (the commit writes to the
    /// gitdir; git add of an untracked file also does). Raises the merge-base
    /// diff from 2 to 3 files.
    private func commitNewFile(in worktree: URL) throws {
        try Data("c\n".utf8).write(to: worktree.appendingPathComponent("c.txt"))
        try fixtures.git(["add", "c.txt"], in: worktree)
        try fixtures.git(["commit", "-m", "add c"], in: worktree)
    }

    // MARK: The key self-heal: background → change → foreground

    @Test func restartAfterMissedChangeSelfHeals() async throws {
        let (repo, worktree) = try taskWorktree()
        let model = makeModel(repo: repo, worktree: worktree)
        defer { model.stop() }

        model.start()
        model.scope = .vsBase // these self-heal cases count committed work too
        #expect(await refreshedFileCount(model) == 2)

        // Simulate: app backgrounded (watcher stopped), a commit happens the
        // watcher never sees, app foregrounded.
        model.stop()
        try commitNewFile(in: worktree)
        model.start()

        // The restart's unconditional refresh re-reads the diff — deterministic.
        #expect(await refreshedFileCount(model) == 3, "restart did not re-read the diff")
    }

    // MARK: Collapse state survives a diff refresh

    @Test func userCollapseSurvivesRefreshInTheModel() async throws {
        // Put a change under a subdirectory so the tree has a foldable dir.
        let main = try fixtures.cleanRepo(defaultBranch: "develop", commitCount: 1)
        try fixtures.git(["commit", "--allow-empty", "-m", "seed"], in: main.path)
        let worktree = main.path.deletingLastPathComponent()
            .appendingPathComponent("wt-\(UUID().uuidString.prefix(6))")
        try fixtures.git(["worktree", "add", "-b", "task", worktree.path, "develop"], in: main.path)
        let subdir = worktree.appendingPathComponent("__tests__")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try Data("t\n".utf8).write(to: subdir.appendingPathComponent("a.test.tsx"))
        try Data("r\n".utf8).write(to: worktree.appendingPathComponent("root.txt"))
        let repo = RepoConfig(path: main.path.path, baseBranch: "develop")
        let model = makeModel(repo: repo, worktree: worktree)
        defer { model.stop() }

        model.start()
        _ = await refreshedFileCount(model)
        // The user collapses __tests__/.
        model.expansion.setExpanded(false, for: "__tests__/")
        #expect(!model.expansion.isExpanded("__tests__/"))

        // Another change lands and the diff regenerates.
        try Data("more\n".utf8).write(to: subdir.appendingPathComponent("b.test.tsx"))
        model.refreshNow()
        _ = await refreshedFileCount(model)

        // The collapse survived the rebuild (same dir still present).
        #expect(!model.expansion.isExpanded("__tests__/"),
                "refresh re-expanded a directory the user had collapsed")
    }

    // MARK: Manual refresh

    @Test func manualRefreshRereadsTheDiff() async throws {
        let (repo, worktree) = try taskWorktree()
        let model = makeModel(repo: repo, worktree: worktree)
        defer { model.stop() }
        model.start()
        model.scope = .vsBase // asserts committed work shows up → vs-base scope
        #expect(await refreshedFileCount(model) == 2)

        // A change with the watcher still running but (pretend) not fired.
        try commitNewFile(in: worktree)
        model.refreshNow()
        #expect(await refreshedFileCount(model) == 3, "manual refresh did not re-read")
    }

    // MARK: Commit-only change fires a refresh via the gitdir watch

    @Test func commitOnlyChangeFiresWatcherThroughGitdir() async throws {
        let (repo, worktree) = try taskWorktree()
        let model = makeModel(repo: repo, worktree: worktree)
        defer { model.stop() }
        model.start()
        model.scope = .vsBase // a commit only changes the vs-base diff
        #expect(await refreshedFileCount(model) == 2)

        // No stop/start, no manual refresh — the gitdir watch must catch the
        // commit and drive a refresh on its own (inherently async: FSEvents →
        // debounce → refresh, so this one polls).
        try commitNewFile(in: worktree)
        #expect(await waitForFileCount(model, 3) == 3,
                "gitdir watch did not fire on a commit — the pane would stay stale")
    }

    /// Direct watcher proof, isolated from the model: a FileSystemWatcher over
    /// [worktree, gitdir] fires when a commit writes only to the gitdir.
    @Test func fileSystemWatcherSeesGitdirCommit() async throws {
        let (_, worktree) = try taskWorktree()
        let gitdir = try await git.gitDirectory(in: worktree)
        // The per-worktree gitdir lives under the MAIN repo, not the worktree.
        #expect(!gitdir.path.hasPrefix(worktree.path))

        let counter = FireCounter()
        let watcher = FileSystemWatcher(paths: [worktree.path, gitdir.path], latency: 0.1) {
            counter.increment()
        }
        #expect(watcher != nil)
        defer { watcher?.stop() }
        try await Task.sleep(for: .milliseconds(300)) // let the stream arm

        try commitNewFile(in: worktree)

        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(8), counter.value == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(counter.value > 0, "watcher never fired for a commit-only change")
    }

    final class FireCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}
