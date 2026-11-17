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
    /// An automatic trigger while automatic runs are off (a manual run is unaffected).
    case automaticOff
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

extension SkipReason {
    /// Plain words for the panel and run log.
    public var explanation: String {
        switch self {
        case .disabled: return "The supervisor is off."
        case .automaticOff: return "Automatic runs are off; use Run now, or switch them on."
        case .halted(let why): return "Halted: \(why)"
        case .invalidSettings(let problems): return "Fix the settings first: \(problems.joined(separator: " "))"
        case .noInstructions: return "Write standing instructions first."
        case .nothingNew:
            return "Nothing to look at: no supervised task has a finished turn that is still current."
        case .debouncing: return "Waiting for a burst of finished turns to settle."
        case .hourlyCap(let n): return "Hourly limit reached (\(n) runs in the last hour)."
        case .dailyCap(let spent, let cap):
            return String(format: "Daily spend limit reached ($%.2f of $%.2f).", spent, cap)
        case .runInFlight: return "A run is already running."
        case .misconfigured(let why): return why
        case .snapshotUnavailable(let why): return "The app's state could not be read: \(why)"
        }
    }
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
        if trigger == .automatic && !settings.automatic { return .skip(.automaticOff) }
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
        let spent = state.spentToday(now: now, calendar: calendar)
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
