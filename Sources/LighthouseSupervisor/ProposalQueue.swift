import Foundation
import LighthouseTaskEngine

/// The app-owned proposal queue: a pure value (single writer — the app), so every
/// rule here is unit-tested without files or UI.
public struct ProposalQueue: Codable, Equatable, Sendable {
    public static let maxPendingPerTask = 5
    public static let maxEntries = 100
    /// Rejected drafts are stored clipped and sanitized: they came from an untrusted
    /// submission and are only kept so the user (and the supervisor) can see why.
    static let maxStoredRejectedChars = 200

    public private(set) var entries: [Proposal]

    public init(entries: [Proposal] = []) {
        self.entries = entries
    }

    public func pending(for taskId: UUID) -> [Proposal] {
        entries.filter { $0.taskId == taskId && $0.status == .pending }
    }

    /// Validates and records a draft. Always returns the recorded entry — pending, or
    /// rejected with a reason; nothing is silently dropped. An identical pending
    /// proposal is returned as-is instead of being added again.
    @discardableResult
    public mutating func ingest(_ draft: ProposalDraft, tasks: [TaskRecord], now: Date) -> Proposal {
        let validated: ValidatedProposal
        do {
            validated = try ProposalValidator.validate(draft, tasks: tasks)
        } catch let rejection as ProposalRejection {
            return record(rejected: draft, reason: rejection.reason, tasks: tasks, now: now)
        } catch {
            return record(rejected: draft, reason: "Invalid proposal.", tasks: tasks, now: now)
        }
        let d = validated.draft
        if let existing = entries.first(where: {
            $0.status == .pending && $0.taskId == validated.taskId && $0.kind == d.kind
                && $0.text == d.text && $0.basedOn == d.basedOn
                && $0.sourceTaskId == validated.sourceTaskId
        }) {
            return existing
        }
        if pending(for: validated.taskId).count >= Self.maxPendingPerTask {
            return record(
                rejected: draft,
                reason: "Too many pending proposals for this task (max \(Self.maxPendingPerTask)); dismiss some first.",
                tasks: tasks, now: now)
        }
        var proposal = Proposal(
            id: UUID(), taskId: validated.taskId, taskRef: String(d.task.prefix(80)), kind: d.kind,
            text: d.text, reason: d.reason, basedOn: d.basedOn, createdAt: now,
            status: .pending, rejectionReason: nil)
        proposal.sourceTaskId = validated.sourceTaskId
        proposal.sourceTaskRef = validated.sourceTaskId == nil ? nil : d.sourceTask.map { String(Self.sanitized($0).prefix(80)) }
        entries.append(proposal)
        prune()
        return proposal
    }

    /// A submission that could not even be parsed (oversize, malformed, not a regular
    /// file): kept as a rejected entry so it is visible, never silently lost.
    @discardableResult
    public mutating func recordInvalidSubmission(reason: String, now: Date) -> Proposal {
        let proposal = Proposal(
            id: UUID(), taskId: nil, taskRef: "", kind: .hold, text: "", reason: "",
            basedOn: nil, createdAt: now, status: .rejected, rejectionReason: Self.clipped(reason))
        entries.append(proposal)
        prune()
        return proposal
    }

    /// Pending → dismissed. False for an unknown id or one that is not pending.
    @discardableResult
    public mutating func dismiss(_ id: UUID, now: Date = Date()) -> Bool {
        resolve(id, from: [.pending], to: .dismissed, note: nil, now: now)
    }

    /// Pending → sent. The caller PERSISTS this before typing anything: a second call
    /// returns false, which is what makes delivery at-most-once.
    @discardableResult
    public mutating func markSent(_ id: UUID, now: Date) -> Bool {
        resolve(id, from: [.pending], to: .sent, note: nil, now: now)
    }

    /// Pending → expired (overtaken by events).
    @discardableResult
    public mutating func expire(_ id: UUID, reason: String, now: Date) -> Bool {
        resolve(id, from: [.pending], to: .expired, note: reason, now: now)
    }

    /// Sent (or pending) → failed: delivery was confirmed but did not happen.
    @discardableResult
    public mutating func markFailed(_ id: UUID, reason: String, now: Date) -> Bool {
        resolve(id, from: [.sent, .pending], to: .failed, note: reason, now: now)
    }

    /// Deliveries that actually went out for a task since `date` (failed ones typed
    /// nothing and do not count) — the input to the per-hour rate breaker.
    public func sentCount(for taskId: UUID, since date: Date) -> Int {
        entries.filter { $0.taskId == taskId && $0.status == .sent && ($0.resolvedAt ?? .distantPast) >= date }.count
    }

    private mutating func resolve(
        _ id: UUID, from: Set<ProposalStatus>, to: ProposalStatus, note: String?, now: Date
    ) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id && from.contains($0.status) })
        else { return false }
        entries[index].status = to
        entries[index].resolvedAt = now
        entries[index].resolutionNote = note.map(Self.clipped)
        return true
    }

    // MARK: Helpers

    private mutating func record(
        rejected draft: ProposalDraft, reason: String, tasks: [TaskRecord], now: Date
    ) -> Proposal {
        var proposal = Proposal(
            id: UUID(), taskId: try? TaskLookup.resolve(draft.task, in: tasks).id,
            taskRef: String(Self.sanitized(draft.task).prefix(80)), kind: draft.kind,
            text: Self.clipped(draft.text), reason: Self.clipped(draft.reason),
            basedOn: draft.basedOn, createdAt: now, status: .rejected, rejectionReason: reason)
        proposal.sourceTaskRef = draft.sourceTask.map { String(Self.sanitized($0).prefix(80)) }
        entries.append(proposal)
        prune()
        return proposal
    }

    /// Past the cap, drop the oldest NON-pending entries first. A pending proposal is
    /// never pruned (it is something the user has not yet seen resolved).
    private mutating func prune() {
        while entries.count > Self.maxEntries,
              let index = entries.firstIndex(where: { $0.status != .pending }) {
            entries.remove(at: index)
        }
    }

    private static func clipped(_ s: String) -> String {
        String(sanitized(s).prefix(maxStoredRejectedChars))
    }

    /// Control characters → U+FFFD, so stored text can never carry keystrokes.
    private static func sanitized(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map {
            switch $0.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: return "\u{FFFD}"
            default: return $0
            }
        }))
    }
}

/// Atomic JSON persistence for the queue. The app is the only writer; the MCP
/// process only reads it.
public struct ProposalStore: Sendable {
    public static let fileName = "proposals.json"
    private let file: OwnerOnlyJSONFile<ProposalQueue>

    public init(directory: URL) {
        file = OwnerOnlyJSONFile(directory: directory, fileName: Self.fileName)
    }

    public var url: URL { file.url }

    /// A missing file is an empty queue; a corrupt one THROWS (an empty answer would
    /// silently discard what the user has not yet handled).
    public func load() throws -> ProposalQueue { try file.load() ?? ProposalQueue() }

    public func save(_ queue: ProposalQueue) throws { try file.save(queue) }
}
