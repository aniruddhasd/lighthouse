import Foundation

/// A throwaway git repository with known, deterministic state.
public struct FixtureRepo: Sendable {
    /// Root of the repository's working tree.
    public let path: URL
    /// The branch the repository was initialized with (`main` unless a scenario says otherwise).
    public let defaultBranch: String

    public init(path: URL, defaultBranch: String) {
        self.path = path
        self.defaultBranch = defaultBranch
    }
}

/// A repository with all three kinds of dirt in the working tree.
public struct DirtyRepoFixture: Sendable {
    public let repo: FixtureRepo
    /// Tracked file with a modification that has been `git add`ed.
    public let stagedPath: String
    /// Tracked file with a modification that has NOT been staged.
    public let unstagedPath: String
    /// File git has never seen.
    public let untrackedPath: String
}

/// A repository whose HEAD is detached at a known commit.
public struct DetachedHeadFixture: Sendable {
    public let repo: FixtureRepo
    /// Full object name HEAD is detached at.
    public let detachedAt: String
}

/// Two branches guaranteed to conflict when `incomingBranch` is merged into `baseBranch`.
public struct ConflictFixture: Sendable {
    public let repo: FixtureRepo
    /// Branch currently checked out; the merge target.
    public let baseBranch: String
    /// Branch whose merge into `baseBranch` produces the conflict.
    public let incomingBranch: String
    /// Repository-relative path of the file that conflicts.
    public let conflictedPath: String
}

/// A repository (with a path containing spaces) plus a not-yet-created
/// worktree destination whose path also contains spaces.
public struct SpacesFixture: Sendable {
    public let repo: FixtureRepo
    /// Destination for a `worktree add`; contains spaces; does not exist yet.
    public let worktreeDestination: URL
}

/// A repository with linked worktrees already attached.
public struct AttachedWorktreesFixture: Sendable {
    public let repo: FixtureRepo
    /// Path and branch of each attached (linked) worktree.
    public let worktrees: [(path: URL, branch: String)]
}

public struct FixtureError: Error, CustomStringConvertible {
    public let description: String
}

/// Creates hermetic, throwaway git repositories in a private temporary
/// directory. Hermetic means: `git init -b <branch>` locally, identity and
/// signing configured per-repository (repo-local config only), global and
/// system config masked during creation, no network, no global state touched.
///
/// Call `destroy()` (or rely on the owning test's `deinit`) to delete
/// everything the factory created.
public struct FixtureFactory: Sendable {
    public let root: URL
    private let gitPath: String

