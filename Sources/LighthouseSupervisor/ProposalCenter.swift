import Foundation
import Observation
import LighthouseTaskEngine

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

    public func dismiss(_ id: UUID) {
        guard loadError == nil else { return }
        var next = queue
        guard next.dismiss(id) else { return }
        do {
            try store.save(next)
            queue = next
            persistenceError = nil
        } catch {
            persistenceError = "Could not save proposals: \(error)"
        }
    }
}
