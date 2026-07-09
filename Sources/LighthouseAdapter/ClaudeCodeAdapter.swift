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
    private let installer: HookInstaller

    public init(claudeCommand: String = "claude", git: GitClient = GitClient()) {
        self.claudeCommand = claudeCommand
        self.installer = HookInstaller(git: git)
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

    /// The session must run through the user's login+interactive shell: this
    /// user selects between two Claude accounts with a shell FUNCTION
    /// (`.zshrc`) that sets CLAUDE_CONFIG_DIR per folder, and `.zshrc` only
    /// loads for interactive shells — `-l -c` alone would silently pick the
    /// wrong account (verified 2026-07-09, see docs/claude-code-contract.md).
    /// The plan targets a pty (step 4), where an interactive shell is normal.
    /// `exec` replaces the shell so the pty owns claude directly.
    private func plan(argv: [String], spec: SessionSpec, sessionRef: String) -> LaunchPlan {
        let command = "exec " + ShellQuoter.command(argv)
        return LaunchPlan(
            executable: spec.loginShell,
            arguments: ["-l", "-i", "-c", command],
            environment: [:],
            workingDirectory: spec.primaryWorktree,
            sessionRef: sessionRef)
    }

    // MARK: - Attention wiring

    public func prepareWorkspaceAttention(in workspace: URL, socketPath: URL) async throws {
        try await installer.install(in: workspace, socketPath: socketPath)
    }

    public func removeWorkspaceAttention(from workspace: URL) async throws {
        try await installer.uninstall(from: workspace)
    }

    // MARK: - Payload translation

    /// Hook payload fields per docs/claude-code-contract.md. Unknown fields
    /// are ignored by decoding; unknown events map to a signal with nil
    /// event so the listener can count them without acting.
    struct HookPayload: Decodable {
        let session_id: String
        let hook_event_name: String
        let notification_type: String?
    }

    public func attentionSignal(fromPayload payload: Data) -> AgentAttentionSignal? {
        guard let decoded = try? JSONDecoder().decode(HookPayload.self, from: payload) else {
            return nil
        }
        return AgentAttentionSignal(
            sessionRef: decoded.session_id,
            event: Self.event(forHook: decoded.hook_event_name, notificationType: decoded.notification_type))
    }

    /// Event mapping — the minimal hook set covering working/needs-input/done
    /// (contract doc, "Hook events"). Pure and separately testable.
    static func event(forHook name: String, notificationType: String?) -> AttentionEvent? {
        switch name {
        case "UserPromptSubmit":
            return .agentWorking
        case "Stop":
            return .agentStopped
        case "StopFailure":
            // An errored turn needs a human, not a "done" badge.
            return .agentNeedsInput
        case "SessionEnd":
            return .sessionDied
        case "Notification":
            switch notificationType {
            case "permission_prompt", "idle_prompt", "agent_needs_input":
                return .agentNeedsInput
            case "agent_completed":
                return .agentStopped
            default:
                return nil // auth_success, elicitation_*, future types
            }
        default:
            return nil
        }
    }
}
