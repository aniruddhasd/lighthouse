import Foundation
import Observation
import LighthouseAdapter
import LighthouseTaskEngine

/// How a hook event relates to a Lighthouse task. The whole point of phase 1a is
/// to find out whether attribution is trustworthy, so the distinction is kept in
/// the record rather than collapsed.
public enum HookAttribution: String, Codable, Sendable, Equatable {
    /// `session_id` equals the task's pre-assigned `sessionRef` — the primary agent.
    case primary
    /// A different session whose `cwd` is inside one of the task's workspaces —
    /// another `claude` started in a tile tab, or a resumed/forked session.
    case otherSessionInTask
    /// Matches no task.
    case unattributed
}

public struct LoggedHookEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let taskId: UUID?
    public let attribution: HookAttribution
    public let event: HookEvent

    public init(id: UUID = UUID(), taskId: UUID?, attribution: HookAttribution, event: HookEvent) {
        self.id = id
        self.taskId = taskId
        self.attribution = attribution
        self.event = event
    }
}

/// Pure attribution of one event against the current task list.
public enum HookAttributor {
    public static func attribute(_ event: HookEvent, tasks: [TaskRecord]) -> (taskId: UUID?, HookAttribution) {
        if let task = tasks.first(where: { $0.sessionRef == event.sessionId }) {
            return (task.id, .primary)
        }
        if let cwd = event.cwd, let task = tasks.first(where: { task in
            task.workspaces.contains { isInside(cwd, root: $0.worktreePath) }
        }) {
            return (task.id, .otherSessionInTask)
        }
        return (nil, .unattributed)
    }

    /// Path-boundary containment: `/a/bc` is NOT inside `/a/b`. Standardized so
    /// `..` and trailing slashes don't defeat or fake a match.
    static func isInside(_ path: String, root: String) -> Bool {
        guard !root.isEmpty else { return false }
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        let r = URL(fileURLWithPath: root).standardizedFileURL.path
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }
}

/// In-memory, bounded, observable event log for the UI (per task, newest last),
/// plus an optional durable sink so a week of observation survives restarts.
/// Contents are UNTRUSTED agent text — display inertly, never execute.
@MainActor @Observable
public final class HookEventLog {
    public static let maxPerTask = 300
    public static let maxUnattributed = 100

    public private(set) var byTask: [UUID: [LoggedHookEvent]] = [:]
    public private(set) var unattributed: [LoggedHookEvent] = []
    /// Set when the durable sink failed — surfaced, never swallowed silently.
    public private(set) var persistenceError: String?

    private let sink: HookEventSink?

    public init(sink: HookEventSink? = nil) {
        self.sink = sink
    }

    @discardableResult
    public func record(_ event: HookEvent, tasks: [TaskRecord]) -> LoggedHookEvent {
        let (taskId, attribution) = HookAttributor.attribute(event, tasks: tasks)
        let logged = LoggedHookEvent(taskId: taskId, attribution: attribution, event: event)
        if let taskId {
            var list = byTask[taskId, default: []]
            list.append(logged)
            if list.count > Self.maxPerTask { list.removeFirst(list.count - Self.maxPerTask) }
            byTask[taskId] = list
        } else {
            unattributed.append(logged)
            if unattributed.count > Self.maxUnattributed {
                unattributed.removeFirst(unattributed.count - Self.maxUnattributed)
            }
        }
        if let sink {
            do { try sink.append(logged); persistenceError = nil }
            catch { persistenceError = String(describing: error) }
        }
        return logged
    }

    public func events(for taskId: UUID) -> [LoggedHookEvent] { byTask[taskId] ?? [] }

    public func remove(taskId: UUID) { byTask.removeValue(forKey: taskId) }
}

/// Append-only JSONL file (one `LoggedHookEvent` per line), owner-only (0600) in
/// an owner-only directory. Rotates to `<name>.1` past `maxBytes` so a long
/// observation run cannot grow without bound. The file holds agent output —
/// treat it as sensitive; it lives in the app support dir, never the repo.
public final class HookEventSink: @unchecked Sendable {
    public static let fileName = "hook-events.jsonl"
    public static let defaultMaxBytes = 5 * 1024 * 1024

    private let fileURL: URL
    private let maxBytes: Int
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public init(directory: URL, maxBytes: Int = HookEventSink.defaultMaxBytes) {
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.maxBytes = maxBytes
    }

    public var url: URL { fileURL }

    public func append(_ logged: LoggedHookEvent) throws {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try fm.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var line = try encoder.encode(logged)
        line.append(0x0A)

        if let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int,
           size + line.count > maxBytes {
            let rotated = fileURL.appendingPathExtension("1")
            try? fm.removeItem(at: rotated)
            try fm.moveItem(at: fileURL, to: rotated)
        }
        if !fm.fileExists(atPath: fileURL.path) {
            guard fm.createFile(
                atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { throw CocoaError(.fileWriteUnknown) }
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}
