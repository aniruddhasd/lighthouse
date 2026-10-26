import Foundation
import LighthouseAppCore
import LighthouseTaskEngine

/// A turn the supervisor has not yet looked at.
public struct PendingTurn: Equatable, Sendable {
    public let taskId: UUID
    public let taskName: String
    public let endedAt: Date
    /// `stop` or `stop_failure`.
    public let outcome: String
}

public enum SkipReason: Equatable, Sendable {
    case disabled
    case halted(String)
    case invalidSettings([String])
    case noInstructions
    case nothingNew
    case debouncing(until: Date)
    case hourlyCap(Int)
    case dailyCap(spent: Double, cap: Double)
    case runInFlight
    case misconfigured(String)
    case snapshotUnavailable(String)
}

public enum WakeDecision: Equatable, Sendable {
    case wake([PendingTurn])
    case skip(SkipReason)
}

/// Decides whether the supervisor should run now, and for which turns. Pure: every
/// input is a parameter. Checks run in a fixed order so a skip always names the first
/// thing in the way (docs/orchestrator-design.md §14).
public enum WakePolicy {
    public static func decide(
        trigger: WakeTrigger, settings: SupervisorSettings, state: SupervisorState,
        tasks: [TaskRecord], events: [LoggedHookEvent], now: Date, calendar: Calendar = .current
    ) -> WakeDecision {
        guard settings.enabled else { return .skip(.disabled) }
        if let halt = state.haltReason { return .skip(.halted(halt)) }
        let problems = settings.problems
        if !problems.isEmpty { return .skip(.invalidSettings(problems)) }
        if settings.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .skip(.noInstructions)
        }

        let turns = pendingTurns(trigger: trigger, state: state, tasks: tasks, events: events)
        if turns.isEmpty { return .skip(.nothingNew) }

        let recent = state.runs.filter { $0.startedAt > now.addingTimeInterval(-3_600) }
        if recent.count >= settings.maxWakesPerHour { return .skip(.hourlyCap(recent.count)) }
        let dayStart = calendar.startOfDay(for: now)
        let spent = state.runs.filter { $0.startedAt >= dayStart }.reduce(0) { $0 + $1.costUSD }
        if spent >= settings.maxDailySpendUSD {
            return .skip(.dailyCap(spent: spent, cap: settings.maxDailySpendUSD))
        }

        // Let a burst of turn ends settle so one run sees them all. A manual run is the
        // user asking now.
        if trigger == .automatic, let newest = turns.map(\.endedAt).max() {
            let ready = newest.addingTimeInterval(settings.debounceSeconds)
            if ready > now { return .skip(.debouncing(until: ready)) }
        }
        return .wake(turns)
    }

    /// The latest turn of each supervised task, if it is still the end of the story
    /// (no later material primary event) and not yet considered. A manual run ignores
    /// "already considered" and "gave up": the user asked for a look now.
    static func pendingTurns(
        trigger: WakeTrigger, state: SupervisorState, tasks: [TaskRecord], events: [LoggedHookEvent]
    ) -> [PendingTurn] {
        if trigger == .automatic && state.since == nil { return [] } // fail closed
        var out: [PendingTurn] = []
        for task in tasks where task.supervised {
            let mine = events.filter { $0.taskId == task.id }
            guard let endIndex = mine.lastIndex(where: TurnOrdering.isTurnEnd) else { continue }
            if mine[(endIndex + 1)...].contains(where: TurnOrdering.isMaterial) { continue }
            let end = mine[endIndex].event
            if trigger == .automatic {
                let floor = state.watermarks[task.id.uuidString] ?? state.since ?? .distantFuture
                // Persisted times keep whole seconds, so compare whole seconds.
                guard whole(end.receivedAt) > whole(floor) else { continue }
                if let attempt = state.attempts[task.id.uuidString],
                   whole(attempt.turn) == whole(end.receivedAt),
                   attempt.count >= SupervisorState.maxAttemptsPerTurn { continue }
            }
            out.append(PendingTurn(
                taskId: task.id, taskName: task.name, endedAt: end.receivedAt,
                outcome: end.eventName == "StopFailure" ? "stop_failure" : "stop"))
        }
        return out.sorted { $0.endedAt < $1.endedAt }
    }

    /// The halt message once `threshold` consecutive runs have failed, else `nil`.
    public static func haltReason(afterRuns runs: [RunRecord], threshold: Int) -> String? {
        let trailing = runs.reversed().prefix { !$0.ok }
        guard trailing.count >= threshold else { return nil }
        return "\(trailing.count) supervisor runs in a row failed; the last said: \(trailing.first?.note ?? "unknown")"
    }

    private static func whole(_ d: Date) -> Int { Int(d.timeIntervalSince1970) }
}
