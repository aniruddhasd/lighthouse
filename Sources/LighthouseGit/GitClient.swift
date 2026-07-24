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
/// uses argument arrays (no shell, no interpolation); every nonzero exit is a
/// typed thrown error. This client has no network operations by design — no
/// fetch, pull, or push exists here; Lighthouse is fully offline.
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

    /// `git worktree add --detach <path> -- <ref>` — a worktree checked out at
    /// `ref` with a DETACHED HEAD (no new branch created). The empty landing
    /// spot a PR checkout switches onto the PR's branch (see PullRequestCheckout);
    /// `--` fences a ref beginning with `-` from the option parser.
    public func addDetachedWorktree(at path: URL, from ref: String, in repository: URL) async throws {
        try await runExpectingSuccess(
            ["worktree", "add", "--detach", path.path, "--", ref], in: repository)
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

    /// UNCOMMITTED changes only: `git diff HEAD --` — the working tree (staged +
    /// unstaged) relative to the last commit, excluding committed branch work.
    /// The "what have I not committed yet" view; untracked files are separate.
    public func uncommittedDiff(in repository: URL) async throws -> String {
        let result = try await runExpectingSuccess(
            ["diff", "--end-of-options", "HEAD", "--"], in: repository)
        return result.stdoutText
    }

    /// File list for the uncommitted diff: `git diff --name-status -z HEAD --`.
    public func uncommittedNameStatus(in repository: URL) async throws -> [DiffEntry] {
        let result = try await runExpectingSuccess(
            ["diff", "--name-status", "-z", "--end-of-options", "HEAD", "--"], in: repository)
        return try Self.parseNameStatus(result.stdout)
    }

    /// Deterministic add/del/file counts for the live review surface:
    /// `git diff --numstat --merge-base <base> --` — the working tree relative
    /// to the merge base of `<base>` and HEAD (committed + staged + unstaged),
    /// the same range as `liveDiff`. `--end-of-options` keeps a base ref
    /// beginning with `-` out of git's option parser (verified git 2.50.1,
    /// mirroring the neighbouring diff methods); parsing (binary `-`/`-`,
    /// renames, zero-change) is handled by the pure `DiffStat.parse`. Untracked
    /// files are NOT counted here (they never appear in a diff vs the merge
    /// base) — the live review surface renders them separately.
    public func diffStat(worktree: URL, base: String) async throws -> DiffStat {
        let result = try await runExpectingSuccess(
            ["diff", "--numstat", "--merge-base", "--end-of-options", base, "--"], in: worktree)
        return DiffStat.parse(numstat: result.stdoutText)
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

    /// The clone's current branch short-name, or nil if detached/unborn.
    /// Auto-suggests the base branch at repo registration.
    public func currentBranch(in repository: URL) async throws -> String? {
        let result = try await run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: repository)
        switch result.exitCode {
        case 0:
            let name = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        case 1: return nil // detached HEAD
        default: throw classify(result, arguments: ["symbolic-ref", "--short", "HEAD"], in: repository)
        }
    }

    /// Absolute path of the git directory for `repository`
    /// (`git rev-parse --absolute-git-dir`). For a linked worktree this is the
    /// per-worktree gitdir `<main>/.git/worktrees/<name>/` — where this
    /// worktree's HEAD/index/reflog live, so it changes on this worktree's
    /// stage/commit. The review watcher watches it so a bare `git commit`
    /// (which writes nothing under the worktree tree) still triggers a refresh.
    public func gitDirectory(in repository: URL) async throws -> URL {
        let result = try await runExpectingSuccess(["rev-parse", "--absolute-git-dir"], in: repository)
        let path = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw GitClientError.unexpectedOutput(
                description: "rev-parse --absolute-git-dir printed nothing", output: result.stdoutText)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
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

    // MARK: - History and file browsing (Phase A navigator)

    /// Recent commits, newest first: `git log --max-count=<limit>
    /// --format=<delimiter-safe> --no-color`. `limit` is an Int (not a
    /// string), so no ref or option can flow in — there is nothing to guard.
    /// An empty (unborn) repository is a normal state, not an error: it yields
    /// `[]`. The format and the parser share `CommitLogParser.format`, so the
    /// writer and reader cannot drift.
    public func commitLog(worktree: URL, limit: Int) async throws -> [CommitSummary] {
        let count = max(0, limit)
        let arguments = ["log", "--max-count=\(count)", "--format=\(CommitLogParser.format)", "--no-color"]
        let result = try await run(arguments, in: worktree)
        if result.exitCode == 0 {
            return try CommitLogParser.parse(result.stdout)
        }
        // `git log` on a repo with no commits exits 128 ("does not have any
        // commits yet"). Distinguish that unborn state — the one non-error
        // failure — from a real fault via the canonical HEAD check, rather
        // than matching stderr text.
        if try await isUnborn(worktree) { return [] }
        throw classify(result, arguments: arguments, in: worktree)
    }

    /// Patch for a single commit, suitable for diff2html: `git show
    /// --format= --patch --end-of-options <hash> --`. `--format=` drops the
    /// commit header so the output is a clean unified diff; a root commit (no
    /// parent) renders as an all-added patch (verified git 2.50.1). `hash` is
    /// the one place a rev reaches `git show`, so it is validated to 4–40 hex
    /// chars BEFORE any subprocess runs (an invalid value throws and never
    /// launches git); `--end-of-options` is the belt-and-suspenders guard.
    public func commitDiff(worktree: URL, hash: String) async throws -> String {
        guard Self.isValidCommitHash(hash) else {
            throw GitClientError.invalidRevision(hash)
        }
        let arguments = ["show", "--format=", "--patch", "--end-of-options", hash, "--"]
        let result = try await runExpectingSuccess(arguments, in: worktree)
        return result.stdoutText
    }

    /// True iff `hash` is 4–40 hexadecimal characters (`^[0-9a-fA-F]{4,40}$`).
    /// Anything with a leading dash, slash, semicolon, or `=` fails here, so
    /// `--output=…`, `-x`, and `; rm` can never reach `git show`.
    static func isValidCommitHash(_ hash: String) -> Bool {
        let count = hash.count
        return count >= 4 && count <= 40 && hash.allSatisfy { $0.isHexDigit }
    }

    /// gitignore-aware file list, relative paths, NUL-parsed:
    /// `git ls-files -z --cached --others --exclude-standard`. `--cached` is
    /// tracked files, `--others` is untracked ones, and `--exclude-standard`
    /// applies `.gitignore`/`.git/info/exclude`/global excludes — so an
    /// ignored `node_modules/` never appears while an untracked, non-ignored
    /// file does. No ref or path argument, so nothing to guard.
    public func listFiles(worktree: URL) async throws -> [String] {
        let arguments = ["ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        let result = try await runExpectingSuccess(arguments, in: worktree)
        return result.stdout
            .split(separator: UInt8(0), omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// `git grep` for the ⌘F content search. `-I` skips binary files, `-z -n`
    /// gives the `path\0line\0text\n` records parsed below, `--no-color` keeps
    /// the text clean. `regex` picks extended-regex (`-E`) vs a literal string
    /// (`--fixed-strings`); `caseSensitive == false` adds `-i`. The pattern
    /// rides as `-e <pattern>` (never positional, so a leading `-` is data, not
    /// an option) and `--end-of-options`/`--` fence off the optional folder
    /// pathspec. Exit 1 is git grep's "no matches" — an empty result, not an
    /// error; a bad pattern (unbalanced regex) or a missing folder exits >1 and
    /// surfaces as `.commandFailed` with git's own message. `-m <limit>` caps
    /// matches PER FILE so one match-dense file can't flood stdout before the
    /// total is capped in `parseGrep`.
    public func grep(
        worktree: URL, pattern: String, regex: Bool, caseSensitive: Bool,
        folder: String? = nil, limit: Int = 500
    ) async throws -> [GrepMatch] {
        guard !pattern.isEmpty else { return [] }
        var arguments = ["grep", "--no-color", "-n", "-I", "-z", "-m", String(limit)]
        arguments.append(regex ? "-E" : "--fixed-strings")
        if !caseSensitive { arguments.append("-i") }
        arguments.append(contentsOf: ["-e", pattern, "--end-of-options", "--"])
        if let folder, !folder.isEmpty { arguments.append(folder) }

        let result = try await run(arguments, in: worktree)
        switch result.exitCode {
        case 0: break
        case 1: return []  // git grep: no matches
        default: throw classify(result, arguments: arguments, in: worktree)
        }
        return Self.parseGrep(result.stdout, limit: limit)
    }

    /// Parses `git grep -z -n` output: newline-separated records, each
    /// `path\0lineNumber\0lineText`. maxSplits keeps any (improbable) NUL in the
    /// text intact; a record that is malformed or lacks a numeric line is
    /// skipped rather than fabricated.
    ///
    /// Caveat: `git grep -z` NUL-terminates only the FILENAME, not the record —
    /// the record separator stays newline. git grep has no full-NUL mode, so a
    /// tracked file whose NAME contains a literal newline (vanishingly rare)
    /// would split mid-path here; such a record is dropped, never mis-attributed.
    static func parseGrep(_ data: Data, limit: Int) -> [GrepMatch] {
        var matches: [GrepMatch] = []
        for record in data.split(separator: UInt8(0x0A), omittingEmptySubsequences: true) {
            let fields = record.split(
                separator: UInt8(0), maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let line = Int(String(decoding: fields[1], as: UTF8.self)) else { continue }
            matches.append(GrepMatch(
                path: String(decoding: fields[0], as: UTF8.self),
                line: line,
                text: String(decoding: fields[2], as: UTF8.self)))
            if matches.count >= limit { break }
        }
        return matches
    }

    /// Reads a repo file for the content viewer. This is a FILESYSTEM read,
    /// not a git call, so it carries its own hard boundary: the worktree root
    /// and the resolved target are both canonicalized with realpath(3), then
    /// the target must be contained in the root by normalized path COMPONENTS
    /// (the same check as `LocalOnlyNavigationDelegate.isContained`, duplicated
    /// here because LighthouseGit cannot depend on the app target). That one
    /// check rejects `..`, absolute paths, and symlinks whose target escapes
    /// the tree. Size is capped at 2 MiB (`.tooLarge`); a NUL byte in the
    /// first 8 KiB marks binary (`.binary`); text is decoded UTF-8 lossily.
    public func fileContents(worktree: URL, relativePath: String) async throws -> FileContents {
        guard let canonicalRoot = Self.realPath(worktree.path) else {
            throw GitClientError.fileUnreadable(
                relativePath: relativePath, reason: "worktree root not resolvable")
        }
        let joined = URL(
            fileURLWithPath: relativePath,
            relativeTo: URL(fileURLWithPath: canonicalRoot, isDirectory: true))
        guard let canonicalTarget = Self.realPath(joined.path) else {
            throw GitClientError.fileUnreadable(relativePath: relativePath, reason: "no such file")
        }
        guard Self.isContained(canonicalTarget, within: canonicalRoot) else {
            throw GitClientError.pathOutsideWorktree(relativePath: relativePath)
        }

        let fileManager = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: canonicalTarget)
        } catch {
            throw GitClientError.fileUnreadable(
                relativePath: relativePath, reason: String(describing: error))
        }
        if (attributes[.type] as? FileAttributeType) == .typeDirectory {
            throw GitClientError.fileUnreadable(relativePath: relativePath, reason: "is a directory")
        }

        let sizeCap = 2 * 1024 * 1024
        let size = (attributes[.size] as? Int) ?? 0
        if size > sizeCap { return .tooLarge(bytes: size) }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: canonicalTarget))
        } catch {
            throw GitClientError.fileUnreadable(
                relativePath: relativePath, reason: String(describing: error))
        }
        // git's own binary heuristic: a NUL in the first 8 KiB.
        if data.prefix(8192).contains(0) { return .binary }
        return .text(String(decoding: data, as: UTF8.self))
    }

    /// realpath(3) wrapper: fully resolves symlinks and `..`; nil if the path
    /// does not exist. Mirrors FixtureFactory's use of realpath — chosen over
    /// URL.resolvingSymlinksInPath(), which strips the /private prefix on macOS.
    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True iff `path` is `root` or a descendant, by normalized path
    /// components — never a raw string prefix, which would accept a sibling
    /// whose name extends root's (the bug fixed in the nav gate 2026-07-13).
    private static func isContained(_ path: String, within root: String) -> Bool {
        let rootComponents = URL(fileURLWithPath: root).standardizedFileURL.pathComponents
        let pathComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard pathComponents.count >= rootComponents.count else { return false }
        return Array(pathComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// True when the repository has no commits yet (unborn HEAD):
    /// `git rev-parse -q --verify HEAD` exits 1 quietly. Used to treat an
    /// empty repo's `git log` failure as `[]` rather than an error.
    private func isUnborn(_ repository: URL) async throws -> Bool {
        let result = try await run(["rev-parse", "-q", "--verify", "HEAD"], in: repository)
        switch result.exitCode {
        case 0: return false
        case 1 where result.stderrText.isEmpty: return true
        default: return false // some other failure — let the caller's error surface
        }
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
