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

    // MARK: Center body (spec §3.4) — default, viewer precedence, mode switch

    @Test func centerBodyDefaultsToTerminal() throws {
        let (workbench, _) = try makeWorkbench()
        #expect(workbench.effectiveBody == .terminal)
        #expect(workbench.bodyState.mode == .terminal)
        #expect(workbench.bodyState.viewerActive == false)
    }

    // A selection activates the viewer OVER the mode; ⌘J (showTerminal) closes
    // it and returns to whichever mode was active — it does NOT force terminal.
    @Test func viewerClosesBackToActiveMode() throws {
        let (workbench, _) = try makeWorkbench()
        workbench.setBodyMode(.summary)
        workbench.bodyState.activateViewer()
        #expect(workbench.effectiveBody == .viewer)
        #expect(workbench.bodyState.mode == .summary, "activating the viewer must not change the mode")
        workbench.showTerminal() // ⌘J = close the viewer
        #expect(workbench.effectiveBody == .summary, "closing the viewer returns to the active mode")
    }

    // The segmented control (setBodyMode) CLEARS an active viewer.
    @Test func setBodyModeClearsActiveViewer() throws {
        let (workbench, _) = try makeWorkbench()
        workbench.bodyState.activateViewer()
        #expect(workbench.effectiveBody == .viewer)
        workbench.setBodyMode(.summary)
        #expect(workbench.effectiveBody == .summary)
        #expect(workbench.bodyState.viewerActive == false)
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
        #expect(workbench.effectiveBody == .viewer)
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
        #expect(workbench.effectiveBody == .viewer)
        #expect(workbench.viewer.hasContent)
    }

    // Failure-first: a binary file must render a placeholder, not crash.
    @Test func selectingBinaryFileRendersPlaceholderNotCrash() async throws {
        let (workbench, worktree) = try makeWorkbench()
        try Data([0x00, 0x01, 0x02, 0xFF, 0x00]).write(
            to: worktree.appendingPathComponent("blob.bin"))
        await workbench.selectFile("blob.bin")
        #expect(workbench.effectiveBody == .viewer)
        #expect(workbench.viewer.hasContent)
    }

    // Failure-first: an out-of-tree path must become an escaped message page,
    // never a throw that escapes the selection.
    @Test func selectingPathOutsideWorktreeRendersMessageNotCrash() async throws {
        let (workbench, _) = try makeWorkbench()
        await workbench.selectFile("../escape.txt")
        #expect(workbench.effectiveBody == .viewer)
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
        #expect(workbench.effectiveBody == .viewer)
        #expect(workbench.viewer.hasContent)
    }

    // MARK: File editing (simple native editor)

    @Test func editingATextFileSavesToDisk() async throws {
        let (workbench, worktree) = try makeWorkbench()
        await workbench.selectFile("notes.txt")
        #expect(workbench.canEditCurrentFile)

        await workbench.beginEditing()
        #expect(workbench.isEditing)
        #expect(workbench.editText == "changed\n") // loaded fresh from disk

        workbench.editText = "edited by test\n"
        await workbench.saveEdits()

        #expect(!workbench.isEditing)
        #expect(try await git.fileContents(worktree: worktree, relativePath: "notes.txt")
                == .text("edited by test\n"))
    }

    @Test func staleFileFlagsConflictInsteadOfClobbering() async throws {
        let (workbench, worktree) = try makeWorkbench()
        await workbench.selectFile("notes.txt")
        await workbench.beginEditing()

        // The agent (someone else) changes the file underneath us.
        try Data("agent changed\n".utf8).write(to: worktree.appendingPathComponent("notes.txt"))
        workbench.editText = "my edit\n"
        await workbench.saveEdits()

        // Not written — a conflict is surfaced instead.
        #expect(workbench.editConflict)
        #expect(workbench.isEditing)
        #expect(try await git.fileContents(worktree: worktree, relativePath: "notes.txt")
                == .text("agent changed\n"))

        // Overwrite resolves it explicitly.
        await workbench.overwriteEdits()
        #expect(!workbench.isEditing)
        #expect(try await git.fileContents(worktree: worktree, relativePath: "notes.txt")
                == .text("my edit\n"))
    }

    @Test func binaryFileIsNotEditable() async throws {
        let (workbench, worktree) = try makeWorkbench()
        try Data([0x00, 0x01, 0xFF]).write(to: worktree.appendingPathComponent("blob.bin"))
        await workbench.selectFile("blob.bin")
        #expect(!workbench.currentFileEditable)
        #expect(!workbench.canEditCurrentFile)
    }
}
