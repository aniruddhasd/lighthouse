import Foundation
import Observation
import LighthouseAppCore
import LighthouseTaskEngine

/// What the app provides for delivery: facts about the task's terminal, and the one
/// action. A protocol so every refusal path is tested without a real pty.
@MainActor
public protocol ProposalDelivering: AnyObject {
    func terminalRunning(taskId: UUID) -> Bool
    /// Whether `claude` is what is running in the tab; nil when it could not be checked.
    func claudeIsForeground(taskId: UUID) -> Bool?
    func lastUserInput(taskId: UUID) -> Date?
    /// Types `text` into the task's agent terminal WITHOUT a trailing newline (3a: the
    /// user reads it in place and presses Enter). False if nothing was typed.
    func typeInto(taskId: UUID, text: String) -> Bool
}

public enum ConfirmOutcome: Equatable, Sendable {
    case sent
    /// The gate said no; the proposal stays pending.
    case refused([GateRefusal])
    /// Overtaken by events; the proposal was retired.
    case expired(String)
    /// Confirmed but not delivered (could not record it, or the terminal refused it).
    case failed(String)
    /// The queue is read-only or the proposal is unknown.
    case notAvailable(String)
}

/// The app's single owner of the proposal queue: loads it, ingests inbox submissions,
/// persists, and exposes it to the UI. All rules live in `ProposalQueue` /
/// `ProposalValidator`; this only sequences I/O around them safely.
@MainActor @Observable
public final class ProposalCenter {
    public static let drainBatch = 50

    public private(set) var queue = ProposalQueue()
    /// Set when the queue file exists but could not be read. While set the center is
    /// read-only: it will not overwrite the file and will not drain the inbox.
    public private(set) var loadError: String?
    /// The last save failure, surfaced rather than swallowed.
    public private(set) var persistenceError: String?

    private let store: ProposalStore
    private let inbox: ProposalInbox

    public init(directory: URL) {
        store = ProposalStore(directory: directory)
        inbox = ProposalInbox(configDirectory: directory)
        do {
            queue = try store.load()
        } catch {
            loadError = "The proposal queue could not be read, so it is left untouched: \(error)"
        }
    }

    public func pending(for taskId: UUID) -> [Proposal] { queue.pending(for: taskId) }

    /// The newest rejected entries for a task, for the card.
    public func recentRejected(for taskId: UUID, limit: Int = 3) -> [Proposal] {
        Array(queue.entries.filter { $0.taskId == taskId && $0.status == .rejected }.suffix(limit).reversed())
    }

    /// Sent / expired / failed entries for a task, newest first.
    public func recentResolved(for taskId: UUID, limit: Int = 3) -> [Proposal] {
        let done: Set<ProposalStatus> = [.sent, .expired, .failed]
        return Array(queue.entries
            .filter { $0.taskId == taskId && done.contains($0.status) }
            .sorted { ($0.resolvedAt ?? .distantPast) > ($1.resolvedAt ?? .distantPast) }
            .prefix(limit))
    }

    /// Ingests whatever is waiting in the inbox. Take → ingest into a COPY → save →
    /// swap in → discard: if the save fails, neither the in-memory queue nor the inbox
    /// files have changed, so the next pass retries cleanly and nothing is lost or
    /// duplicated.
    public func drain(tasks: [TaskRecord], now: Date = Date()) {
        guard loadError == nil else { return }
        let batch = inbox.take(limit: Self.drainBatch)
        guard !batch.items.isEmpty else { return }

        var next = queue
        for item in batch.items {
            switch item {
            case .draft(let draft): next.ingest(draft, tasks: tasks, now: now)
            case .invalid(let reason): next.recordInvalidSubmission(reason: reason, now: now)
            }
        }
        do {
            try store.save(next)
        } catch {
            persistenceError = "Could not save proposals: \(error)"
            return
        }
        queue = next
        persistenceError = nil
        inbox.discard(batch)
    }

    public func dismiss(_ id: UUID, now: Date = Date()) {
        guard loadError == nil else { return }
        var next = queue
        guard next.dismiss(id, now: now) else { return }
        do {
            try store.save(next)
            queue = next
            persistenceError = nil
        } catch {
            persistenceError = "Could not save proposals: \(error)"
        }
    }

