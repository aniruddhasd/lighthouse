import Foundation
import LighthouseAppCore
import LighthouseTaskEngine

/// Everything the read-only queries look at, captured at one instant: the task
/// list and the logged hook events. Plain values, so the queries are pure.
public struct SupervisorSnapshot: Sendable {
    public let tasks: [TaskRecord]
    public let events: [LoggedHookEvent]
    /// The app-owned proposal queue as last written. Empty when there is none yet.
    public let proposals: [Proposal]
    /// Set when the queue file exists but could not be read. A bad queue must not take
    /// the read tools down, but it must not look like "no proposals" either.
    public let proposalsError: String?
    /// Submissions in the inbox the app has not drained yet.
    public let proposalsAwaitingApp: Int
    public let now: Date

    public init(
        tasks: [TaskRecord], events: [LoggedHookEvent], proposals: [Proposal] = [],
        proposalsError: String? = nil, proposalsAwaitingApp: Int = 0, now: Date = Date()
    ) {
        self.tasks = tasks
        self.events = events
        self.proposals = proposals
        self.proposalsError = proposalsError
        self.proposalsAwaitingApp = proposalsAwaitingApp
        self.now = now
    }
}

/// Where a snapshot comes from. A protocol so the MCP layer is testable without
/// files, and so slice 2 can swap in an app-backed source without touching it.
public protocol SupervisorSnapshotSource: Sendable {
    func snapshot() throws -> SupervisorSnapshot
}

/// Reads the app's own persisted state — `config.json` (atomic writes) and
/// `hook-events.jsonl` (torn lines are skipped on load) — so no socket or daemon
/// is needed for reads. Read-only: nothing here writes either file.
public struct FileSnapshotSource: SupervisorSnapshotSource {
    /// How many recent events to read. The sink rotates at 5 MB, well under this.
    static let eventLimit = 5_000

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `$LIGHTHOUSE_CONFIG_DIR` (the app honours the same override) or the
    /// production Application Support location.
    public static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["LIGHTHOUSE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return ConfigStore.defaultDirectory()
    }

    public func snapshot() throws -> SupervisorSnapshot {
        // A corrupt config THROWS (surfaced as a tool error) rather than reading as
        // "no tasks": an empty answer would look like a clean, quiet system.
        let config = try ConfigStore(directory: directory).load()
        let events = try HookEventSink(directory: directory).loadRecent(limit: Self.eventLimit)
        let queue: ProposalQueue
        var queueError: String?
        do {
            queue = try ProposalStore(directory: directory).load()
        } catch {
            queue = ProposalQueue()
            queueError = "The proposal queue could not be read: \(error)"
        }
        return SupervisorSnapshot(
            tasks: config.tasks, events: events, proposals: queue.entries,
            proposalsError: queueError,
            proposalsAwaitingApp: ProposalInbox(configDirectory: directory).pendingCount())
    }
}
