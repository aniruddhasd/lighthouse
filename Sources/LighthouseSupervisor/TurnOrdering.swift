import Foundation
import LighthouseAppCore

/// The one definition of which hook events end a turn and which ones move a session
/// on, shared by the delivery gate (is this advice still fresh?) and the wake policy
/// (is there a turn to look at?). Subagent events, other sessions and notifications
/// never count: the next-prompt helper always trails a `Stop` (hook-observations.md).
enum TurnOrdering {
    /// A primary-session event that ends a turn: `Stop` or `StopFailure`, no `agent_id`.
    static func isTurnEnd(_ logged: LoggedHookEvent) -> Bool {
        logged.attribution == .primary && logged.event.agentId == nil
            && (logged.event.eventName == "Stop" || logged.event.eventName == "StopFailure")
    }

    /// Any primary-session event with no `agent_id` other than `Notification`: after a
    /// turn end, one of these means the world has moved on.
    static func isMaterial(_ logged: LoggedHookEvent) -> Bool {
        logged.attribution == .primary && logged.event.agentId == nil
            && logged.event.eventName != "Notification"
    }
}

/// Whether a turn an agent's advice was based on is still the end of that task's story.
/// Order-based, not time-based: find the turn-ending event `basedOn` names (matched by
/// whole second — the stored time has no fraction), then ask whether any MATERIAL
/// primary-session event came after it. `events` are ONE task's, in arrival order.
enum TurnFreshness {
    case fresh
    /// The log holds no turn that `basedOn` names. "Unknown" is not "stale".
    case unknownTurn
    /// Proven overtaken, with the reason to show.
    case stale(String)

    static func assess(events: [LoggedHookEvent], basedOn: Date?) -> TurnFreshness {
        guard let basedOn else { return .unknownTurn }
        let second = Int(basedOn.timeIntervalSince1970)
        guard let index = events.lastIndex(where: { logged in
            TurnOrdering.isTurnEnd(logged)
                && Int(logged.event.receivedAt.timeIntervalSince1970) == second
        }) else { return .unknownTurn }

        if let newer = events[(index + 1)...].first(where: TurnOrdering.isMaterial) {
            return .stale("Overtaken by a newer \(newer.event.eventName) event; the agent has moved on since this was proposed.")
        }
        return .fresh
    }
}

/// Whether a task's agent is sitting at an idle prompt, judged from its own events.
/// Fails closed: anything not known to be idle is busy.
enum TargetState {
    case idle
    case busy(String)

    static func assess(events: [LoggedHookEvent]) -> TargetState {
        guard let last = events.last(where: TurnOrdering.isMaterial) else {
            return .busy("nothing is known about that session yet.")
        }
        switch last.event.eventName {
        case "Stop", "StopFailure", "SessionStart": return .idle
        case "UserPromptSubmit", "PostToolUse": return .busy("the agent is working on a turn.")
        case "PermissionRequest": return .busy("it is waiting on a question (or was interrupted).")
        case "SessionEnd": return .busy("Claude is not running there (the session ended).")
        default: return .busy("its last event was \(last.event.eventName).")
        }
    }
}
