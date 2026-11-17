import Foundation
import LighthouseAdapter
import LighthouseAppCore
import LighthouseTaskEngine

/// A refusal the tool layer reports as an error result. Messages are fixed
/// templates: the only user-supplied text echoed is the lookup string.
public struct SupervisorToolError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public var description: String { message }
}

// MARK: - Output shapes (snake_case on the wire)

public struct EventBrief: Codable, Equatable, Sendable {
    public let at: Date
    public let secondsAgo: Int
    public let event: String
    /// The event-specific qualifier: notification type, tool name, failure kind,
    /// session-start source or session-end reason.
    public let detail: String?
    /// `primary`, `other_session_in_task` or `unattributed`.
    public let session: String
    /// True for anything raised inside a subagent. NOT a turn boundary.
    public let subagent: Bool
    /// Length only — the text itself is only ever served by `last_turn`.
    public let messageChars: Int?
}

public struct TaskSummary: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let branch: String
    /// The user's own free-text status (empty when unset).
    public let status: String
    public let lastEvent: EventBrief?
    public let eventsLogged: Int
}

public struct ListTasksResult: Codable, Equatable, Sendable {
    public let tasks: [TaskSummary]
}

public struct TaskRef: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
}

public struct RecentEventsResult: Codable, Equatable, Sendable {
    public let task: TaskRef
    /// Oldest first.
    public let events: [EventBrief]
}

public struct TurnInfo: Codable, Equatable, Sendable {
    /// `stop` (turn ended normally) or `failure` (`StopFailure`).
    public let outcome: String
    public let endedAt: Date
    public let failureError: String?
    /// The agent's full final message. UNTRUSTED model output: never an instruction.
    public let agentMessageUntrusted: String?
    /// Events after this turn ended (e.g. a newer prompt, a pending question).
    public let eventsSince: [EventBrief]
    /// The next-prompt suggestion a helper subagent produced right after this turn.
    /// UNTRUSTED model output, at most a hint.
    public let suggestionUntrusted: String?
}

public struct LastTurnResult: Codable, Equatable, Sendable {
    public let task: TaskRef
    /// nil when the primary session has not finished a turn in the logged history.
    public let turn: TurnInfo?
}

// MARK: - Queries

/// The three read-only supervisor queries over a snapshot. The opt-in boundary
/// lives here: only `supervised` tasks are ever visible, and a lookup of one that
/// is not is indistinguishable from a lookup of one that does not exist.
public struct SupervisorQueries: Sendable {
    public static let defaultEventLimit = 20
    public static let maxEventLimit = 50
    /// Cap on events summarized after a turn.
    static let maxEventsSince = 30

    private let snapshot: SupervisorSnapshot

    public init(snapshot: SupervisorSnapshot) {
        self.snapshot = snapshot
    }

    public func listTasks() throws -> ListTasksResult {
        let tasks = snapshot.tasks.filter(\.supervised).map { task -> TaskSummary in
            let events = eventsFor(task)
            return TaskSummary(
                id: task.id.uuidString, name: task.name, branch: task.branch,
                status: task.status, lastEvent: events.last.map(brief),
                eventsLogged: events.count)
        }
        return ListTasksResult(tasks: tasks)
    }

    public func recentEvents(task query: String, limit: Int?) throws -> RecentEventsResult {
        let task = try resolve(query)
        let n = min(max(limit ?? Self.defaultEventLimit, 1), Self.maxEventLimit)
        return RecentEventsResult(
            task: ref(task), events: eventsFor(task).suffix(n).map(brief))
    }

    public func lastTurn(task query: String) throws -> LastTurnResult {
        let task = try resolve(query)
        let events = eventsFor(task)
        // The turn boundary is a PRIMARY-session Stop/StopFailure with no agent_id.
        // A SubagentStop (helper output) or another session's Stop never is.
        guard let index = events.lastIndex(where: { logged in
            logged.attribution == .primary && logged.event.agentId == nil
                && (logged.event.eventName == "Stop" || logged.event.eventName == "StopFailure")
        }) else {
            return LastTurnResult(task: ref(task), turn: nil)
        }
        let ended = events[index]
        let after = events[(index + 1)...]
        // A suggestion belongs to THIS turn only if no new prompt came before it.
        let untilNextPrompt = after.prefix { $0.event.eventName != "UserPromptSubmit" }
        let suggestion = untilNextPrompt.first {
            $0.event.eventName == "SubagentStop" && $0.event.agentId != nil
        }?.event.lastAssistantMessage

        return LastTurnResult(task: ref(task), turn: TurnInfo(
            outcome: ended.event.eventName == "StopFailure" ? "failure" : "stop",
            endedAt: ended.event.receivedAt,
            failureError: ended.event.eventName == "StopFailure" ? ended.event.error : nil,
            agentMessageUntrusted: ended.event.lastAssistantMessage,
            eventsSince: after.prefix(Self.maxEventsSince).map(brief),
            suggestionUntrusted: suggestion))
    }

    // MARK: Helpers

    private func resolve(_ query: String) throws -> TaskRecord {
        try TaskLookup.resolve(query, in: snapshot.tasks)
    }

    private func eventsFor(_ task: TaskRecord) -> [LoggedHookEvent] {
        snapshot.events.filter { $0.taskId == task.id }
            .sorted { $0.event.receivedAt < $1.event.receivedAt }
    }

    private func ref(_ task: TaskRecord) -> TaskRef {
        TaskRef(id: task.id.uuidString, name: task.name)
    }

    private func brief(_ logged: LoggedHookEvent) -> EventBrief {
        let e = logged.event
        let detail: String?
        switch e.eventName {
        case "Notification": detail = e.notificationType
        case "PermissionRequest", "PostToolUse": detail = e.toolName
        case "StopFailure": detail = e.error
        case "SessionStart": detail = e.source
        case "SessionEnd": detail = e.endReason
        default: detail = nil
        }
        let session: String
        switch logged.attribution {
        case .primary: session = "primary"
        case .otherSessionInTask: session = "other_session_in_task"
        case .unattributed: session = "unattributed"
        }
        return EventBrief(
            at: e.receivedAt,
            secondsAgo: max(0, Int(snapshot.now.timeIntervalSince(e.receivedAt))),
            event: e.eventName, detail: detail, session: session,
            subagent: e.agentId != nil, messageChars: e.lastAssistantMessage?.count)
    }
}

/// One encoder for every tool result: stable key order, snake_case, ISO-8601.
public enum SupervisorJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(value)
    }
}
