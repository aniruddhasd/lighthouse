import Foundation
import Testing
@testable import LighthouseAdapter

@Suite("ClaudeHookParser")
struct ClaudeHookParserTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func parse(_ json: String) -> HookEvent? {
        ClaudeHookParser.parse(Data(json.utf8), receivedAt: now)
    }

    // MARK: Broken input first

    @Test func nonJSONRejected() { #expect(parse("not json") == nil) }
    @Test func nonObjectRejected() { #expect(parse("[1,2]") == nil) }
    @Test func emptyBodyRejected() { #expect(parse("") == nil) }
    @Test func missingSessionIdRejected() {
        #expect(parse(#"{"hook_event_name":"Stop"}"#) == nil)
    }
    @Test func missingEventNameRejected() {
        #expect(parse(#"{"session_id":"s"}"#) == nil)
    }
    @Test func emptyRequiredFieldsRejected() {
        #expect(parse(#"{"session_id":"","hook_event_name":"Stop"}"#) == nil)
        #expect(parse(#"{"session_id":"s","hook_event_name":""}"#) == nil)
    }
    @Test func wrongTypedRequiredFieldsRejected() {
        #expect(parse(#"{"session_id":7,"hook_event_name":"Stop"}"#) == nil)
    }

    // MARK: Tolerance + extraction

    @Test func unknownFieldsIgnoredButKeysRecorded() throws {
        let e = try #require(parse(
            #"{"session_id":"s","hook_event_name":"Stop","stop_hook_active":false,"zzz":1}"#))
        #expect(e.payloadKeys == ["hook_event_name", "session_id", "stop_hook_active", "zzz"])
    }

    @Test func wrongTypedOptionalFieldsBecomeNil() throws {
        let e = try #require(parse(
            #"{"session_id":"s","hook_event_name":"Stop","cwd":5,"agent_id":false}"#))
        #expect(e.cwd == nil && e.agentId == nil)
    }

    @Test func stopCarriesMessageTruncatedToCap() throws {
        let long = String(repeating: "x", count: HookEvent.maxMessageChars + 50)
        let e = try #require(parse(
            "{\"session_id\":\"s\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"\(long)\"}"))
        #expect(e.lastAssistantMessage?.count == HookEvent.maxMessageChars)
    }

    @Test func endReasonPrefersReasonThenEndReason() throws {
        let a = try #require(parse(
            #"{"session_id":"s","hook_event_name":"SessionEnd","reason":"other","end_reason":"logout"}"#))
        #expect(a.endReason == "other")
        let b = try #require(parse(
            #"{"session_id":"s","hook_event_name":"SessionEnd","end_reason":"logout"}"#))
        #expect(b.endReason == "logout")
    }

    @Test func subagentAndNotificationFieldsExtracted() throws {
        let e = try #require(parse(
            #"{"session_id":"s","hook_event_name":"Notification","notification_type":"idle_prompt","agent_id":"a1","agent_type":"Explore"}"#))
        #expect(e.notificationType == "idle_prompt")
        #expect(e.agentId == "a1" && e.agentType == "Explore")
        #expect(e.receivedAt == now)
    }

    // MARK: Fields seen live (2026-10-22 observation)

    /// Helper subagents arrive with the key PRESENT but empty. Present-empty must
    /// stay distinguishable from absent (the card labels it, the supervisor must
    /// not treat it as a turn).
    @Test func emptyAgentTypeIsKeptAsEmptyStringNotNil() throws {
        let present = try #require(parse(
            #"{"session_id":"s","hook_event_name":"SubagentStop","agent_id":"a1","agent_type":""}"#))
        #expect(present.agentType == "")
        let absent = try #require(parse(#"{"session_id":"s","hook_event_name":"Stop"}"#))
        #expect(absent.agentType == nil)
    }

    @Test func emptyOtherOptionalStringsStillBecomeNil() throws {
        let e = try #require(parse(
            #"{"session_id":"s","hook_event_name":"Stop","cwd":"","agent_id":""}"#))
        #expect(e.cwd == nil && e.agentId == nil)
    }

    @Test func sessionStartSourceExtracted() throws {
        let e = try #require(parse(
            #"{"session_id":"s","hook_event_name":"SessionStart","source":"resume"}"#))
        #expect(e.source == "resume")
        #expect(try #require(parse(#"{"session_id":"s","hook_event_name":"Stop"}"#)).source == nil)
    }

    @Test func wrongTypedSourceBecomesNil() throws {
        let e = try #require(parse(
            #"{"session_id":"s","hook_event_name":"SessionStart","source":3}"#))
        #expect(e.source == nil)
    }

    // MARK: Failure + tool fields seen live (2026-10-22, second observation)

    @Test func stopFailureCarriesStructuredErrorAndMessage() throws {
        let e = try #require(parse(
            #"{"session_id":"s","hook_event_name":"StopFailure","error":"unknown","last_assistant_message":"API Error: Can't reach the API server"}"#))
        #expect(e.error == "unknown")
        #expect(e.lastAssistantMessage == "API Error: Can't reach the API server")
    }

    @Test func permissionRequestKeepsToolNameButNeverToolInput() throws {
        let e = try #require(parse(
            #"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"secret?"}]}}"#))
        #expect(e.toolName == "AskUserQuestion")
        // tool_input (commands/args/answers) is sensitive + untrusted: its KEY is
        // recorded for drift-spotting, its VALUE is never retained.
        #expect(e.payloadKeys.contains("tool_input"))
        let encoded = String(decoding: try JSONEncoder().encode(e), as: UTF8.self)
        #expect(!encoded.contains("secret?"))
    }

    @Test func toolResponseAndPromptValuesAreNeverRetained() throws {
        let e = try #require(parse(
            #"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","tool_response":"the-answers","prompt":"my private prompt"}"#))
        let encoded = String(decoding: try JSONEncoder().encode(e), as: UTF8.self)
        #expect(!encoded.contains("the-answers") && !encoded.contains("my private prompt"))
    }

    @Test func wrongTypedErrorAndToolNameBecomeNil() throws {
        let e = try #require(parse(
            #"{"session_id":"s","hook_event_name":"StopFailure","error":{"x":1},"tool_name":9}"#))
        #expect(e.error == nil && e.toolName == nil)
    }
}
