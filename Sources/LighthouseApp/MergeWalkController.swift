import AppKit
import Foundation
import Observation
import LighthouseAdapter
import LighthouseAppCore
import LighthouseGit
import LighthouseTaskEngine

/// Observable app-side driver for a task's merge-back: owns the MergeWalk,
/// classifies conflicts through ConflictResolver, and exposes state to the
/// conflict pane. All resolution goes through the resolver's structured
/// transforms (guardrail 2); complete/abort are explicit user actions
/// (guardrail 5).
@MainActor @Observable
final class MergeWalkController {
    let task: TaskRecord
    private let repos: [RepoConfig]
    private let git: GitClient
    private let resolver: ConflictResolver
    private let walk: MergeWalk
    private let session: SessionRegistry
    private let loginShell: String

    private(set) var state: MergeWalkState = .notStarted
    private(set) var progress: [RepoMergeProgress] = []
    /// Conflicts at the current pause, classified for the pane.
    private(set) var conflicts: [ClassifiedConflict] = []
    /// Per-(file,block) user choices for text conflicts.
    var textChoices: [String: [Int: BlockResolution]] = [:]
    private(set) var lastError: String?
    private(set) var busy = false

    init(
        task: TaskRecord, repos: [RepoConfig], orderedRepoIds: [UUID],
        git: GitClient, session: SessionRegistry, loginShell: String
    ) {
        self.task = task
        self.repos = repos
        self.git = git
        self.resolver = ConflictResolver(git: git)
        self.session = session
        self.loginShell = loginShell
        let ordered = orderedRepoIds.compactMap { id in repos.first { $0.id == id } }
        self.walk = MergeWalk(taskBranch: task.branch, orderedRepos: ordered, git: git)
    }

    private func currentClone() async -> URL? {
        await walk.currentRepoPath()
    }

    func start() async {
        await step { try await self.walk.run() }
    }

    func completeCurrentRepo() async {
        await step { try await self.walk.completeCurrentRepo() }
    }

    func abortCurrentRepo() async {
        await step { try await self.walk.abortCurrentRepo() }
    }

    /// Runs a walk transition, then refreshes state + conflict classification.
    private func step(_ body: @escaping () async throws -> MergeWalkState) async {
        busy = true
        defer { busy = false }
        do {
            state = try await body()
            progress = await walk.repoProgress
            await refreshConflicts()
        } catch {
            lastError = String(describing: error)
        }
    }

    private func refreshConflicts() async {
        guard case .paused(_, .conflicted) = state, let clone = await currentClone() else {
            conflicts = []
            return
        }
        do {
            conflicts = try await resolver.classify(in: clone)
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Resolution actions (structured transforms only)

    func setChoice(path: String, block: Int, choice: BlockResolution) {
        textChoices[path, default: [:]][block] = choice
    }

    /// Applies the collected per-block choices for a text file and stages it.
    func resolveText(path: String) async {
        guard let clone = await currentClone() else { return }
        let resolution = FileResolution(choices: textChoices[path] ?? [:])
        await withClone(clone) {
            try await self.resolver.resolveText(path: path, resolution: resolution, in: clone)
        }
    }

    func resolveWholeFileText(path: String, side: BlockResolution) async {
        guard let clone = await currentClone() else { return }
        await withClone(clone) {
            try await self.resolver.resolveWholeFileText(path: path, side: side, in: clone)
        }
    }

    func resolveBinary(path: String, side: GitClient.ConflictSide) async {
        guard let clone = await currentClone() else { return }
        await withClone(clone) {
            try await self.resolver.resolveBinary(path: path, side: side, in: clone)
        }
    }

    func resolveDeleteModify(path: String, keepModified: Bool, modifiedSide: GitClient.ConflictSide) async {
        guard let clone = await currentClone() else { return }
        await withClone(clone) {
            try await self.resolver.resolveDeleteModify(
                path: path, keepModified: keepModified, modifiedSide: modifiedSide, in: clone)
        }
    }

    func rematerialize(path: String) async {
        guard let clone = await currentClone() else { return }
        await withClone(clone) {
            try await self.resolver.rematerialize(path: path, in: clone)
        }
    }

    private func withClone(_ clone: URL, _ body: @escaping () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await body()
            await refreshConflicts()
        } catch {
            lastError = String(describing: error)
        }
    }

    /// True once every conflicted file is staged (no `u` entries remain) —
    /// enables "complete this repo's merge".
    var allFilesResolved: Bool { conflicts.isEmpty && isPausedConflicted }

    var isPausedConflicted: Bool {
        if case .paused(_, .conflicted) = state { return true }
        return false
    }

    // MARK: - Escape hatches (spec §2.5)

    /// Composes a prompt naming the conflicted files + their hunks and types
    /// it into the task's session — NOT submitted (user reviews and presses
    /// Enter). Size-capped so a huge conflict can't flood the pty.
    @discardableResult
    func askClaudeToResolve() async -> Bool {
        guard let clone = await currentClone() else { return false }
        var prompt = "Please resolve the merge conflicts in \(clone.path). Conflicted files:\n"
        for conflict in conflicts {
            prompt += "- \(conflict.path)\n"
            if case .text(let blocks) = conflict.kind {
                for block in blocks {
                    let current = String(block.current.prefix(400))
                    let incoming = String(block.incoming.prefix(400))
                    prompt += "  <<< current\n\(current)\n=== incoming\n\(incoming)\n>>>\n"
                }
            }
            if prompt.count > 6000 {
                prompt += "…(truncated)\n"
                break
            }
        }
        return session.typeIntoSession(taskId: task.id, text: prompt)
    }

    /// Opens `$EDITOR` on a conflicted file in the clone, through the user's
    /// login shell (same resolution as sessions). Marker removal is picked up
    /// on the next classify (window focus / explicit refresh).
    func openInEditor(path: String) async {
        guard let clone = await currentClone() else { return }
        let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "open -t"
        let command = "exec " + editor + " " + ShellQuoterBridge.quote(path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell)
        process.arguments = ["-l", "-i", "-c", command]
        process.currentDirectoryURL = clone
        try? process.run()
    }

    /// Re-classify (e.g. after $EDITOR marker removal, on window focus).
    func refresh() async {
        state = await walk.state
        progress = await walk.repoProgress
        await refreshConflicts()
    }
}

/// Bridges to the adapter's ShellQuoter without importing it into every view.
enum ShellQuoterBridge {
    static func quote(_ word: String) -> String { LighthouseAdapter.ShellQuoter.quote(word) }
}