    // MARK: Delivery (slice 3a)

    /// The gate's verdict for the review sheet's live checklist. Nil for an unknown id.
    public func evaluate(
        _ id: UUID, task: TaskRecord, events: [LoggedHookEvent],
        delivery: ProposalDelivering, now: Date = Date()
    ) -> GateResult? {
        guard let proposal = queue.entries.first(where: { $0.id == id }) else { return nil }
        return DeliveryGate.check(context(proposal, task: task, events: events, delivery: delivery, now: now))
    }

    /// Confirms a `send`: re-runs the gate NOW, then records it as sent, then types it.
    /// The order is the whole point — the entry is saved as `sent` before a single
    /// character is typed, so a crash or a retry can never type the same message twice
    /// (the price: a crash between save and type reads as sent when it wasn't).
    public func confirm(
        _ id: UUID, task: TaskRecord, events: [LoggedHookEvent],
        delivery: ProposalDelivering, now: Date = Date()
    ) -> ConfirmOutcome {
        if let loadError { return .notAvailable(loadError) }
        guard let proposal = queue.entries.first(where: { $0.id == id }) else {
            return .notAvailable("That proposal no longer exists.")
        }
        let verdict = DeliveryGate.check(context(proposal, task: task, events: events, delivery: delivery, now: now))

        if let reason = verdict.expireReason, proposal.status == .pending {
            var next = queue
            if next.expire(id, reason: reason, now: now), (try? store.save(next)) != nil {
                queue = next
                persistenceError = nil
            }
            return .expired(reason)
        }
        guard verdict.allowed else { return .refused(verdict.refusals) }

        var next = queue
        guard next.markSent(id, now: now) else { return .notAvailable("That proposal is no longer pending.") }
        do {
            try store.save(next)
        } catch {
            persistenceError = "Could not save proposals: \(error)"
            return .failed("The send could not be recorded, so nothing was typed.")
        }
        queue = next
        persistenceError = nil

        guard let taskId = proposal.taskId, delivery.typeInto(taskId: taskId, text: proposal.text) else {
            // Memory always reflects the truth (nothing was typed). If this second save
            // fails the file still says `sent` — the conservative side for at-most-once.
            var failed = queue
            if failed.markFailed(id, reason: "The terminal did not accept the text.", now: now) {
                queue = failed
                _ = try? store.save(failed)
            }
            return .failed("The terminal did not accept the text.")
        }
        return .sent
    }

    /// Retires pending sends that events have overtaken. Called on the same tick as the
    /// inbox drain. Only a PROVEN overtake expires anything: a proposal whose turn the
    /// log cannot find is left alone ("unknown" is not "stale").
    public func expireStale(
        tasks: [TaskRecord], eventsFor: (UUID) -> [LoggedHookEvent], now: Date = Date()
    ) {
        guard loadError == nil else { return }
        var next = queue
        var changed = false
        for proposal in queue.entries where proposal.status == .pending && proposal.kind == .send {
            guard let taskId = proposal.taskId, let task = tasks.first(where: { $0.id == taskId }) else { continue }
            let verdict = DeliveryGate.check(DeliveryContext(
                proposal: proposal, taskSupervised: task.supervised, events: eventsFor(taskId), now: now,
                terminalRunning: true, claudeIsForeground: true, lastUserInput: nil, sentInLastHour: 0))
            if let reason = verdict.expireReason, next.expire(proposal.id, reason: reason, now: now) {
                changed = true
            }
        }
        guard changed else { return }
        do {
            try store.save(next)
            queue = next
            persistenceError = nil
        } catch {
            persistenceError = "Could not save proposals: \(error)"
        }
    }

    private func context(
        _ proposal: Proposal, task: TaskRecord, events: [LoggedHookEvent],
        delivery: ProposalDelivering, now: Date
    ) -> DeliveryContext {
        DeliveryContext(
            proposal: proposal, taskSupervised: task.supervised, events: events, now: now,
            terminalRunning: delivery.terminalRunning(taskId: task.id),
            claudeIsForeground: delivery.claudeIsForeground(taskId: task.id),
            lastUserInput: delivery.lastUserInput(taskId: task.id),
            sentInLastHour: queue.sentCount(for: task.id, since: now.addingTimeInterval(-3_600)))
    }
}

