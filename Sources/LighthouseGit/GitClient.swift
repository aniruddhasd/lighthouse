import Foundation

/// How `removeWorktree` treats local changes. Forcing requires a written
/// justification so that destroying unmerged work can never be a default
/// code path (guardrail: never destroy unmerged work silently).
public enum WorktreeRemovalMode: Sendable, Equatable {
    /// Refuse (with `GitClientError.dirtyWorktree`) if the worktree has
    /// modified or untracked files.
    case refuseIfDirty
    /// Pass `--force`, discarding local changes. The justification is the
    /// caller's record of the user confirmation that authorized it.
    case forceDiscardingChanges(justification: String)
}

/// The single place Lighthouse ever invokes git. All subprocess execution
/// uses argument arrays (no shell, no interpolation); every nonzero exit is
/// a typed thrown error except merge conflicts, which are an expected state
/// reported via `MergeOutcome`. This client has no network operations by
/// design — no fetch, pull, or push exists here; Lighthouse is fully offline.
public actor GitClient {
    private let gitExecutable: String

    public init(gitExecutable: String = "/usr/bin/git") {
        self.gitExecutable = gitExecutable
    }

    // MARK: - Worktrees

    /// `git worktree add -b <newBranch> <path> -- <baseRef>` — creates the
    /// worktree at `path` on a new branch cut from `baseRef`. The `--`
    /// separates `baseRef` so a ref beginning with `-` can never reach git's
    /// option parser (`worktree add` does not accept `--end-of-options`;
    /// verified git 2.50.1).
    public func addWorktree(
        at path: URL, newBranch: String, from baseRef: String, in repository: URL
    ) async throws {
        try await runExpectingSuccess(
            ["worktree", "add", "-b", newBranch, path.path, "--", baseRef], in: repository)
    }

    /// Parsed `git worktree list --porcelain -z`.
    public func listWorktrees(in repository: URL) async throws -> [Worktree] {
        let result = try await runExpectingSuccess(
            ["worktree", "list", "--porcelain", "-z"], in: repository)
        return try WorktreeListParser.parse(result.stdout)
    }

    /// `git worktree remove <path>`. With `.refuseIfDirty` (the default
    /// posture), a dirty worktree throws `GitClientError.dirtyWorktree` and
    /// the tree is left untouched.
    public func removeWorktree(
        at path: URL, in repository: URL, mode: WorktreeRemovalMode
    ) async throws {
        var arguments = ["worktree", "remove"]
        if case .forceDiscardingChanges = mode {
            arguments.append("--force")
        }
        arguments.append(path.path)
        try await runExpectingSuccess(arguments, in: repository)
    }

    // MARK: - Status

    /// Parsed `git status --porcelain=v2 --branch -z`. Unmerged (`u`) entries
    /// in the result are the conflict detector — including delete/modify and
    /// binary conflicts, which are never detected by reading file content.
    /// `--no-optional-locks` keeps frequent background status calls from
    /// contending on the index lock (documented in git-status(1)).
    public func status(in repository: URL) async throws -> RepoStatus {
        let result = try await runExpectingSuccess(
            ["--no-optional-locks", "status", "--porcelain=v2", "--branch",
             "--untracked-files=all", "-z"],
            in: repository)
        return try StatusV2Parser.parse(result.stdout)
    }

    // MARK: - Diff

    /// Raw patch text of `git diff <base>...HEAD` (changes on HEAD's side
    /// since the merge base).
    public func diffAgainstBase(_ base: String, in repository: URL) async throws -> String {
        let result = try await runExpectingSuccess(
            ["diff", "--end-of-options", "\(base)...HEAD", "--"], in: repository)
        return result.stdoutText
    }

    /// File list variant: `git diff --name-status -z <base>...HEAD`.
    public func diffNameStatus(against base: String, in repository: URL) async throws -> [DiffEntry] {
        let result = try await runExpectingSuccess(
            ["diff", "--name-status", "-z", "--end-of-options", "\(base)...HEAD", "--"], in: repository)
        return try Self.parseNameStatus(result.stdout)
    }

    /// LIVE diff for the review pane: `git diff --merge-base <base> --` —
    /// per git-diff(1), the working tree relative to the merge base of
    /// <base> and HEAD. Covers committed + staged + unstaged in one
    /// invocation and excludes base-side commits (verified live 2026-07-12);
    /// untracked files are separate (see untrackedFilePatch).
    public func liveDiff(againstMergeBaseOf base: String, in repository: URL) async throws -> String {
        let result = try await runExpectingSuccess(
            ["diff", "--merge-base", "--end-of-options", base, "--"], in: repository)
        return result.stdoutText
    }

    /// File list for the live diff: `git diff --name-status -z --merge-base <base> --`.
    public func liveDiffNameStatus(
        againstMergeBaseOf base: String, in repository: URL
    ) async throws -> [DiffEntry] {
        let result = try await runExpectingSuccess(
            ["diff", "--name-status", "-z", "--merge-base", "--end-of-options", base, "--"], in: repository)
        return try Self.parseNameStatus(result.stdout)
    }

    /// Renders an untracked file as an added-file patch:
    /// `git diff --no-index -- /dev/null <path>`. Like diff(1), --no-index
    /// exits 1 when differences exist — that is the expected outcome here,
    /// not a failure (git-diff(1) --exit-code semantics).
    public func untrackedFilePatch(for path: String, in repository: URL) async throws -> String {
        let arguments = ["diff", "--no-index", "--", "/dev/null", path]
        let result = try await run(arguments, in: repository)
        switch result.exitCode {
        case 0, 1: return result.stdoutText
        default: throw classify(result, arguments: arguments, in: repository)
        }
    }

    // MARK: - Merge

    /// `git merge --no-edit <branch>`. A conflict is returned as
    /// `.conflicted` with the unmerged paths — it is a state, not an error.
    public func merge(_ branch: String, in repository: URL) async throws -> MergeOutcome {
        let arguments = ["merge", "--no-edit", "--end-of-options", branch]
        let result = try await run(arguments, in: repository)
        return try await mergeOutcome(from: result, arguments: arguments, in: repository)
    }

    /// `git merge --continue` after conflicts have been resolved and staged.
    /// Uses a no-op editor so the default merge-commit message is taken.
    public func continueMerge(in repository: URL) async throws -> MergeOutcome {
        let arguments = ["-c", "core.editor=true", "merge", "--continue"]
        let result = try await run(arguments, in: repository)
        return try await mergeOutcome(from: result, arguments: arguments, in: repository)
    }

    /// True while a merge is in progress (MERGE_HEAD exists), verified via
    /// `git rev-parse -q --verify MERGE_HEAD` — the canonical check.
    public func isMergeInProgress(in repository: URL) async throws -> Bool {
        let result = try await run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: repository)
        switch result.exitCode {
        case 0: return true
        case 1 where result.stderrText.isEmpty: return false // -q: absent, quietly
        default: throw classify(result, arguments: ["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: repository)
        }
    }

    /// `git checkout --conflict=zdiff3 -- <path>` — re-materializes conflict
    /// markers (with the base section) in a conflicted file, e.g. after an
    /// external editor mangled them.
    public func rematerializeConflict(path: String, in repository: URL) async throws {
        try await runExpectingSuccess(
            ["checkout", "--conflict=zdiff3", "--", path], in: repository)
    }

    // MARK: - Branches

    /// `git branch --end-of-options <name> <startPoint>`. `--end-of-options`
    /// keeps a `name`/`startPoint` beginning with `-` out of git's option
    /// parser (verified git 2.50.1).
    public func createBranch(_ name: String, at startPoint: String = "HEAD", in repository: URL) async throws {
        try await runExpectingSuccess(
            ["branch", "--end-of-options", name, startPoint], in: repository)
    }

    /// `git branch -d <name>` (or `-D` when `force`). Deleting an unmerged
    /// branch without `force` fails with a typed error.
    public func deleteBranch(_ name: String, force: Bool = false, in repository: URL) async throws {
        try await runExpectingSuccess(
            ["branch", force ? "-D" : "-d", "--end-of-options", name], in: repository)
    }

    // MARK: - Branch and ancestry queries

    /// True if a local branch of this name exists
    /// (`git rev-parse -q --verify refs/heads/<name>`; exits 1 quietly when absent).
    public func branchExists(_ name: String, in repository: URL) async throws -> Bool {
        let arguments = ["rev-parse", "-q", "--verify", "--end-of-options", "refs/heads/\(name)"]
        let result = try await run(arguments, in: repository)
        switch result.exitCode {
        case 0: return true
        case 1 where result.stderrText.isEmpty: return false
        default: throw classify(result, arguments: arguments, in: repository)
        }
    }

    /// True if `ancestor`'s tip is reachable from `descendant`
    /// (`git merge-base --is-ancestor`; per git-merge-base(1): exit 0 = yes,
    /// 1 = no, any other nonzero = error).
    public func isAncestor(_ ancestor: String, of descendant: String, in repository: URL) async throws -> Bool {
        let arguments = ["merge-base", "--is-ancestor", "--end-of-options", ancestor, descendant]
        let result = try await run(arguments, in: repository)
        switch result.exitCode {
        case 0: return true
        case 1 where result.stderrText.isEmpty: return false
        default: throw classify(result, arguments: arguments, in: repository)
        }
    }

    /// True if `name` is a syntactically valid branch name
    /// (`git check-ref-format refs/heads/<name>`; exit 0 = valid, 1 = not).
    /// Needs no repository; runs in the temporary directory.
    public func isValidBranchName(_ name: String) async throws -> Bool {
        let arguments = ["check-ref-format", "refs/heads/\(name)"]
        let cwd = FileManager.default.temporaryDirectory
        let result = try await run(arguments, in: cwd)
        switch result.exitCode {
        case 0: return true
        case 1: return false
        default: throw classify(result, arguments: arguments, in: cwd)
        }
    }

    // MARK: - rev-parse helpers

    /// Resolves a path inside the .git directory
    /// (`git rev-parse --git-path <name>`), correctly following worktree and
    /// common-dir indirection (e.g. `info/exclude` from a linked worktree
    /// resolves to the repo's shared exclude file). Relative output is
    /// resolved against the query directory, matching git's cwd-relative
    /// behavior.
    public func gitPath(_ name: String, in repository: URL) async throws -> URL {
        let result = try await runExpectingSuccess(["rev-parse", "--git-path", name], in: repository)
        let path = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw GitClientError.unexpectedOutput(
                description: "rev-parse --git-path printed nothing", output: result.stdoutText)
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: path, relativeTo: repository).standardizedFileURL
    }

    /// Full object name of HEAD.
    public func headCommit(in repository: URL) async throws -> String {
        try await revParse("HEAD", in: repository)
    }

    /// Full object name of any revision (`git rev-parse --verify <rev>^{commit}`).
    public func revParse(_ revision: String, in repository: URL) async throws -> String {
        let result = try await runExpectingSuccess(
            ["rev-parse", "--verify", "--end-of-options", "\(revision)^{commit}"], in: repository)
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True if `path` is inside a git working tree; false for a plain
    /// directory (this query never throws not-a-repo).
    public func isInsideWorkTree(at path: URL) async throws -> Bool {
        let result = try await run(["rev-parse", "--is-inside-work-tree"], in: path)
        if result.exitCode == 0 {
            return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        }
        if case .notARepository = classify(result, arguments: ["rev-parse", "--is-inside-work-tree"], in: path) {
            return false
        }
        throw classify(result, arguments: ["rev-parse", "--is-inside-work-tree"], in: path)
    }

    /// Absolute path of the working-tree root containing `path`
    /// (`git rev-parse --show-toplevel`).
    public func topLevel(of path: URL) async throws -> URL {
        let result = try await runExpectingSuccess(["rev-parse", "--show-toplevel"], in: path)
        let top = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !top.isEmpty else {
            throw GitClientError.unexpectedOutput(
                description: "rev-parse --show-toplevel printed nothing", output: result.stdoutText)
        }
        return URL(fileURLWithPath: top, isDirectory: true)
    }

    // MARK: - Execution and error classification

    @discardableResult
    private func run(_ arguments: [String], in directory: URL) async throws -> ProcessResult {
        do {
            return try await ProcessRunner.run(
                executable: gitExecutable, arguments: arguments, workingDirectory: directory)
        } catch let error as ProcessLaunchError {
            throw GitClientError.launchFailed(executable: error.executable, reason: error.reason)
        }
    }

    @discardableResult
    private func runExpectingSuccess(_ arguments: [String], in directory: URL) async throws -> ProcessResult {
        let result = try await run(arguments, in: directory)
        guard result.exitCode == 0 else {
            throw classify(result, arguments: arguments, in: directory)
        }
        return result
    }

    private func mergeOutcome(
        from result: ProcessResult, arguments: [String], in repository: URL
    ) async throws -> MergeOutcome {
        if result.exitCode == 0 { return .merged }
        // Distinguish "stopped on conflicts" (a state) from real failure by
        // the canonical marker: MERGE_HEAD exists while a merge is unresolved.
        if try await isMergeInProgress(in: repository) {
            let status = try await status(in: repository)
            return .conflicted(paths: status.conflictedPaths)
        }
        throw classify(result, arguments: arguments, in: repository)
    }

    private func classify(
        _ result: ProcessResult, arguments: [String], in directory: URL
    ) -> GitClientError {
        let failure = GitCommandFailure(
            arguments: arguments,
            workingDirectory: directory.path,
            exitCode: result.exitCode,
            stderr: result.stderrText)
        let stderr = failure.stderr
        // Message texts from git 2.50.1 (setup.c "not a git repository",
        // builtin/worktree.c "contains modified or untracked files"); the
        // full stderr is always carried, so a future wording change degrades
        // to .commandFailed, never to a silent misclassification.
        if stderr.contains("not a git repository") {
            return .notARepository(path: directory.path, failure: failure)
        }
        if stderr.contains("contains modified or untracked files") {
            return .dirtyWorktree(path: directory.path, failure: failure)
        }
        return .commandFailed(failure)
    }

    // MARK: - name-status parsing

    /// Parses `diff --name-status -z` records: `<status>NUL<path>NUL`, with
    /// renames/copies as `R<score>NUL<src>NUL<dst>NUL`.
    static func parseNameStatus(_ data: Data) throws -> [DiffEntry] {
        let tokens = data.split(separator: UInt8(0), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        var entries: [DiffEntry] = []
        var index = 0
        while index < tokens.count {
            let status = tokens[index]
            if status.isEmpty { index += 1; continue }
            func nextToken(_ what: String) throws -> String {
                index += 1
                guard index < tokens.count, !tokens[index].isEmpty else {
                    throw GitClientError.unexpectedOutput(
                        description: "name-status '\(status)' missing \(what)", output: tokens.joined(separator: "|"))
                }
                return tokens[index]
            }
            switch status.first {
            case "A": entries.append(DiffEntry(change: .added, path: try nextToken("path")))
            case "M": entries.append(DiffEntry(change: .modified, path: try nextToken("path")))
            case "D": entries.append(DiffEntry(change: .deleted, path: try nextToken("path")))
            case "T": entries.append(DiffEntry(change: .typeChanged, path: try nextToken("path")))
            case "U": entries.append(DiffEntry(change: .unmerged, path: try nextToken("path")))
            case "R", "C":
                let score = Int(status.dropFirst()) ?? 0
                let source = try nextToken("source path")
                let target = try nextToken("target path")
                let change: DiffEntry.Change = status.first == "R"
                    ? .renamed(score: score) : .copied(score: score)
                entries.append(DiffEntry(change: change, path: target, originalPath: source))
            default:
                entries.append(DiffEntry(change: .other(status), path: try nextToken("path")))
            }
            index += 1
        }
        return entries
    }
}
