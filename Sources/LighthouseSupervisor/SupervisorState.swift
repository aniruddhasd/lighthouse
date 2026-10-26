import Foundation

public enum WakeTrigger: String, Codable, Sendable { case automatic, manual }

/// One supervisor run, as recorded. Cost is never "free by omission": when a run
/// reports none, the per-run budget is recorded instead (the most it could have cost).
public struct RunRecord: Codable, Sendable, Equatable, Identifiable {
    public static let maxNoteChars = 500
    public let id: UUID
    public let startedAt: Date
    public let trigger: WakeTrigger
    public let taskNames: [String]
    public let ok: Bool
    public let costUSD: Double
    /// The model's own closing note (truncated) or the failure reason. Not an instruction.
    public let note: String

    public init(
        id: UUID = UUID(), startedAt: Date, trigger: WakeTrigger, taskNames: [String],
        ok: Bool, costUSD: Double, note: String
    ) {
        self.id = id
        self.startedAt = startedAt
        self.trigger = trigger
        self.taskNames = taskNames
        self.ok = ok
        self.costUSD = costUSD
        self.note = SupervisorState.flatten(note, limit: Self.maxNoteChars)
    }
}

/// A turn that failed to be handled: how many times we have tried that exact turn.
public struct TurnAttempt: Codable, Sendable, Equatable {
    public var turn: Date
    public var count: Int
}

/// What the runner remembers between wakes. Persisted, so an app restart cannot
/// re-wake on old events or forget what was spent. Keys are task UUID strings.
public struct SupervisorState: Codable, Sendable, Equatable {
    public static let maxRuns = 200
    public static let maxAttemptsPerTurn = 2

    /// Start of the current enabled period. Turns that ended before it are history,
    /// never woken for. `nil` while disabled.
    public var since: Date?
    /// The end time of the last turn a completed run considered, per task.
    public var watermarks: [String: Date] = [:]
    public var attempts: [String: TurnAttempt] = [:]
    /// Oldest first.
    public var runs: [RunRecord] = []
    /// Why the supervisor stopped itself; only the user clears it.
    public var haltReason: String?

    public init() {}

    public mutating func append(_ run: RunRecord) {
        runs.append(run)
        if runs.count > Self.maxRuns { runs.removeFirst(runs.count - Self.maxRuns) }
    }

    /// One line, no control characters, bounded — for anything stored from model output.
    static func flatten(_ text: String, limit: Int) -> String {
        let cleaned = String(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : Character($0)
        })
        let collapsed = cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(collapsed.prefix(limit))
    }
}
