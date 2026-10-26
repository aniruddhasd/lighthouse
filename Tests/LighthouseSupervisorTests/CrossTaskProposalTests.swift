import Foundation
import LighthouseAdapter
import LighthouseAppCore
import LighthouseTaskEngine
import Testing
@testable import LighthouseSupervisor

/// The proposal side of "when alpha finishes, tell beta": naming a source task, and the
/// confirm/expiry paths that use it. Failure modes first.
@MainActor
@Suite("Cross-task proposals", .serialized)
struct CrossTaskProposalTests {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)
    private let alpha = TaskRecord(name: "alpha", branch: "b", adapterKind: "c", sessionRef: "sa", supervised: true, workspaces: [])
    private let beta = TaskRecord(name: "beta", branch: "b", adapterKind: "c", sessionRef: "sb", supervised: true, workspaces: [])
    private var off: TaskRecord {
        TaskRecord(name: "off", branch: "b", adapterKind: "c", sessionRef: "so", supervised: false, workspaces: [])
    }

    private func dir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("lh-xt-\(UUID().uuidString.prefix(8))") }
    private func ev(_ task: TaskRecord, _ name: String, at offset: TimeInterval) -> LoggedHookEvent {
        LoggedHookEvent(taskId: task.id, attribution: .primary, event: HookEvent(
            receivedAt: t0.addingTimeInterval(offset), eventName: name, sessionId: "s"))
    }
    private func draft(task: String = "beta", source: String? = "alpha", kind: ProposalKind = .send) -> ProposalDraft {
        ProposalDraft(kind: kind, task: task, text: "please start the review", reason: "alpha finished",
                      basedOn: t0, sourceTask: source)
    }
    private var alphaDone: [LoggedHookEvent] { [ev(alpha, "UserPromptSubmit", at: -60), ev(alpha, "Stop", at: 0)] }
    private var betaIdle: [LoggedHookEvent] { [ev(beta, "Stop", at: -300)] }

    // MARK: Validation

    @Test func aSourceMustBeASupervisedTaskThatExists() {
        for bad in ["ghost", "off", "  "] where bad != "  " {
            #expect(throws: ProposalRejection.self) {
                try ProposalValidator.validate(draft(source: bad), tasks: [alpha, beta, off])
            }
        }
    }

    @Test func onlyASendMayNameASource() {
        #expect(throws: ProposalRejection.self) {
            try ProposalValidator.validate(draft(kind: .hold), tasks: [alpha, beta])
        }
    }

    @Test func aSourceEqualToTheTargetOrBlankIsNoSource() throws {
        #expect(try ProposalValidator.validate(draft(source: "beta"), tasks: [alpha, beta]).sourceTaskId == nil)
        #expect(try ProposalValidator.validate(draft(source: "   "), tasks: [alpha, beta]).sourceTaskId == nil)
        #expect(try ProposalValidator.validate(draft(source: nil), tasks: [alpha, beta]).sourceTaskId == nil)
        #expect(try ProposalValidator.validate(draft(), tasks: [alpha, beta]).sourceTaskId == alpha.id)
    }

    @Test func theQueueRecordsTheSourceAndDoesNotMergeDifferentSources() {
        var q = ProposalQueue()
        let a = q.ingest(draft(), tasks: [alpha, beta], now: t0)
        #expect(a.status == .pending && a.sourceTaskId == alpha.id && a.sourceTaskRef == "alpha")
        let same = q.ingest(draft(), tasks: [alpha, beta], now: t0)
        #expect(same.id == a.id, "an identical proposal is not added twice")
        let other = q.ingest(draft(source: nil), tasks: [alpha, beta], now: t0)
        #expect(other.id != a.id, "same text but a different source is a different proposal")
    }

    @Test func aRejectedProposalStillShowsWhichSourceItNamed() {
        var q = ProposalQueue()
        let r = q.ingest(draft(source: "off"), tasks: [alpha, beta, off], now: t0)
        #expect(r.status == .rejected && r.sourceTaskRef == "off")
    }

    @Test func aQueueFileWrittenBeforeSourcesExistedStillLoads() throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        var q = ProposalQueue()
        q.ingest(draft(source: nil), tasks: [alpha, beta], now: t0)
        try ProposalStore(directory: d).save(q)
        let url = ProposalStore(directory: d).url
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.split(separator: "\n").filter { !$0.contains("sourceTask") }.joined(separator: "\n")
        try Data(text.utf8).write(to: url)
        #expect(try ProposalStore(directory: d).load().entries.count == 1)
    }

    // MARK: The MCP tool

    @Test func proposeSendPassesTheSourceTaskThrough() throws {
        let submitter = RecordingSubmitter()
        let server = MCPServer(
            source: FixedTasks(tasks: [alpha, beta]), submitter: submitter)
        let call = """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"propose_send","arguments":{"task":"beta","source_task":"alpha","text":"start the review","reason":"done","based_on":"2026-10-26T08:00:00Z"}}}
        """
        _ = server.handle(line: call)
        #expect(submitter.submitted.first?.sourceTask == "alpha")
        #expect(submitter.submitted.first?.task == "beta")
    }

    @Test func aSourceThatIsNotSupervisedIsRefusedAtTheTool() throws {
        let submitter = RecordingSubmitter()
        let server = MCPServer(source: FixedTasks(tasks: [off, beta]), submitter: submitter)
        let call = """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"propose_send","arguments":{"task":"beta","source_task":"off","text":"start","reason":"done","based_on":"2026-10-26T08:00:00Z"}}}
        """
        let out = try #require(server.handle(line: call))
        #expect(out.contains("isError") && submitter.submitted.isEmpty)
    }

    @Test func theToolSchemaAdvertisesSourceTaskAsOptional() throws {
        let tool = try #require(MCPServer.tools.first { $0["name"] as? String == "propose_send" })
        let schema = try #require(tool["inputSchema"] as? [String: Any])
        #expect((schema["properties"] as? [String: Any])?["source_task"] != nil)
        #expect(!((schema["required"] as? [String]) ?? []).contains("source_task"))
    }

    // MARK: Confirm and expiry through the center

    private func center(_ d: URL) throws -> (ProposalCenter, UUID) {
        try ProposalInbox(configDirectory: d).enqueue(draft())
        let c = ProposalCenter(directory: d)
        c.drain(tasks: [alpha, beta], now: t0)
        return (c, try #require(c.queue.entries.first).id)
    }

    @Test func confirmTypesIntoTheTargetNotTheSource() throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let (c, id) = try center(d)
        let fake = FakeDelivery()
        let out = c.confirm(id, task: beta, events: betaIdle, source: alpha, sourceEvents: alphaDone,
                            delivery: fake, now: t0.addingTimeInterval(60))
        #expect(out == .sent)
        #expect(fake.typed.count == 1 && fake.typed[0].0 == beta.id && fake.typed[0].1 == "please start the review")
    }

    @Test func aBusyTargetRefusesAndTypesNothingAndKeepsItPending() throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let (c, id) = try center(d)
        let fake = FakeDelivery()
        let out = c.confirm(id, task: beta, events: betaIdle + [ev(beta, "UserPromptSubmit", at: 10)],
                            source: alpha, sourceEvents: alphaDone, delivery: fake, now: t0.addingTimeInterval(60))
        if case .refused = out {} else { Issue.record("expected a refusal, got \(out)") }
        #expect(fake.typed.isEmpty)
        #expect(c.queue.entries.first?.status == .pending, "a busy target is retryable, not expired")
    }

    @Test func aMissingSourceTaskOrItsEventsRefusesAtConfirm() throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let (c, id) = try center(d)
        let fake = FakeDelivery()
        let noEvents = c.confirm(id, task: beta, events: betaIdle, source: alpha, sourceEvents: nil,
                                 delivery: fake, now: t0.addingTimeInterval(60))
        if case .refused = noEvents {} else { Issue.record("fail closed without source events: \(noEvents)") }
        let noTask = c.confirm(id, task: beta, events: betaIdle, source: nil, sourceEvents: alphaDone,
                               delivery: fake, now: t0.addingTimeInterval(60))
        if case .expired = noTask {} else { Issue.record("a vanished source task expires it: \(noTask)") }
        #expect(fake.typed.isEmpty)
    }

    @Test func expireStaleRetiresOnTheSourceMovingOnButNotOnABusyTarget() throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let (c, id) = try center(d)
        let busyTarget = betaIdle + [ev(beta, "UserPromptSubmit", at: 10)]
        c.expireStale(tasks: [alpha, beta], eventsFor: { $0 == alpha.id ? alphaDone : busyTarget }, now: t0.addingTimeInterval(60))
        #expect(c.queue.entries.first { $0.id == id }?.status == .pending, "a busy target must not retire it")
        c.expireStale(tasks: [alpha, beta],
                      eventsFor: { $0 == alpha.id ? alphaDone + [ev(alpha, "UserPromptSubmit", at: 20)] : busyTarget },
                      now: t0.addingTimeInterval(60))
        #expect(c.queue.entries.first { $0.id == id }?.status == .expired)
    }

    @Test func expireStaleLeavesAProposalWhoseSourceTurnIsUnknownAlone() throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let (c, id) = try center(d)
        c.expireStale(tasks: [alpha, beta], eventsFor: { _ in [] }, now: t0.addingTimeInterval(60))
        #expect(c.queue.entries.first { $0.id == id }?.status == .pending, "unknown is not stale")
    }
}

private struct FixedTasks: SupervisorSnapshotSource {
    let tasks: [TaskRecord]
    func snapshot() throws -> SupervisorSnapshot { SupervisorSnapshot(tasks: tasks, events: []) }
}
