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
        #expect(signal == AgentAttentionSignal(
            sessionRef: "7c2f0000-1111-2222-3333-444455556666", event: .agentNeedsInput))
    }

    // MARK: Launch plans

    @Test func launchPlanRunsThroughInteractiveLoginShell() throws {
        let plan = try adapter.launchPlan(for: spec())
        #expect(plan.executable == "/bin/zsh")
        #expect(plan.arguments.count == 4)
        #expect(Array(plan.arguments.prefix(3)) == ["-l", "-i", "-c"])
        #expect(plan.arguments[3].hasPrefix("exec "))
        #expect(plan.workingDirectory.path == "/tmp/wt/primary repo")
        #expect(plan.environment.isEmpty)
    }

    @Test func launchPlanPreassignsSessionIdAsSessionRef() throws {
        let plan = try adapter.launchPlan(for: spec())
        // sessionRef is a UUID and appears in the command via --session-id.
        #expect(UUID(uuidString: plan.sessionRef) != nil)
        #expect(plan.arguments[3].contains("--session-id"))
        #expect(plan.arguments[3].contains(plan.sessionRef))
        // Two launches never share a session.
        let second = try adapter.launchPlan(for: spec())
        #expect(second.sessionRef != plan.sessionRef)
    }

    @Test func resumePlanUsesStoredSessionRef() throws {
        let ref = "0e984725-c51c-4bf4-9960-e1c80e27aba0"
        let plan = try adapter.resumePlan(for: spec(), sessionRef: ref)
        #expect(plan.arguments[3].contains("--resume"))
        #expect(plan.arguments[3].contains(ref))
        #expect(plan.sessionRef == ref)
        #expect(!plan.arguments[3].contains("--session-id"))
    }

    @Test func additionalWorktreesWithSpacesBecomeQuotedAddDirs() async throws {
        let plan = try adapter.launchPlan(for: spec(
            primary: "/tmp/wt/repo one",
            additional: ["/tmp/wt/repo two", "/tmp/wt/repo three (copy)"]))
        let command = plan.arguments[3]
        // Prove word boundaries with a real shell: replace `exec claude`
        // with printf and let the shell parse the exact command string.
        // Probe with a plain (non-login) shell: quoting semantics are
        // identical, and this avoids sourcing the developer's real rc files.
        let probe = command.replacingOccurrences(
            of: "exec 'claude'", with: "printf '[%s]'")
        let result = try await ProcessRunner.run(
            executable: "/bin/zsh", arguments: ["-c", probe],
            workingDirectory: FileManager.default.temporaryDirectory)
        let words = String(decoding: result.stdout, as: UTF8.self)
        #expect(words.contains("[--add-dir][/tmp/wt/repo two][--add-dir][/tmp/wt/repo three (copy)]"))
    }

    @Test func hostileWorktreePathsCannotEscapeTheCommand() async throws {
        let evil = "/tmp/x'; touch /tmp/lighthouse-pwned; '"
        let plan = try adapter.launchPlan(for: spec(additional: [evil]))
        let probe = plan.arguments[3].replacingOccurrences(
            of: "exec 'claude'", with: "printf '[%s]'")
        let result = try await ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", probe],
            workingDirectory: FileManager.default.temporaryDirectory)
        // The path arrives as ONE word, verbatim; nothing was executed.
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("[\(evil)]"))
        #expect(!FileManager.default.fileExists(atPath: "/tmp/lighthouse-pwned"))
    }
}