    public init(gitPath: String = "/usr/bin/git") throws {
        self.gitPath = gitPath
        let proposed = FileManager.default.temporaryDirectory
            .appendingPathComponent("lighthouse-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: proposed, withIntermediateDirectories: true)
        // Canonicalize so fixture paths compare equal to the paths git
        // reports: macOS's temp dir lives under /var, a symlink to
        // /private/var, and git prints the resolved form. realpath(3),
        // because URL.resolvingSymlinksInPath() deliberately strips the
        // /private prefix back off and is a no-op for exactly this case.
        guard let resolved = realpath(proposed.path, nil) else {
            throw FixtureError(description: "realpath failed for \(proposed.path)")
        }
        defer { free(resolved) }
        self.root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// Deletes every fixture this factory created.
    public func destroy() throws {
        try FileManager.default.removeItem(at: root)
    }

    // MARK: - Scenarios

    /// Linear history on the default branch, clean working tree.
    public func cleanRepo(defaultBranch: String = "main", commitCount: Int = 3) throws -> FixtureRepo {
        let repo = try initRepo(named: "clean", branch: defaultBranch)
        for i in 1...max(1, commitCount) {
            try write("notes.txt", "line \(i)\n", in: repo, appending: true)
            try git(["add", "notes.txt"], in: repo.path)
            try git(["commit", "-m", "commit \(i)"], in: repo.path)
        }
        return repo
    }

    /// Same as `cleanRepo` but the base branch is `develop`.
    public func developBaseRepo() throws -> FixtureRepo {
        try cleanRepo(defaultBranch: "develop")
    }

    /// Working tree with staged, unstaged, and untracked changes at once.
    public func dirtyRepo() throws -> DirtyRepoFixture {
        let repo = try initRepo(named: "dirty", branch: "main")
        try write("staged.txt", "original staged\n", in: repo)
        try write("tracked.txt", "original tracked\n", in: repo)
        try git(["add", "."], in: repo.path)
        try git(["commit", "-m", "baseline"], in: repo.path)

        try write("staged.txt", "modified and staged\n", in: repo)
        try git(["add", "staged.txt"], in: repo.path)
        try write("tracked.txt", "modified, not staged\n", in: repo)
        try write("untracked.txt", "never added\n", in: repo)

        return DirtyRepoFixture(
            repo: repo,
            stagedPath: "staged.txt",
            unstagedPath: "tracked.txt",
            untrackedPath: "untracked.txt"
        )
    }

    /// HEAD detached at the first commit of a two-commit history.
    public func detachedHeadRepo() throws -> DetachedHeadFixture {
        let repo = try cleanRepo(commitCount: 2)
        let target = try git(["rev-parse", "HEAD~1"], in: repo.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["checkout", "--detach", target], in: repo.path)
        return DetachedHeadFixture(repo: repo, detachedAt: target)
    }

    /// `main` and `feature` both edit the same line of the same file.
    /// Merging `feature` into `main` produces a content (both-modified) conflict.
    public func contentConflictRepo() throws -> ConflictFixture {
        let repo = try initRepo(named: "content-conflict", branch: "main")
        let file = "shared.txt"
        try write(file, "alpha\ncommon\nomega\n", in: repo)
        try git(["add", file], in: repo.path)
        try git(["commit", "-m", "base"], in: repo.path)

        try git(["checkout", "-b", "feature"], in: repo.path)
        try write(file, "alpha\nfeature change\nomega\n", in: repo)
        try git(["commit", "-am", "feature edit"], in: repo.path)

        try git(["checkout", "main"], in: repo.path)
        try write(file, "alpha\nmain change\nomega\n", in: repo)
        try git(["commit", "-am", "main edit"], in: repo.path)

        return ConflictFixture(repo: repo, baseBranch: "main", incomingBranch: "feature", conflictedPath: file)
    }

    /// `main` modifies a file that `feature` deletes. Merging `feature` into
    /// `main` produces a delete/modify conflict ("deleted by them").
    public func deleteModifyConflictRepo() throws -> ConflictFixture {
        let repo = try initRepo(named: "delete-modify-conflict", branch: "main")
        let file = "victim.txt"
        try write(file, "original\n", in: repo)
        try git(["add", file], in: repo.path)
        try git(["commit", "-m", "base"], in: repo.path)

        try git(["checkout", "-b", "feature"], in: repo.path)
        try git(["rm", file], in: repo.path)
        try git(["commit", "-m", "delete on feature"], in: repo.path)

        try git(["checkout", "main"], in: repo.path)
        try write(file, "modified on main\n", in: repo)
        try git(["commit", "-am", "modify on main"], in: repo.path)

        return ConflictFixture(repo: repo, baseBranch: "main", incomingBranch: "feature", conflictedPath: file)
    }

    /// Both branches commit different binary content (bytes containing NUL,
    /// which git classifies as binary) to the same path. Merging conflicts.
    public func binaryConflictRepo() throws -> ConflictFixture {
        let repo = try initRepo(named: "binary-conflict", branch: "main")
        let file = "blob.bin"
        try writeBytes([0x00, 0x01, 0x02, 0xFF, 0x00], to: file, in: repo)
        try git(["add", file], in: repo.path)
        try git(["commit", "-m", "base blob"], in: repo.path)

        try git(["checkout", "-b", "feature"], in: repo.path)
        try writeBytes([0x00, 0xAA, 0xBB, 0x00, 0x10], to: file, in: repo)
        try git(["commit", "-am", "feature blob"], in: repo.path)

        try git(["checkout", "main"], in: repo.path)
        try writeBytes([0x00, 0xCC, 0xDD, 0x00, 0x20], to: file, in: repo)
        try git(["commit", "-am", "main blob"], in: repo.path)

        return ConflictFixture(repo: repo, baseBranch: "main", incomingBranch: "feature", conflictedPath: file)
    }

    /// Repository whose own path contains spaces, plus a worktree destination
    /// path (not yet created) that also contains spaces.
    public func spacesRepo() throws -> SpacesFixture {
        let scenario = try scenarioDirectory(named: "spaces")
        let repoDir = scenario.appendingPathComponent("repo with spaces", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], in: repoDir)
        try configureIdentity(in: repoDir)
        let repo = FixtureRepo(path: repoDir, defaultBranch: "main")
        try write("read me.txt", "content\n", in: repo)
        try git(["add", "."], in: repo.path)
        try git(["commit", "-m", "base"], in: repo.path)
        let worktreeDestination = scenario.appendingPathComponent("work tree with spaces", isDirectory: true)
        return SpacesFixture(repo: repo, worktreeDestination: worktreeDestination)
    }

    /// Repository with `count` linked worktrees already attached, each on its
    /// own branch (`wt-1`, `wt-2`, ...) cut from the default branch tip.
    public func repoWithAttachedWorktrees(count: Int = 2) throws -> AttachedWorktreesFixture {
        let repo = try cleanRepo(commitCount: 1)
        var worktrees: [(path: URL, branch: String)] = []
        for i in 1...max(1, count) {
            let branch = "wt-\(i)"
            let path = repo.path.deletingLastPathComponent()
                .appendingPathComponent("attached-\(i)", isDirectory: true)
            try git(["worktree", "add", "-b", branch, path.path, repo.defaultBranch], in: repo.path)
            worktrees.append((path: path, branch: branch))
        }
        return AttachedWorktreesFixture(repo: repo, worktrees: worktrees)
    }

    /// A directory that exists but is not a git repository.
    public func nonRepoDirectory() throws -> URL {
        let dir = try scenarioDirectory(named: "not-a-repo")
        try Data("just a file\n".utf8).write(to: dir.appendingPathComponent("plain.txt"))
        return dir
    }

    // MARK: - Escape hatch for tests

    /// Runs git in a fixture repository. Tests use this for setup steps that
    /// are deliberately NOT part of GitClient's API surface (e.g. `git add`
    /// to stage a conflict resolution). Throws on nonzero exit.
    @discardableResult
    public func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // Mask global/system config so fixture creation is identical on every
        // machine (the author's global config has commit.gpgsign=true, which
        // would otherwise make every fixture commit try to sign).
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Fixture command output is tiny; sequential reads cannot fill a pipe buffer.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError(description:
                "git \(arguments.joined(separator: " ")) in \(directory.path) "
                + "exited \(process.terminationStatus): "
                + String(decoding: errData, as: UTF8.self))
        }
        return String(decoding: outData, as: UTF8.self)
    }

    // MARK: - Internals

    private func scenarioDirectory(named name: String) throws -> URL {
        let dir = root.appendingPathComponent(
            "\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func initRepo(named name: String, branch: String) throws -> FixtureRepo {
        let dir = try scenarioDirectory(named: name)
        try git(["init", "-b", branch], in: dir)
        try configureIdentity(in: dir)
        return FixtureRepo(path: dir, defaultBranch: branch)
    }

    /// Repo-local config only. Local values also shield later GitClient
    /// invocations (which run with the real user environment) from the
    /// developer's global config: identity for merge commits, gpgsign off,
    /// autocrlf off for byte-stable fixtures.
    private func configureIdentity(in dir: URL) throws {
        try git(["config", "user.name", "Lighthouse Fixture"], in: dir)
        try git(["config", "user.email", "fixture@lighthouse.invalid"], in: dir)
        try git(["config", "commit.gpgsign", "false"], in: dir)
        try git(["config", "core.autocrlf", "false"], in: dir)
    }

    private func write(_ relativePath: String, _ content: String, in repo: FixtureRepo, appending: Bool = false) throws {
        let url = repo.path.appendingPathComponent(relativePath)
        if appending, FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(content.utf8))
        } else {
            try Data(content.utf8).write(to: url)
        }
    }

    private func writeBytes(_ bytes: [UInt8], to relativePath: String, in repo: FixtureRepo) throws {
        try Data(bytes).write(to: repo.path.appendingPathComponent(relativePath))
    }
}
