import Foundation
import Testing
import LighthouseAdapter
import LighthouseAppCore
import LighthouseTaskEngine
@testable import LighthouseSupervisor

@Suite("FileSnapshotSource")
struct FileSnapshotSourceTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lh-sup-\(UUID().uuidString.prefix(8))")
    }

    @Test func missingDirectoryIsAnEmptySnapshotNotACrash() throws {
        let s = try FileSnapshotSource(directory: tempDir()).snapshot()
        #expect(s.tasks.isEmpty && s.events.isEmpty)
    }

    @Test func corruptConfigIsAThrownErrorNotSilentlyEmpty() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: dir.appendingPathComponent("config.json"))
        #expect(throws: (any Error).self) { try FileSnapshotSource(directory: dir).snapshot() }
    }

    @Test func readsTasksAndEventsWrittenByTheApp() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let task = TaskRecord(name: "t", branch: "b", adapterKind: "c", sessionRef: "s", supervised: true,
            workspaces: [Workspace(repoId: UUID(), worktreePath: "/w", mergeState: .unmerged)])
        let store = ConfigStore(directory: dir)
        try store.save(LighthouseConfig(tasks: [task]))
        let sink = HookEventSink(directory: dir)
        try sink.append(LoggedHookEvent(taskId: task.id, attribution: .primary,
            event: HookEvent(receivedAt: Date(timeIntervalSince1970: 5), eventName: "Stop", sessionId: "s")))

        let snap = try FileSnapshotSource(directory: dir).snapshot()
        #expect(snap.tasks.map(\.name) == ["t"] && snap.tasks[0].supervised)
        #expect(snap.events.map(\.event.eventName) == ["Stop"])
    }
}
