import Foundation

/// One Claude Code hook delivery, parsed and bounded. Phase 1a (observation
/// only, docs/orchestrator-design.md): every field is a fact the CLI sent, kept
/// verbatim — no interpretation (done/blocked/question) happens here.
///
/// All text is UNTRUSTED agent/repo content. It is stored and displayed inertly
/// and never executed, interpolated into a shell, or forwarded to another session.
public struct HookEvent: Sendable, Equatable, Codable {
    /// Cap on stored `lastAssistantMessage` characters (the listener already
    /// caps the whole body at 64 KiB; this bounds what the log retains).
    public static let maxMessageChars = 8_000

    public let receivedAt: Date
    /// `hook_event_name` — `Stop`, `Notification`, `SubagentStop`, …
    public let eventName: String
    public let sessionId: String
    /// Present on events raised inside a subagent (docs: `agent_id`).
    public let agentId: String?
    /// The subagent's type. Present-but-EMPTY (`""`) is meaningful and kept: the
    /// background helper subagents seen live (2026-10-22) send `agent_type: ""`.
    public let agentType: String?
    /// `SessionStart` only: why it started (docs: `startup`, `resume`, `clear`,
    /// `compact`, `fork`). Kept verbatim — unknown values pass through.
    public let source: String?
    /// `Notification` only: the notification type (`permission_prompt`, …).
    public let notificationType: String?
    /// `SessionEnd`: the end reason. The CLI has used `reason` while docs said
    /// `end_reason` — accept either, preferring `reason`.
    public let endReason: String?
    public let cwd: String?
    public let transcriptPath: String?
    /// `Stop` / `SubagentStop`: the agent's final message, truncated to
    /// `maxMessageChars`. nil when absent.
    public let lastAssistantMessage: String?
    /// Sorted top-level payload keys — lets the log reveal undocumented or
    /// newly-added fields without storing the whole payload.
    public let payloadKeys: [String]

    public init(
        receivedAt: Date, eventName: String, sessionId: String, agentId: String? = nil,
        agentType: String? = nil, source: String? = nil, notificationType: String? = nil, endReason: String? = nil,
        cwd: String? = nil, transcriptPath: String? = nil, lastAssistantMessage: String? = nil,
        payloadKeys: [String] = []
    ) {
        self.receivedAt = receivedAt
        self.eventName = eventName
        self.sessionId = sessionId
        self.agentId = agentId
        self.agentType = agentType
        self.source = source
        self.notificationType = notificationType
        self.endReason = endReason
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.lastAssistantMessage = lastAssistantMessage
        self.payloadKeys = payloadKeys
    }
}

/// Parses a raw hook stdin payload into a `HookEvent`. Total and non-throwing:
/// anything that is not a JSON object with a string `hook_event_name` and
/// `session_id` yields nil (the listener counts it as a drop). Unknown fields
/// are ignored; every other field is optional — decoders must tolerate CLI
/// drift (docs/claude-code-contract.md).
public enum ClaudeHookParser {
    public static func parse(_ data: Data, receivedAt: Date) -> HookEvent? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = object["hook_event_name"] as? String, !name.isEmpty,
              let sessionId = object["session_id"] as? String, !sessionId.isEmpty
        else { return nil }

        func string(_ key: String) -> String? {
            guard let value = object[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        /// Like `string`, but a present-empty value is preserved as "".
        func stringKeepingEmpty(_ key: String) -> String? { object[key] as? String }
        let message = string("last_assistant_message").map {
            String($0.prefix(HookEvent.maxMessageChars))
        }
        return HookEvent(
            receivedAt: receivedAt, eventName: name, sessionId: sessionId,
            agentId: string("agent_id"), agentType: stringKeepingEmpty("agent_type"), source: string("source"),
            notificationType: string("notification_type"),
            endReason: string("reason") ?? string("end_reason"),
            cwd: string("cwd"), transcriptPath: string("transcript_path"),
            lastAssistantMessage: message,
            payloadKeys: object.keys.sorted())
    }
}
