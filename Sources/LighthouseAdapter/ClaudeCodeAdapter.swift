import Foundation
import LighthouseGit
import LighthouseTaskEngine

/// The v1 (and only) AgentAdapter. Every fact this file encodes about the
/// Claude Code CLI is verified in docs/claude-code-contract.md (CLI 2.1.205,
/// 2026-07-09) — update that file when re-verifying against a newer CLI.
public struct ClaudeCodeAdapter: AgentAdapter {
    public let kind = "claude-code"

    /// Command name resolved by the login shell (PATH, aliases, functions).
    private let claudeCommand: String

    public init(claudeCommand: String = "claude") {
        self.claudeCommand = claudeCommand
    }

    // MARK: - Launch plans

    public func launchPlan(for spec: SessionSpec) throws -> LaunchPlan {
        // --session-id pre-assigns the session UUID, making sessionRef
        // deterministic at launch instead of discovered afterwards.
        let sessionId = UUID().uuidString.lowercased()
        var argv = [claudeCommand, "--session-id", sessionId]
        argv += Self.nameArguments(spec.displayName)
        argv += Self.addDirArguments(spec.additionalWorktrees)
        return plan(argv: argv, spec: spec, sessionRef: sessionId)
    }

    public func resumePlan(for spec: SessionSpec, sessionRef: String) throws -> LaunchPlan {
        var argv = [claudeCommand, "--resume", sessionRef]
        argv += Self.nameArguments(spec.displayName)
        argv += Self.addDirArguments(spec.additionalWorktrees)
        return plan(argv: argv, spec: spec, sessionRef: sessionRef)
    }

    /// `-n <name>` labels the session in Claude Code's own UI.
    private static func nameArguments(_ displayName: String?) -> [String] {
        displayName.map { ["-n", $0] } ?? []
    }

    private static func addDirArguments(_ dirs: [URL]) -> [String] {
        // --add-dir is variadic, but one flag per directory is unambiguous
        // and order-preserving.
        dirs.flatMap { ["--add-dir", $0.path] }
    }

    /// The session runs inside a PERSISTENT interactive login shell
    /// (`$SHELL -l -i`, no `-c`/`exec`): the claude command is TYPED into that
    /// shell (`typedCommand`), so Claude's exit drops the user back to their
    /// prompt in the worktree instead of killing the pty (2026-07-13 fix).
    /// Interactive+login is required for this user's per-folder account
    /// selector, a `.zshrc` function that only loads for interactive shells
    /// (verified 2026-07-09, see docs/claude-code-contract.md).
    private func plan(argv: [String], spec: SessionSpec, sessionRef: String) -> LaunchPlan {
        LaunchPlan(
            executable: spec.loginShell,
            arguments: ["-l", "-i"],
            environment: [:],
            workingDirectory: spec.primaryWorktree,
            sessionRef: sessionRef,
            typedCommand: ShellQuoter.command(argv))
    }
}
