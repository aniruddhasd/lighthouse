import Foundation

/// Everything needed to reproduce and diagnose a failed git invocation.
public struct GitCommandFailure: Sendable, Equatable {
    public let arguments: [String]
    public let workingDirectory: String
    public let exitCode: Int32
    public let stderr: String

    public init(arguments: [String], workingDirectory: String, exitCode: Int32, stderr: String) {
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.exitCode = exitCode
        self.stderr = stderr
    }
}

/// Typed failures from GitClient. Nonzero exits always surface here — there
/// are no silent fallbacks. A merge conflict is deliberately NOT an error;
/// it is reported as `MergeOutcome.conflicted`.
public enum GitClientError: Error, Sendable, Equatable {
    /// The directory is not inside a git repository.
    case notARepository(path: String, failure: GitCommandFailure)
    /// The operation refused to run because the working tree has local
    /// changes (e.g. `worktree remove` without force on a dirty tree).
    case dirtyWorktree(path: String, failure: GitCommandFailure)
    /// Any other nonzero git exit.
    case commandFailed(GitCommandFailure)
    /// The git executable could not be launched at all.
    case launchFailed(executable: String, reason: String)
    /// git exited 0 but its output did not match the documented porcelain
    /// format; the raw output is carried for diagnosis.
    case unexpectedOutput(description: String, output: String)
    /// A revision argument failed validation before any subprocess ran (e.g.
    /// `commitDiff` rejects anything that is not 4–40 hex chars — the one
    /// place a rev flows into `git show`, so it is validated, not just guarded).
    case invalidRevision(String)
    /// `fileContents` refused a path that resolves outside the worktree root
    /// (`..`, an absolute path, or a symlink escaping the tree).
    case pathOutsideWorktree(relativePath: String)
    /// `fileContents` could not read the resolved file (missing, a directory,
    /// or a filesystem error); the reason is carried for diagnosis.
    case fileUnreadable(relativePath: String, reason: String)
}

extension GitClientError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notARepository(let path, _):
            return "not a git repository: \(path)"
        case .dirtyWorktree(let path, let failure):
            return "worktree has local changes: \(path) — \(failure.stderr)"
        case .commandFailed(let failure):
            return "git \(failure.arguments.joined(separator: " ")) in \(failure.workingDirectory) "
                + "exited \(failure.exitCode): \(failure.stderr)"
        case .launchFailed(let executable, let reason):
            return "could not launch \(executable): \(reason)"
        case .unexpectedOutput(let description, _):
            return "unexpected git output: \(description)"
        case .invalidRevision(let revision):
            return "not a valid commit hash: \(revision)"
        case .pathOutsideWorktree(let relativePath):
            return "path resolves outside the worktree: \(relativePath)"
        case .fileUnreadable(let relativePath, let reason):
            return "cannot read \(relativePath): \(reason)"
        }
    }
}
