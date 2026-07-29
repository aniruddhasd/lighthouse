import Foundation
import LighthouseTaskEngine

/// Everything the pty layer needs to start an agent session. The adapter
/// BUILDS this; it never spawns the interactive session itself.
///
/// The pty runs a PERSISTENT interactive login shell (`executable` +
/// `arguments`), and the agent is launched by TYPING `typedCommand` into that
/// shell (2026-07-13). Rationale: `exec claude` replaced the shell, so when
/// Claude exited the pty died and the terminal became a corpse — the opposite
/// of a real terminal. With a persistent shell, Claude exits back to the
/// user's prompt in the worktree, with the same per-folder account env (the
/// `.zshrc` account selector applies to the interactive shell identically).
public struct LaunchPlan: Sendable, Equatable {
    /// Executable to spawn (for Claude Code: the user's login shell).
    public let executable: String
    /// Argument array for the executable — the persistent-shell flags
    /// (`-l -i`), NOT `-c <command>`. Never a shell string.
    public let arguments: [String]
    /// Extra environment merged over the inherited environment by the pty layer.
    public let environment: [String: String]
    public let workingDirectory: URL
    /// The session reference to persist on the task (deterministic at launch
    /// when the agent supports pre-assigned session IDs).
    public let sessionRef: String
    /// The command to TYPE into the shell after it starts (the pty layer adds
    /// the trailing newline). ShellQuoter-composed — every argument is one
    /// shell word, so task/session names never break out. nil for a plain
    /// shell tab.
    public let typedCommand: String?

    public init(
        executable: String, arguments: [String], environment: [String: String],
        workingDirectory: URL, sessionRef: String, typedCommand: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.sessionRef = sessionRef
        self.typedCommand = typedCommand
    }
}

/// What a new session should span: the task's primary worktree (cwd) and the
/// sibling worktrees the agent must also reach.
public struct SessionSpec: Sendable, Equatable {
    public let primaryWorktree: URL
    public let additionalWorktrees: [URL]
    /// The user's shell (e.g. "/bin/zsh"); prod passes SHELL from the environment.
    public let loginShell: String
    /// Human-readable session name (the task name), shown by the agent's own
    /// UI (Claude Code: `-n`, prompt box + /resume picker).
    public let displayName: String?

    public init(
        primaryWorktree: URL, additionalWorktrees: [URL] = [], loginShell: String,
        displayName: String? = nil
    ) {
        self.primaryWorktree = primaryWorktree
        self.additionalWorktrees = additionalWorktrees
        self.loginShell = loginShell
        self.displayName = displayName
    }
}

/// The seam between Lighthouse and any agent CLI (spec guardrail 3: app code
/// never calls agent CLIs raw). Shaped around capabilities, not Claude
/// specifics — this is one of the two future-public contracts (§4).
///
/// Attention/hook wiring was removed (2026-07-29): Lighthouse no longer infers
/// a task's status from agent hooks (they were untrustworthy) — status is now
/// user-set free text. The adapter's remaining job is purely to build the
/// command that launches or resumes a session, which is the one piece still
/// specific to the agent CLI.
public protocol AgentAdapter: Sendable {
    /// Stable identifier persisted as TaskRecord.adapterKind.
    var kind: String { get }

    /// Plan for a brand-new session. The returned plan's sessionRef is what
    /// the caller persists for later resume.
    func launchPlan(for spec: SessionSpec) throws -> LaunchPlan

    /// Plan that resumes a previously persisted sessionRef.
    func resumePlan(for spec: SessionSpec, sessionRef: String) throws -> LaunchPlan
}
