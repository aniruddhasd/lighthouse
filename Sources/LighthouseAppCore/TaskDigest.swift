import Foundation
import Observation
import LighthouseGit

/// Per-task derived metadata the redesign's cards / footer / Summary display.
/// Every field is independently optional and honest:
///
/// - `diffStat` is DETERMINISTIC (git). nil = **unknown** (renders blank);
///   `DiffStat.zero` = **known zero** (renders a real `0`). The two are never
///   conflated — a task with genuinely no changes shows `0`, a task whose diff
///   hasn't been computed shows nothing.
/// - `baked` is DETERMINISTIC (hook wall-clock timing).
/// - `model`, `context`, `action` are a best-effort projection of stochastic
///   model output — present when honestly derived, nil otherwise. `context`
///   (ctx%) is built ONLY when a genuine token source + known window exist
///   (see `TranscriptReader`); it is never fabricated.
///
/// Not persisted (re-derivable, partly stochastic — spec §7).
public struct TaskDigest: Sendable, Equatable {
    public var diffStat: DiffStat?
    public var baked: TimeInterval?
    public var model: String?
    public var context: ContextEstimate?
    /// The agent's last message (`Stop` hook `last_assistant_message`).
    /// UNTRUSTED content — consumers must render it inert (SwiftUI `Text`,
    /// which does not interpret markup) with a line limit.
    public var action: String?

    public init(
        diffStat: DiffStat? = nil, baked: TimeInterval? = nil,
        model: String? = nil, context: ContextEstimate? = nil, action: String? = nil
    ) {
        self.diffStat = diffStat
        self.baked = baked
        self.model = model
        self.context = context
        self.action = action
    }

    public static let empty = TaskDigest()
}

/// In-memory, re-derivable digest store keyed by task id, plus the per-task
/// baked-timing bookkeeping. `@Observable` so the SwiftUI cards/footer/Summary
/// re-render when a field lands; owned by the runtime, never persisted. The
/// cache holds no GitClient and does no I/O of its own — the runtime performs
/// the git/transcript reads and feeds results in — so this stays a pure,
/// unit-testable store.
@MainActor @Observable
public final class TaskDigestCache {
    /// The maximum stored `action` length. The hook already caps the payload;
    /// this bounds what a hostile `last_assistant_message` can retain in memory
    /// (rendering already truncates by line).
    public static let maxActionChars = 4000

    public private(set) var digests: [UUID: TaskDigest] = [:]
    /// When each task last transitioned to `agentWorking` (UserPromptSubmit),
    /// so a subsequent `agentStopped` (Stop) yields an exact turn duration.
    private var workStartedAt: [UUID: Date] = [:]

    public init() {}

    /// The digest for a task, or `.empty` (all-blank) if nothing derived yet.
    public func digest(for taskId: UUID) -> TaskDigest {
        digests[taskId] ?? .empty
    }

    /// Records the start of a turn (UserPromptSubmit / agentWorking). Only the
    /// most recent start is kept — baked measures the last turn.
    public func noteWorkStarted(taskId: UUID, at time: Date) {
        workStartedAt[taskId] = time
    }

    /// Records a turn's end (Stop / agentStopped): computes `baked` from the
    /// tracked start (dropped if there was no start or the clock went backward),
    /// and stores the sanitised `action`. Returns nothing — the transcript-
    /// derived `model`/`context` land separately via `setTranscript`.
    public func recordStop(taskId: UUID, action rawAction: String?, at time: Date) {
        var digest = digest(for: taskId)
        if let started = workStartedAt[taskId], time > started {
            digest.baked = time.timeIntervalSince(started)
        }
        digest.action = Self.sanitizedAction(rawAction)
        digests[taskId] = digest
        workStartedAt[taskId] = nil
    }

    /// Sets the deterministic diff counts. Pass `nil` to mark them unknown
    /// (renders blank); pass `DiffStat.zero` for a real no-change reading.
    public func setDiffStat(taskId: UUID, _ stat: DiffStat?) {
        var digest = digest(for: taskId)
        digest.diffStat = stat
        digests[taskId] = digest
    }

    /// Sets the transcript-derived stochastic fields. Either may be nil (e.g.
    /// a known model with an unknown context window → `context` stays nil and
    /// the meter is omitted).
    public func setTranscript(taskId: UUID, model: String?, context: ContextEstimate?) {
        var digest = digest(for: taskId)
        digest.model = model
        digest.context = context
        digests[taskId] = digest
    }

    /// Drops a removed task's digest + timing.
    public func remove(taskId: UUID) {
        digests.removeValue(forKey: taskId)
        workStartedAt.removeValue(forKey: taskId)
    }

    /// Trims an untrusted `last_assistant_message`: nil/empty → nil; otherwise
    /// clamped to `maxActionChars`. Content is NOT otherwise altered — it stays
    /// untrusted and must be rendered inert.
    static func sanitizedAction(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= maxActionChars ? trimmed : String(trimmed.prefix(maxActionChars))
    }
}
