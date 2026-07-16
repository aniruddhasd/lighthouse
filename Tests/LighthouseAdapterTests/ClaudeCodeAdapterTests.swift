import Foundation
import Testing
import LighthouseGit
import LighthouseTaskEngine
@testable import LighthouseAdapter

@Suite("ClaudeCodeAdapter plans and payload mapping")
struct ClaudeCodeAdapterTests {
    private let adapter = ClaudeCodeAdapter()

    private func spec(
        primary: String = "/tmp/wt/primary repo",
        additional: [String] = []
    ) -> SessionSpec {
        SessionSpec(
            primaryWorktree: URL(fileURLWithPath: primary, isDirectory: true),
            additionalWorktrees: additional.map { URL(fileURLWithPath: $0, isDirectory: true) },
            loginShell: "/bin/zsh")
    }

    // MARK: Payload mapping — broken payloads first

    @Test func garbageAndNonObjectPayloadsMapToNil() {
        #expect(adapter.attentionSignal(fromPayload: Data("not json".utf8)) == nil)
        #expect(adapter.attentionSignal(fromPayload: Data()) == nil)
        #expect(adapter.attentionSignal(fromPayload: Data("[1,2,3]".utf8)) == nil)
        #expect(adapter.attentionSignal(fromPayload: Data(#"{"cwd": "/x"}"#.utf8)) == nil) // no session_id
        #expect(adapter.attentionSignal(fromPayload: Data(#"{"session_id": "s"}"#.utf8)) == nil) // no event name
    }

