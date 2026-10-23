import Foundation
import Testing
import LighthouseTaskEngine
@testable import LighthouseSupervisor

@MainActor
@Suite("ProposalCenter", .serialized)
struct ProposalCenterTests {
    private let a = TaskRecord(name: "a", branch: "b", adapterKind: "c", sessionRef: "s", supervised: true, workspaces: [])
    private let now = Date(timeIntervalSince1970: 1_000)

    private func dir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lh-pc-\(UUID().uuidString.prefix(8))")
    }
    private func d(_ text: String = "go on", task: String = "a") -> ProposalDraft {
        ProposalDraft(kind: .send, task: task, text: text, reason: "r", basedOn: Date(timeIntervalSince1970: 5))
    }

    // MARK: Failure modes first

    /// A queue file we cannot read must never be overwritten: that would destroy
    /// whatever the user has not yet handled. Nothing is drained either.
    @Test func corruptQueueIsNeitherOverwrittenNorDrained() throws {
        let dir = dir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bad = Data("{ not a queue".utf8)
        try bad.write(to: dir.appendingPathComponent(ProposalStore.fileName))
        try ProposalInbox(configDirectory: dir).enqueue(d())

        let center = ProposalCenter(directory: dir)
        #expect(center.loadError != nil)
        center.drain(tasks: [a], now: now)
        #expect(try Data(contentsOf: dir.appendingPathComponent(ProposalStore.fileName)) == bad)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: ProposalInbox(configDirectory: dir).directory.path).count == 1, "the submission must stay queued")
        #expect(center.queue.entries.isEmpty)
    }

    @Test func aFailedSaveKeepsTheInboxFilesAndTheOldQueue() throws {
        let dir = dir(); defer { chmod(dir.path, 0o700); try? FileManager.default.removeItem(at: dir) }
        let center = ProposalCenter(directory: dir)
        try ProposalInbox(configDirectory: dir).enqueue(d())
        // Make the directory unwritable so the queue file cannot be created. Take the
        // inbox files' parent into account: only the *queue* write must fail.
        chmod(dir.path, 0o500)
        center.drain(tasks: [a], now: now)
        chmod(dir.path, 0o700)
        #expect(center.persistenceError != nil)
        #expect(center.queue.entries.isEmpty, "in-memory queue must not run ahead of what was saved")
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: ProposalInbox(configDirectory: dir).directory.path).count == 1)

        // Retry once writable: the same submission lands, exactly once.
        center.drain(tasks: [a], now: now)
        #expect(center.persistenceError == nil)
        #expect(center.queue.entries.count == 1)
    }

    @Test func invalidSubmissionsAreRecordedAsRejectedNotLost() throws {
        let dir = dir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = ProposalInbox(configDirectory: dir)
        try FileManager.default.createDirectory(at: inbox.directory, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: inbox.directory.appendingPathComponent("\(UUID().uuidString).json"))
        let center = ProposalCenter(directory: dir)
        center.drain(tasks: [a], now: now)
        #expect(center.queue.entries.count == 1)
        #expect(center.queue.entries[0].status == .rejected)
    }

    // MARK: Behaviour

    @Test func drainIngestsPersistsAndEmptiesTheInbox() throws {
        let dir = dir(); defer { try? FileManager.default.removeItem(at: dir) }
        try ProposalInbox(configDirectory: dir).enqueue(d("first"))
        try ProposalInbox(configDirectory: dir).enqueue(d("second"))
        let center = ProposalCenter(directory: dir)
        center.drain(tasks: [a], now: now)
        #expect(center.pending(for: a.id).map(\.text).sorted() == ["first", "second"])
        #expect(try ProposalStore(directory: dir).load().entries.count == 2, "persisted")
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: ProposalInbox(configDirectory: dir).directory.path).isEmpty)
    }

    @Test func aRestartReloadsWhatWasPending() throws {
        let dir = dir(); defer { try? FileManager.default.removeItem(at: dir) }
        try ProposalInbox(configDirectory: dir).enqueue(d())
        ProposalCenter(directory: dir).drain(tasks: [a], now: now)
        #expect(ProposalCenter(directory: dir).pending(for: a.id).count == 1)
    }

    @Test func dismissPersistsAndAProposalFromAnOptedOutTaskIsRejected() throws {
        let dir = dir(); defer { try? FileManager.default.removeItem(at: dir) }
        let off = TaskRecord(name: "off", branch: "b", adapterKind: "c", sessionRef: "s2", supervised: false, workspaces: [])
        try ProposalInbox(configDirectory: dir).enqueue(d(task: "off"))
        try ProposalInbox(configDirectory: dir).enqueue(d(task: "a"))
        let center = ProposalCenter(directory: dir)
        center.drain(tasks: [a, off], now: now)
        #expect(center.queue.entries.filter { $0.status == .rejected }.count == 1)

        let id = try #require(center.pending(for: a.id).first?.id)
        center.dismiss(id)
        #expect(center.pending(for: a.id).isEmpty)
        #expect(ProposalCenter(directory: dir).pending(for: a.id).isEmpty, "dismissal persisted")
    }

    @Test func drainWithNothingWaitingDoesNotTouchTheQueueFile() throws {
        let dir = dir(); defer { try? FileManager.default.removeItem(at: dir) }
        let center = ProposalCenter(directory: dir)
        center.drain(tasks: [a], now: now)
        #expect(!FileManager.default.fileExists(atPath: ProposalStore(directory: dir).url.path))
    }
}
