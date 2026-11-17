import Foundation

/// A resolved pull request — the fields Lighthouse needs to name the task and
/// its branch.
public struct PullRequestInfo: Sendable, Equatable {
    public let number: Int
    public let title: String

    public init(number: Int, title: String) {
        self.number = number
        self.title = title
    }
}

public enum PullRequestCheckoutError: Error, Sendable, Equatable {
    /// The `gh` CLI could not be located — required for PR checkout (it handles
    /// fork remotes + upstream tracking so commits can be pushed back).
    case ghNotAvailable
    /// The reference is empty, an option-lookalike, or not a PR number/URL.
    case invalidReference(String)
    /// `gh pr view` failed — the PR does not exist, is in another repo, or auth
    /// is missing. Carries gh's stderr verbatim.
    case resolveFailed(stderr: String)
    /// `gh pr checkout` failed after the worktree was made. Carries gh's stderr.
    case checkoutFailed(stderr: String)
    /// gh/git could not be launched at all.
    case launchFailed(reason: String)
}

/// Fetches a GitHub pull request into a work tree and checks it out on a local
/// branch that tracks the PR's head — so commits can be pushed back to the PR.
///
/// This is a NETWORK operation, kept out of the offline `GitClient` (same as
/// `RepoCloner`). It leans on `gh pr checkout`, which already does the hard part
/// correctly: fetch the PR (even from a fork), add the fork remote when needed,
/// create the local branch, and set upstream tracking. The two-step dance —
/// `GitClient.addDetachedWorktree` first, then `gh pr checkout` INSIDE that
/// work tree — is how the branch lands in a worktree rather than the main
/// checkout (gh has no worktree flag; verified 2026-07-24).
///
/// gh is invoked through an argument array (never a shell); the PR reference is
/// validated to a number or URL and can never begin with `-`. Auth rides gh's
/// own configured credentials — Lighthouse handles none.
public struct PullRequestCheckout: Sendable {
    private let explicitGhExecutable: String?
    private let loginShell: String

    public init(
        ghExecutable: String? = nil,
        loginShell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    ) {
        self.explicitGhExecutable = ghExecutable
        self.loginShell = loginShell
    }

    /// A reference is usable when it is a bare PR number or a URL containing
    /// `/pull/`, and never begins with `-` (which would reach gh's option
    /// parser). Pure and unit-tested.
    public static func isValidReference(_ reference: String) -> Bool {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return false }
        if trimmed.allSatisfy(\.isNumber) { return true }
        return trimmed.contains("/pull/")
    }

    /// The local branch a PR lands on: `pr-<number>` — collision-safe and clear,
    /// never the head branch name (which could clash with an existing local
    /// branch).
    public static func localBranch(for number: Int) -> String { "pr-\(number)" }

    /// `gh pr view <reference> --json number,title` in `repository`. Validates
    /// the PR exists and returns its number + title (the task-name default).
    public func resolve(reference: String, in repository: URL) async throws -> PullRequestInfo {
        guard Self.isValidReference(reference) else {
            throw PullRequestCheckoutError.invalidReference(reference)
        }
        let gh = try await ghPath()
        let result = try await runGh(
            gh, ["pr", "view", reference, "--json", "number,title"], in: repository)
        guard result.exitCode == 0 else {
            throw PullRequestCheckoutError.resolveFailed(stderr: result.stderrText)
        }
        struct Wire: Decodable { let number: Int; let title: String }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: result.stdout) else {
            throw PullRequestCheckoutError.resolveFailed(
                stderr: "unexpected gh output: \(result.stdoutText)")
        }
        return PullRequestInfo(number: wire.number, title: wire.title)
    }

    /// `gh pr checkout <reference> -b <localBranch>` run INSIDE `worktree` (a
    /// detached work tree the caller already created). Fetches the PR, sets up
    /// the fork remote + tracking, and checks the branch out there. Throws
    /// `checkoutFailed` with gh's stderr; the caller removes the worktree.
    public func checkout(reference: String, localBranch: String, in worktree: URL) async throws {
        guard Self.isValidReference(reference) else {
            throw PullRequestCheckoutError.invalidReference(reference)
        }
        let gh = try await ghPath()
        let result = try await runGh(
            gh, ["pr", "checkout", reference, "-b", localBranch], in: worktree)
        guard result.exitCode == 0 else {
            throw PullRequestCheckoutError.checkoutFailed(stderr: result.stderrText)
        }
    }

    // MARK: - gh invocation

    private func runGh(
        _ gh: String, _ arguments: [String], in directory: URL
    ) async throws -> ProcessResult {
        // gh shells out to git and reads its own auth from HOME; augment PATH so
        // a Homebrew git resolves even under launchd's minimal PATH, and disable
        // git's terminal prompt so a missing credential fails fast.
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        do {
            return try await ProcessRunner.run(
                executable: gh, arguments: arguments,
                workingDirectory: directory, environment: environment)
        } catch let error as ProcessLaunchError {
            throw PullRequestCheckoutError.launchFailed(reason: error.reason)
        }
    }

    /// Locates `gh`: an explicit override, then the usual install paths, then a
    /// login-shell PATH lookup (the app's own environment lacks Homebrew under
    /// launchd). Throws `ghNotAvailable` if none resolves.
    private func ghPath() async throws -> String {
        if let explicitGhExecutable { return explicitGhExecutable }
        for candidate in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        // Fixed command, no user input — safe to run through the login shell.
        if let result = try? await ProcessRunner.run(
            executable: loginShell, arguments: ["-lc", "command -v gh"],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environment: nil) {
            let path = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        throw PullRequestCheckoutError.ghNotAvailable
    }
}