    @Test func hostileFieldContentIsJustData() {
        // Shell metacharacters in every string field: they decode to a
        // signal (or nil) and are never evaluated anywhere.
        let payload = #"{"session_id": "$(rm -rf /); `evil`", "hook_event_name": "Stop", "cwd": "; reboot"}"#
        let signal = adapter.attentionSignal(fromPayload: Data(payload.utf8))
        #expect(signal == AgentAttentionSignal(
            sessionRef: "$(rm -rf /); `evil`", event: .agentStopped))
    }

    @Test func stopPayloadSurfacesTranscriptExtras() {
        // A real Stop payload (contract doc): last_assistant_message +
        // transcript_path ride through as optional signal fields.
        let payload = #"""
        {"session_id":"s1","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done <b>x</b>","transcript_path":"/p/s1.jsonl"}
        """#
        let signal = adapter.attentionSignal(fromPayload: Data(payload.utf8))
        #expect(signal == AgentAttentionSignal(
            sessionRef: "s1", event: .agentStopped,
            lastAssistantMessage: "Done <b>x</b>", transcriptPath: "/p/s1.jsonl"))
    }

    @Test func extrasAreOptionalAndBackwardCompatible() {
        // UserPromptSubmit carries transcript_path but no last_assistant_message.
        let payload = #"{"session_id":"s2","hook_event_name":"UserPromptSubmit","transcript_path":"/p/s2.jsonl"}"#
        let signal = adapter.attentionSignal(fromPayload: Data(payload.utf8))
        #expect(signal?.lastAssistantMessage == nil)
        #expect(signal?.transcriptPath == "/p/s2.jsonl")
        // A payload with neither still decodes (fields nil).
        let bare = adapter.attentionSignal(
            fromPayload: Data(#"{"session_id":"s3","hook_event_name":"Stop"}"#.utf8))
        #expect(bare == AgentAttentionSignal(sessionRef: "s3", event: .agentStopped))
    }

    @Test func unknownEventsAndNotificationTypesMapToNilEvent() {
        #expect(ClaudeCodeAdapter.event(forHook: "PreToolUse", notificationType: nil) == nil)
        #expect(ClaudeCodeAdapter.event(forHook: "SomeFutureEvent", notificationType: nil) == nil)
        #expect(ClaudeCodeAdapter.event(forHook: "Notification", notificationType: "auth_success") == nil)
        #expect(ClaudeCodeAdapter.event(forHook: "Notification", notificationType: "elicitation_dialog") == nil)
        #expect(ClaudeCodeAdapter.event(forHook: "Notification", notificationType: nil) == nil)
    }

    /// The full verified mapping (docs/claude-code-contract.md).
    @Test(arguments: [
        ("UserPromptSubmit", nil, AttentionEvent.agentWorking),
        ("Stop", nil, .agentStopped),
        ("StopFailure", nil, .agentNeedsInput),
        ("SessionEnd", nil, .sessionDied),
        ("Notification", "permission_prompt", .agentNeedsInput),
        ("Notification", "idle_prompt", .agentNeedsInput),
        ("Notification", "agent_needs_input", .agentNeedsInput),
        ("Notification", "agent_completed", .agentStopped),
    ] as [(String, String?, AttentionEvent)])
    func verifiedEventMapping(hook: String, notificationType: String?, expected: AttentionEvent) {
        #expect(ClaudeCodeAdapter.event(forHook: hook, notificationType: notificationType) == expected)
    }

    @Test func realCapturedPayloadShapeDecodes() {
        // Field shape per the contract doc's common fields.
        let payload = """
        {"session_id":"7c2f0000-1111-2222-3333-444455556666",\
        "transcript_path":"/Users/u/.claude/projects/x/transcript.jsonl",\
        "cwd":"/private/tmp/fixture","permission_mode":"default",\
        "hook_event_name":"Notification","notification_type":"permission_prompt",\
        "message":"Permission required: Run Bash command?","tool_name":"Bash",\
        "tool_input":{"command":"npm test"},"unknown_future_field":{"nested":true}}
        """
        let signal = adapter.attentionSignal(fromPayload: Data(payload.utf8))
        // transcript_path now rides through (Phase 4); this Notification has no
        // last_assistant_message.
        #expect(signal == AgentAttentionSignal(
            sessionRef: "7c2f0000-1111-2222-3333-444455556666", event: .agentNeedsInput,
            lastAssistantMessage: nil,
            transcriptPath: "/Users/u/.claude/projects/x/transcript.jsonl"))
    }

    // MARK: Launch plans

    @Test func launchPlanRunsPersistentInteractiveLoginShell() throws {
        let plan = try adapter.launchPlan(for: spec())
        // Persistent shell: -l -i and NO -c/exec (2026-07-13). The claude
        // command is typed in, so Claude's exit returns the user's prompt.
        #expect(plan.executable == "/bin/zsh")
        #expect(plan.arguments == ["-l", "-i"])
        #expect(plan.workingDirectory.path == "/tmp/wt/primary repo")
        #expect(plan.environment.isEmpty)
        let command = try #require(plan.typedCommand)
        #expect(!command.contains("exec"))
        #expect(command.hasPrefix("'claude'") || command.hasPrefix("claude"))
    }

    @Test func launchPlanPreassignsSessionIdAsSessionRef() throws {
        let plan = try adapter.launchPlan(for: spec())
        let command = try #require(plan.typedCommand)
        #expect(UUID(uuidString: plan.sessionRef) != nil)
        #expect(command.contains("--session-id"))
        #expect(command.contains(plan.sessionRef))
        let second = try adapter.launchPlan(for: spec())
        #expect(second.sessionRef != plan.sessionRef)
    }

    @Test func resumePlanUsesStoredSessionRef() throws {
        let ref = "0e984725-c51c-4bf4-9960-e1c80e27aba0"
        let plan = try adapter.resumePlan(for: spec(), sessionRef: ref)
        let command = try #require(plan.typedCommand)
        #expect(command.contains("--resume"))
        #expect(command.contains(ref))
        #expect(plan.sessionRef == ref)
        #expect(!command.contains("--session-id"))
    }

    @Test func additionalWorktreesWithSpacesBecomeQuotedAddDirs() async throws {
        let plan = try adapter.launchPlan(for: spec(
            primary: "/tmp/wt/repo one",
            additional: ["/tmp/wt/repo two", "/tmp/wt/repo three (copy)"]))
        let command = try #require(plan.typedCommand)
        // Prove word boundaries with a real shell: the typed command, with
        // `claude` swapped for printf, must parse into exact words.
        let probe = command.replacingOccurrences(of: "'claude'", with: "printf '[%s]'")
        let result = try await ProcessRunner.run(
            executable: "/bin/zsh", arguments: ["-c", probe],
            workingDirectory: FileManager.default.temporaryDirectory)
        let words = String(decoding: result.stdout, as: UTF8.self)
        #expect(words.contains("[--add-dir][/tmp/wt/repo two][--add-dir][/tmp/wt/repo three (copy)]"))
    }

    @Test func hostileWorktreePathsCannotEscapeTheTypedCommand() async throws {
        let evil = "/tmp/x'; touch /tmp/lighthouse-pwned; '"
        let plan = try adapter.launchPlan(for: spec(additional: [evil]))
        let command = try #require(plan.typedCommand)
        let probe = command.replacingOccurrences(of: "'claude'", with: "printf '[%s]'")
        let result = try await ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", probe],
            workingDirectory: FileManager.default.temporaryDirectory)
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("[\(evil)]"))
        #expect(!FileManager.default.fileExists(atPath: "/tmp/lighthouse-pwned"))
    }

    @Test func hostileTaskNameInTypedCommandCannotBreakOut() async throws {
        // The task name flows into `-n <name>`; a hostile name must stay one
        // word (composed by ShellQuoter).
        let evil = "task$(touch /tmp/lighthouse-name-pwned)`id`; rm -rf /"
        let plan = try adapter.launchPlan(for: SessionSpec(
            primaryWorktree: URL(fileURLWithPath: "/tmp/wt"),
            loginShell: "/bin/zsh", displayName: evil))
        let command = try #require(plan.typedCommand)
        let probe = command.replacingOccurrences(of: "'claude'", with: "printf '[%s]'")
        let result = try await ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", probe],
            workingDirectory: FileManager.default.temporaryDirectory)
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("[\(evil)]"))
        #expect(!FileManager.default.fileExists(atPath: "/tmp/lighthouse-name-pwned"))
    }
}
