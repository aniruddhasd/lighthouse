import Foundation
import LighthouseAppCore
import LighthouseTaskEngine

/// Everything the read-only queries look at, captured at one instant: the task
/// list and the logged hook events. Plain values, so the queries are pure.
public struct SupervisorSnapshot: Sendable {
    public let tasks: [TaskRecord]
    public let events: [LoggedHookEvent]
    public let now: Date

    public init(tasks: [TaskRecord], events: [LoggedHookEvent], now: Date = Date()) {
        self.tasks = tasks
        self.events = events
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
        return SupervisorSnapshot(tasks: config.tasks, events: events)
    }
}
