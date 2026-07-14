import Foundation
import Testing
import LighthouseAppCore
import LighthouseFixtures
import LighthouseGit
import LighthouseTaskEngine
@testable import LighthouseApp

/// The workbench's decision layer: the center stage defaults to the terminal
/// and toggles; a navigator selection promotes the right page into the center
/// viewer; and the non-happy file cases (binary, out-of-tree) render safe
/// placeholders instead of crashing. SwiftUI layout is not headlessly testable
/// (documented scar), so these drive the observable model directly.
@MainActor
@Suite("Workbench model", .serialized)
final class WorkbenchModelTests {
    private let fixtures: FixtureFactory
    private let git = GitClient()

    init() throws { fixtures = try FixtureFactory() }
    deinit { try? fixtures.destroy() }

    /// A registered repo on `main` (2 commits, tracked `notes.txt`) with a
    /// linked `task` worktree holding one tracked modification and one untracked
    /// file (1 changed file vs base). Returns the workbench and the worktree URL.
    private func makeWorkbench() throws -> (workbench: WorkbenchModel, worktree: URL) {
        let main = try fixtures.cleanRepo(defaultBranch: "main", commitCount: 2)
        let worktree = main.path.deletingLastPathComponent()
            .appendingPathComponent("wt-\(UUID().uuidString.prefix(6))")
        try fixtures.git(["worktree", "add", "-b", "task", worktree.path, "main"], in: main.path)
        try Data("changed\n".utf8).write(to: worktree.appendingPathComponent("notes.txt"))
        try Data("new\n".utf8).write(to: worktree.appendingPathComponent("untracked.txt"))
        let repo = RepoConfig(path: main.path.path, baseBranch: "main")
        let task = TaskRecord(
            name: "t", branch: "task", adapterKind: "debug", sessionRef: nil, state: .done,
            workspaces: [Workspace(repoId: repo.id, worktreePath: worktree.path, mergeState: .unmerged)])
        return (WorkbenchModel(task: task, repos: [repo], git: git), worktree)
    }

    // MARK: Center-stage default + toggle

    @Test func centerStageDefaultsToTerminalAndToggles() throws {
        let (workbench, _) = try makeWorkbench()
        #expect(workbench.centerMode == .terminal)
        workbench.toggleCenter()
        #expect(workbench.centerMode == .viewer)
        workbench.showTerminal()
        #expect(workbench.centerMode == .terminal)
    }

    // MARK: Changes → live diff + swap

    @Test func startPopulatesChangesAndLatestPatch() async throws {
        let (workbench, _) = try makeWorkbench()
        defer { workbench.stop() }
        workbench.start()
        await workbench.review.awaitRefresh()
        #expect(workbench.review.changedFileCount == 1)
        #expect(workbench.review.latestPatch != nil)
    }

    @Test func selectingChangedFileRendersDiffAndSwapsToViewer() async throws {
        let (workbench, _) = try makeWorkbench()
        defer { workbench.stop() }
        workbench.start()
        await workbench.review.awaitRefresh()
        await workbench.selectChangedFile("notes.txt")
        #expect(workbench.centerMode == .viewer)
        #expect(workbench.viewer.hasContent)
    }

    // MARK: Files surface

    @Test func filesSurfaceListsRepoFiles() async throws {
        let (workbench, _) = try makeWorkbench()
        await workbench.loadFiles()
        #expect(!workbench.files.isEmpty)
    }

    @Test func selectingTextFileRendersFilePageAndSwaps() async throws {
        let (workbench, _) = try makeWorkbench()
        await workbench.selectFile("notes.txt")
        #expect(workbench.centerMode == .viewer)
        #expect(workbench.viewer.hasContent)
    }

    // Failure-first: a binary file must render a placeholder, not crash.
    @Test func selectingBinaryFileRendersPlaceholderNotCrash() async throws {
        let (workbench, worktree) = try makeWorkbench()
        try Data([0x00, 0x01, 0x02, 0xFF, 0x00]).write(
            to: worktree.appendingPathComponent("blob.bin"))
        await workbench.selectFile("blob.bin")
        #expect(workbench.centerMode == .viewer)
        #expect(workbench.viewer.hasContent)
    }

    // Failure-first: an out-of-tree path must become an escaped message page,
    // never a throw that escapes the selection.
    @Test func selectingPathOutsideWorktreeRendersMessageNotCrash() async throws {
        let (workbench, _) = try makeWorkbench()
        await workbench.selectFile("../escape.txt")
        #expect(workbench.centerMode == .viewer)
        #expect(workbench.viewer.hasContent)
    }

    // MARK: History surface

    @Test func historySurfaceListsCommits() async throws {
        let (workbench, _) = try makeWorkbench()
        await workbench.loadHistory()
        #expect(workbench.commits.count >= 2)
    }

    @Test func selectingCommitRendersDiffAndSwaps() async throws {
        let (workbench, _) = try makeWorkbench()
        await workbench.loadHistory()
        let commit = try #require(workbench.commits.first)
        await workbench.selectCommit(commit)
        #expect(workbench.centerMode == .viewer)
        #expect(workbench.viewer.hasContent)
    }
}
