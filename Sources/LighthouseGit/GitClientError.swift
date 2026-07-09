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
        }
    }
}
