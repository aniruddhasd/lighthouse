import Foundation
import Testing
import LighthouseAdapter
import LighthouseTaskEngine
@testable import LighthouseAppCore

@Suite("HookAttributor")
struct HookAttributorTests {
    private func task(ref: String?, at path: String) -> TaskRecord {
        TaskRecord(
            name: "t", branch: "b", adapterKind: "claude-code", sessionRef: ref,
            workspaces: [Workspace(repoId: UUID(), worktreePath: path, mergeState: .unmerged)])
    }
    private func event(session: String, cwd: String?) -> HookEvent {
        HookEvent(receivedAt: Date(), eventName: "Stop", sessionId: session, cwd: cwd)
    }

    // MARK: Broken / adversarial first

    @Test func siblingDirectorySharingAPrefixIsNotInside() {
        let t = task(ref: "p", at: "/w/task-a")
        let r = HookAttributor.attribute(event(session: "x", cwd: "/w/task-ab"), tasks: [t])
        #expect(r.1 == .unattributed && r.taskId == nil)
    }

    @Test func dotDotCannotEscapeIntoAnotherTask() {
        let t = task(ref: "p", at: "/w/task-a")
        let r = HookAttributor.attribute(event(session: "x", cwd: "/w/task-a/../other"), tasks: [t])
        #expect(r.1 == .unattributed)
    }

    @Test func missingCwdAndUnknownSessionIsUnattributed() {
        let r = HookAttributor.attribute(event(session: "x", cwd: nil), tasks: [task(ref: "p", at: "/w/a")])
        #expect(r.1 == .unattributed)
    }

    @Test func emptyWorktreePathNeverMatches() {
        let r = HookAttributor.attribute(event(session: "x", cwd: "/anything"), tasks: [task(ref: "p", at: "")])
        #expect(r.1 == .unattributed)
    }

    // MARK: Attribution

    @Test func sessionRefMatchIsPrimaryEvenFromAnotherDirectory() {
        let t = task(ref: "p", at: "/w/a")
        let r = HookAttributor.attribute(event(session: "p", cwd: "/elsewhere"), tasks: [t])
        #expect(r.1 == .primary && r.taskId == t.id)
    }

    @Test func otherSessionInsideWorktreeSubdirIsOtherSessionInTask() {
        let t = task(ref: "p", at: "/w/a")
        let r = HookAttributor.attribute(event(session: "x", cwd: "/w/a/src/deep"), tasks: [t])
        #expect(r.1 == .otherSessionInTask && r.taskId == t.id)
    }
}

