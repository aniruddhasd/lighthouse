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
