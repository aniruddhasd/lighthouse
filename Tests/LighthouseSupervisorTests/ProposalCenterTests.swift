import Foundation
import Testing
import LighthouseAdapter
import LighthouseAppCore
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

// MARK: - Confirmed delivery (slice 3a)

@MainActor
final class FakeDelivery: ProposalDelivering {
    var running = true
    var claude: Bool? = true
    var lastInput: Date?
    var typeResult = true
    var typed: [(UUID, String)] = []
    /// Runs inside `typeInto`, so a test can observe what was on DISK at that instant.
    var onType: (() -> Void)?

    func terminalRunning(taskId: UUID) -> Bool { running }
    func claudeIsForeground(taskId: UUID) -> Bool? { claude }
    func lastUserInput(taskId: UUID) -> Date? { lastInput }
    func typeInto(taskId: UUID, text: String) -> Bool {
        onType?()
        typed.append((taskId, text))
        return typeResult
    }
}

@MainActor
@Suite("ProposalCenter delivery", .serialized)
struct ProposalCenterDeliveryTests {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)
    private let task = TaskRecord(name: "a", branch: "b", adapterKind: "c", sessionRef: "s", supervised: true, workspaces: [])

    private func dir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lh-dl-\(UUID().uuidString.prefix(8))")
    }

    private func events(_ extra: [LoggedHookEvent] = []) -> [LoggedHookEvent] {
        func e(_ n: String, _ s: TimeInterval) -> LoggedHookEvent {
            LoggedHookEvent(taskId: task.id, attribution: .primary,
                event: HookEvent(receivedAt: t0.addingTimeInterval(s), eventName: n, sessionId: "s"))
        }
        return [e("UserPromptSubmit", -60), e("Stop", 0)] + extra
    }

    /// A center holding one pending `send` based on the Stop at t0.
    private func center(_ dir: URL, text: String = "please open the PR") throws -> (ProposalCenter, UUID) {
        try ProposalInbox(configDirectory: dir).enqueue(ProposalDraft(
            kind: .send, task: "a", text: text, reason: "turn finished", basedOn: t0))
        let c = ProposalCenter(directory: dir)
        c.drain(tasks: [task], now: t0)
        return (c, try #require(c.pending(for: task.id).first?.id))
    }

    private func confirm(_ c: ProposalCenter, _ id: UUID, _ d: FakeDelivery,
                         _ ev: [LoggedHookEvent]? = nil, now: TimeInterval = 60) -> ConfirmOutcome {
        c.confirm(id, task: task, events: ev ?? events(), delivery: d, now: t0.addingTimeInterval(now))
    }

    // MARK: Ordering and failure modes first

    /// THE at-most-once property: the proposal is already `sent` ON DISK when the text is typed.
    @Test func sentIsPersistedBeforeAnythingIsTyped() throws {
        let dir = dir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (c, id) = try center(dir)
        let d = FakeDelivery()
        var onDiskWhileTyping: ProposalStatus?
        d.onType = { onDiskWhileTyping = try? ProposalStore(directory: dir).load().entries.first { $0.id == id }?.status }
        let out = confirm(c, id, d)
        #expect(out == .sent)
        #expect(onDiskWhileTyping == .sent, "must already be saved as sent when the text is typed")
        #expect(d.typed.count == 1 && d.typed[0].1 == "please open the PR")
    }

    @Test func aFailedSaveTypesNothing() throws {
        let dir = dir(); defer { chmod(dir.path, 0o700); try? FileManager.default.removeItem(at: dir) }
        let (c, id) = try center(dir)
        let d = FakeDelivery()
        chmod(dir.path, 0o500)
        let out = confirm(c, id, d)
        chmod(dir.path, 0o700)
        #expect(d.typed.isEmpty, "if we could not record the send, we must not perform it")
        if case .failed = out {} else { Issue.record("expected .failed, got \(out)") }
        #expect(c.pending(for: task.id).count == 1, "still pending so the user can retry")
        #expect(c.persistenceError != nil)
    }

    @Test func aTypingFailureLeavesAFailedEntryNotASentOne() throws {
        let dir = dir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (c, id) = try center(dir)
        let d = FakeDelivery(); d.typeResult = false
        let out = confirm(c, id, d)
        if case .failed = out {} else { Issue.record("expected .failed, got \(out)") }
        let entry = try #require(c.queue.entries.first { $0.id == id })
        #expect(entry.status == .failed && entry.resolutionNote != nil)
        #expect(c.queue.sentCount(for: task.id, since: .distantPast) == 0)
        #expect(try ProposalStore(directory: dir).load().entries.first { $0.id == id }?.status == .failed)
    }

    @Test func aSecondConfirmNeverTypesAgain() throws {
        let dir = dir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (c, id) = try center(dir)
        let d = FakeDelivery()
        #expect(confirm(c, id, d) == .sent)
        let second = confirm(c, id, d)
        #expect(second != .sent)
        #expect(d.typed.count == 1)
    }

    @Test func aStaleProposalIsExpiredAndNeverTyped() throws {
        let dir = dir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (c, id) = try center(dir)
        let d = FakeDelivery()
        var later = events()
        later.append(LoggedHookEvent(taskId: task.id, attribution: .primary, event: HookEvent(
            receivedAt: t0.addingTimeInterval(20), eventName: "UserPromptSubmit", sessionId: "s")))
        let out = confirm(c, id, d, later)
        if case .expired = out {} else { Issue.record("expected .expired, got \(out)") }
        #expect(d.typed.isEmpty)
        #expect(c.queue.entries.first { $0.id == id }?.status == .expired)
        #expect(ProposalCenter(directory: dir).pending(for: task.id).isEmpty, "expiry persisted")
    }

    @Test func refusalsLeaveTheProposalPendingAndTypeNothing() throws {
        let dir = dir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (c, id) = try center(dir)
        let d = FakeDelivery(); d.running = false
        let out = confirm(c, id, d)
        guard case .refused(let why) = out else { Issue.record("expected .refused, got \(out)"); return }
        #expect(why.contains(.noTerminal) && d.typed.isEmpty)
        #expect(c.pending(for: task.id).count == 1)
    }

    @Test func userTypingBlocksDeliveryUntilTheyStop() throws {
        let dir = dir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (c, id) = try center(dir)
        let d = FakeDelivery(); d.lastInput = t0.addingTimeInterval(57)
        guard case .refused = confirm(c, id, d, now: 60) else { Issue.record("should refuse"); return }
        #expect(confirm(c, id, d, now: 80) == .sent, "20 s after the last keystroke it goes through")
    }

    @Test func theRateBreakerCountsRealSendsAndStopsTheSeventh() throws {
        let dir = dir(); defer { try? FileManager.default.removeItem(at: dir) }
        let d = FakeDelivery()
        let c = ProposalCenter(directory: dir)
        for i in 0..<(DeliveryGate.maxPerHour + 1) {
            try ProposalInbox(configDirectory: dir).enqueue(ProposalDraft(
                kind: .send, task: "a", text: "message \(i)", reason: "r", basedOn: t0))
            c.drain(tasks: [task], now: t0)
            let id = try #require(c.pending(for: task.id).first { $0.text == "message \(i)" }?.id)
            let out = confirm(c, id, d, now: 60 + Double(i))
            if i < DeliveryGate.maxPerHour { #expect(out == .sent, "send \(i)") }
            else { guard case .refused(let why) = out else { Issue.record("expected refusal"); return }
                   #expect(why.contains(.rateLimited)) }
        }
        #expect(d.typed.count == DeliveryGate.maxPerHour)
    }

    @Test func aCorruptQueueRefusesToDeliverAnything() throws {
        let dir = dir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: dir.appendingPathComponent(ProposalStore.fileName))
        let c = ProposalCenter(directory: dir)
        let d = FakeDelivery()
        let out = confirm(c, UUID(), d)
        if case .notAvailable = out {} else { Issue.record("expected .notAvailable, got \(out)") }
        #expect(d.typed.isEmpty)
    }

    @Test func holdAndAskUserCannotBeDelivered() throws {
        let dir = dir(); defer { try? FileManager.default.removeItem(at: dir) }
        try ProposalInbox(configDirectory: dir).enqueue(ProposalDraft(kind: .hold, task: "a", text: "VPN down", reason: "blocked"))
        let c = ProposalCenter(directory: dir); c.drain(tasks: [task], now: t0)
        let id = try #require(c.pending(for: task.id).first?.id)
        let d = FakeDelivery()
        guard case .refused(let why) = confirm(c, id, d) else { Issue.record("should refuse"); return }
        #expect(why.contains(.notASend) && d.typed.isEmpty)
    }

    // MARK: Expiry on the background tick

    @Test func expireStaleRetiresOnlyOvertakenSendsAndTheSessionEndTooButNotFreshOnes() throws {
        let dir = dir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (c, fresh) = try center(dir, text: "still good")
        try ProposalInbox(configDirectory: dir).enqueue(ProposalDraft(
            kind: .send, task: "a", text: "old news", reason: "r", basedOn: t0.addingTimeInterval(-300)))
        c.drain(tasks: [task], now: t0)
        let oldId = try #require(c.pending(for: task.id).first { $0.text == "old news" }?.id)

        // The log knows a Stop at -300 (the old turn) and one at 0, with a prompt between.
        func e(_ n: String, _ s: TimeInterval) -> LoggedHookEvent {
            LoggedHookEvent(taskId: task.id, attribution: .primary,
                event: HookEvent(receivedAt: t0.addingTimeInterval(s), eventName: n, sessionId: "s"))
        }
        let log = [e("Stop", -300), e("UserPromptSubmit", -200), e("Stop", 0)]
        c.expireStale(tasks: [task], eventsFor: { _ in log }, now: t0.addingTimeInterval(30))
        #expect(c.queue.entries.first { $0.id == oldId }?.status == .expired)
        #expect(c.queue.entries.first { $0.id == fresh }?.status == .pending)
        #expect(ProposalCenter(directory: dir).queue.entries.first { $0.id == oldId }?.status == .expired)
    }

    @Test func expireStaleDoesNotExpireWhatItCannotJudge() throws {
        let dir = dir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (c, id) = try center(dir)
        c.expireStale(tasks: [task], eventsFor: { _ in [] }, now: t0)   // log empty: unknown turn
        #expect(c.queue.entries.first { $0.id == id }?.status == .pending, "unknown ≠ stale")
    }

    @Test func recentResolvedListsSentExpiredAndFailedNewestFirstAndOnlyForThatTask() throws {
        let dir = dir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (c, id) = try center(dir, text: "first")
        let d = FakeDelivery()
        #expect(confirm(c, id, d) == .sent)
        try ProposalInbox(configDirectory: dir).enqueue(ProposalDraft(kind: .send, task: "a", text: "second", reason: "r", basedOn: t0))
        c.drain(tasks: [task], now: t0)
        let id2 = try #require(c.pending(for: task.id).first?.id)
        d.typeResult = false
        _ = confirm(c, id2, d, now: 70)
        let resolved = c.recentResolved(for: task.id)
        #expect(resolved.map(\.text) == ["second", "first"])
        #expect(resolved.map(\.status) == [.failed, .sent])
        #expect(c.recentResolved(for: UUID()).isEmpty)
    }
}