@Suite("HookEventLog")
@MainActor
struct HookEventLogTests {
    private func ev(_ n: Int, session: String = "p") -> HookEvent {
        HookEvent(receivedAt: Date(timeIntervalSince1970: Double(n)), eventName: "Stop", sessionId: session, cwd: "/w/a")
    }
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lh-log-\(UUID().uuidString.prefix(8))")
    }

    @Test func perTaskBufferIsBoundedKeepingNewest() {
        let t = TaskRecord(name: "t", branch: "b", adapterKind: "c", sessionRef: "p",
            workspaces: [Workspace(repoId: UUID(), worktreePath: "/w/a", mergeState: .unmerged)])
        let log = HookEventLog()
        for i in 0..<(HookEventLog.maxPerTask + 25) { log.record(ev(i), tasks: [t]) }
        let kept = log.events(for: t.id)
        #expect(kept.count == HookEventLog.maxPerTask)
        #expect(kept.last?.event.receivedAt == Date(timeIntervalSince1970: Double(HookEventLog.maxPerTask + 24)))
    }

    @Test func unattributedBufferIsBounded() {
        let log = HookEventLog()
        for i in 0..<(HookEventLog.maxUnattributed + 10) { log.record(ev(i, session: "nobody"), tasks: []) }
        #expect(log.unattributed.count == HookEventLog.maxUnattributed)
    }

    @Test func sinkWritesOwnerOnlyJSONLAndFailureIsSurfaced() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = HookEventLog(sink: HookEventSink(directory: dir))
        log.record(ev(1), tasks: [])
        let url = dir.appendingPathComponent(HookEventSink.fileName)
        let perms = try #require((try FileManager.default.attributesOfItem(atPath: url.path))[.posixPermissions] as? NSNumber)
        #expect(perms.uint16Value & 0o777 == 0o600)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        #expect(log.persistenceError == nil)

        // Directory path occupied by a FILE → append must fail loudly, not silently.
        let blocker = tempDir(); defer { try? FileManager.default.removeItem(at: blocker) }
        try Data().write(to: blocker)
        let bad = HookEventLog(sink: HookEventSink(directory: blocker))
        bad.record(ev(1), tasks: [])
        #expect(bad.persistenceError != nil)
    }

    @Test func sinkRotatesPastMaxBytes() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sink = HookEventSink(directory: dir, maxBytes: 600)
        for i in 0..<10 {
            try sink.append(LoggedHookEvent(taskId: nil, attribution: .unattributed, event: ev(i)))
        }
        #expect(FileManager.default.fileExists(atPath: sink.url.appendingPathExtension("1").path))
        let size = try #require((try FileManager.default.attributesOfItem(atPath: sink.url.path))[.size] as? Int)
        #expect(size <= 600)
    }

    // MARK: Restore from the durable file (history survives a restart)

    private func task(_ ref: String) -> TaskRecord {
        TaskRecord(name: "t", branch: "b", adapterKind: "c", sessionRef: ref,
            workspaces: [Workspace(repoId: UUID(), worktreePath: "/w/a", mergeState: .unmerged)])
    }

    @Test func loadRecentOnMissingFileIsEmptyNotAnError() throws {
        let dir = tempDir()
        #expect(try HookEventSink(directory: dir).loadRecent(limit: 10).isEmpty)
    }

    @Test func loadRecentSkipsMalformedLinesAndKeepsNewestInOrder() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sink = HookEventSink(directory: dir)
        for i in 0..<5 {
            try sink.append(LoggedHookEvent(taskId: nil, attribution: .unattributed, event: ev(i)))
        }
        // Corrupt the middle: a torn write / hand edit must not cost the rest.
        var text = try String(contentsOf: sink.url, encoding: .utf8)
        text += "{ not json\n\n"
        try text.write(to: sink.url, atomically: true, encoding: .utf8)
        try sink.append(LoggedHookEvent(taskId: nil, attribution: .unattributed, event: ev(9)))

        let recent = try sink.loadRecent(limit: 3)
        #expect(recent.map(\.event.receivedAt.timeIntervalSince1970) == [3, 4, 9])
    }

    @Test func loadRecentReadsTheRotatedFileFirstSoRotationDoesNotLoseHistory() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sink = HookEventSink(directory: dir, maxBytes: 600)
        for i in 0..<10 {
            try sink.append(LoggedHookEvent(taskId: nil, attribution: .unattributed, event: ev(i)))
        }
        let times = try sink.loadRecent(limit: 50).map(\.event.receivedAt.timeIntervalSince1970)
        #expect(times == times.sorted())
        #expect(times.last == 9)
        #expect(times.count > 1)
    }

    @Test func restorePopulatesBoundedHistoryWithoutRewritingTheFile() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let t = task("p")
        let sink = HookEventSink(directory: dir)
        for i in 0..<5 {
            try sink.append(LoggedHookEvent(taskId: t.id, attribution: .primary, event: ev(i)))
        }
        let before = try Data(contentsOf: sink.url)

        let log = MainActorBox.make(sink: sink)
        log.restore(tasks: [t])
        #expect(log.events(for: t.id).count == 5)
        #expect(try Data(contentsOf: sink.url) == before, "restore must not append to the file")
    }

    @Test func restoreDropsEventsOfTasksThatNoLongerExist() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let gone = UUID(), kept = task("p")
        let sink = HookEventSink(directory: dir)
        try sink.append(LoggedHookEvent(taskId: gone, attribution: .primary, event: ev(1)))
        try sink.append(LoggedHookEvent(taskId: kept.id, attribution: .primary, event: ev(2)))
        try sink.append(LoggedHookEvent(taskId: nil, attribution: .unattributed, event: ev(3)))

        let log = MainActorBox.make(sink: sink)
        log.restore(tasks: [kept])
        #expect(log.byTask[gone] == nil)
        #expect(log.events(for: kept.id).count == 1)
        #expect(log.unattributed.count == 1)
    }

    // MARK: Drop counter

    @Test func dropsAreCountedWithTheLastReasonBounded() {
        let log = HookEventLog()
        #expect(log.droppedCount == 0 && log.lastDropReason == nil)
        log.recordDrop("first")
        log.recordDrop(String(repeating: "x", count: 5_000))
        #expect(log.droppedCount == 2)
        #expect((log.lastDropReason?.count ?? 0) <= HookEventLog.maxDropReasonChars)
    }
}

/// Builds a main-actor log from a (nonisolated) test helper context.
@MainActor private enum MainActorBox {
    static func make(sink: HookEventSink) -> HookEventLog { HookEventLog(sink: sink) }
}
