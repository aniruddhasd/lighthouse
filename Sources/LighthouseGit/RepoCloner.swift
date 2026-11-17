import Foundation

/// Errors from a clone. `cloneFailed` carries git's stderr verbatim so an auth
/// or network failure is reported in git's own words, not a lossy paraphrase.
public enum RepoCloneError: Error, Sendable, Equatable {
    case launchFailed(reason: String)
    case cloneFailed(stderr: String)
}

/// The ONE place Lighthouse performs a network git operation. It is kept out of
/// `GitClient` on purpose — that client is contractually offline (no fetch,
/// pull, or push) — so cloning a remote lives here, isolated, and that
/// invariant stays legible.
///
/// Like `GitClient`, it invokes git through an argument array (never a shell).
/// `--` fences the URL against option injection; `GIT_TERMINAL_PROMPT=0` makes
/// a missing credential fail fast instead of hanging a TTY-less subprocess.
/// Lighthouse never handles credentials — auth rides the ambient git credential
/// helper / SSH agent, which is why the inherited environment is preserved.
public struct RepoCloner: Sendable {
    private let gitExecutable: String

    public init(gitExecutable: String = "/usr/bin/git") {
        self.gitExecutable = gitExecutable
    }

    /// `git clone -- <url> <destination>`, run from the destination's parent.
    /// Throws `RepoCloneError.cloneFailed` (with git's stderr) on any nonzero
    /// exit. The caller owns pre-flight (valid URL, parent exists, destination
    /// absent) — this method only runs the clone.
    public func clone(url: String, into destination: URL) async throws {
        // Merge onto the inherited environment; assigning a bare dictionary
        // would wipe PATH/HOME/SSH_AUTH_SOCK and break SSH auth and git's own
        // helper lookups. GIT_TERMINAL_PROMPT=0 turns a missing credential into
        // a fast failure rather than a hung subprocess waiting on a TTY.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"

        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: gitExecutable,
                arguments: ["clone", "--", url, destination.path],
                workingDirectory: destination.deletingLastPathComponent(),
                environment: environment)
        } catch let error as ProcessLaunchError {
            throw RepoCloneError.launchFailed(reason: error.reason)
        }
        guard result.exitCode == 0 else {
            throw RepoCloneError.cloneFailed(stderr: result.stderrText)
        }
    }
}
