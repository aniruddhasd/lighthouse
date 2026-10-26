import Foundation
import Testing
import LighthouseAdapter
import LighthouseAppCore
import LighthouseTaskEngine
@testable import LighthouseSupervisor

private struct FixedSource: SupervisorSnapshotSource {
    let result: Result<SupervisorSnapshot, Error>
    func snapshot() throws -> SupervisorSnapshot { try result.get() }
}

final class RecordingSubmitter: ProposalSubmitting, @unchecked Sendable {
    private let lock = NSLock()
    private var drafts: [ProposalDraft] = []
    var failWith: Error?
    var submitted: [ProposalDraft] { lock.lock(); defer { lock.unlock() }; return drafts }
    func submit(_ draft: ProposalDraft) throws {
        if let failWith { throw failWith }
        lock.lock(); drafts.append(draft); lock.unlock()
    }
}

@Suite("MCPServer")
struct MCPServerTests {
    private func server(
        _ tasks: [TaskRecord] = [], _ events: [LoggedHookEvent] = [],
        proposals: [Proposal] = [], submitter: RecordingSubmitter = RecordingSubmitter()
    ) -> MCPServer {
        MCPServer(
            source: FixedSource(result: .success(SupervisorSnapshot(
                tasks: tasks, events: events, proposals: proposals, now: Date(timeIntervalSince1970: 100)))),
            submitter: submitter)
    }

    private func reply(_ s: MCPServer, _ line: String) throws -> [String: Any] {
        let out = try #require(s.handle(line: line), "expected a response for: \(line)")
        return try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    // MARK: Hostile / broken input first

    @Test func malformedJSONYieldsParseErrorWithNullId() throws {
        let r = try reply(server(), "{ not json")
        #expect((r["error"] as? [String: Any])?["code"] as? Int == -32700)
        #expect(r["id"] is NSNull)
    }

    @Test func nonObjectAndEmptyInputDoNotCrash() {
        let s = server()
        for line in ["", "   ", "[]", "42", "\"str\"", "null", String(repeating: "{", count: 10_000)] {
            _ = s.handle(line: line)
        }
    }

    @Test func randomBytesNeverCrash() {
        let s = server()
        var g = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let bytes = (0..<Int.random(in: 0..<200, using: &g)).map { _ in UInt8.random(in: 0...255, using: &g) }
            _ = s.handle(line: String(decoding: bytes, as: UTF8.self))
        }
    }

    @Test func unknownMethodIsMethodNotFound() throws {
        let r = try reply(server(), #"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#)
        #expect((r["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(r["id"] as? Int == 1)
    }

    @Test func notificationsGetNoResponse() {
        #expect(server().handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(server().handle(line: #"{"jsonrpc":"2.0","method":"whatever"}"#) == nil)
    }

    @Test func unknownToolIsAToolErrorNotACrash() throws {
        let r = try reply(server(), #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"rm_rf","arguments":{}}}"#)
        #expect((r["result"] as? [String: Any])?["isError"] as? Bool == true)
    }

    @Test func missingAndWronglyTypedArgumentsAreToolErrors() throws {
        let s = server()
        for args in [#"{}"#, #"{"task":5}"#, #"{"task":null}"#, #"{"task":["a"]}"#, #"{"task":"a","limit":"ten"}"#] {
            let r = try reply(s, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"recent_events","arguments":\#(args)}}"#)
            #expect((r["result"] as? [String: Any])?["isError"] as? Bool == true, "args \(args)")
        }
        let noArgs = try reply(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"last_turn"}}"#)
        #expect((noArgs["result"] as? [String: Any])?["isError"] as? Bool == true)
    }

    @Test func unreadableStateIsAToolErrorNotACrash() throws {
        struct Boom: Error {}
        let s = MCPServer(source: FixedSource(result: .failure(Boom())), submitter: RecordingSubmitter())
        let r = try reply(s, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_tasks","arguments":{}}}"#)
        #expect((r["result"] as? [String: Any])?["isError"] as? Bool == true)
    }

    // MARK: Protocol shape

    @Test func initializeEchoesProtocolVersionAndAdvertisesToolsOnly() throws {
        let r = try reply(server(), #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
        let result = try #require(r["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-03-26")
        let caps = try #require(result["capabilities"] as? [String: Any])
        #expect(Set(caps.keys) == ["tools"])
    }

    /// The tool surface is a security boundary: exactly these seven. The three read
    /// tools write nothing; the three `propose_*`/`hold`/`ask_user` tools can only drop
    /// an inbox file (nothing is sent anywhere); `list_proposals` reads the queue.
    @Test func toolsListIsExactlyTheSevenKnownTools() throws {
        let r = try reply(server(), #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let tools = try #require((r["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(Set(tools.compactMap { $0["name"] as? String }) == [
            "list_tasks", "recent_events", "last_turn",
            "propose_send", "hold", "ask_user", "list_proposals",
        ])
        for tool in tools {
            let desc = try #require(tool["description"] as? String)
            #expect(desc.localizedCaseInsensitiveContains("untrusted") || tool["name"] as? String != "last_turn")
            #expect(tool["inputSchema"] != nil)
        }
    }

    @Test func ping() throws {
        let r = try reply(server(), #"{"jsonrpc":"2.0","id":9,"method":"ping"}"#)
        #expect(r["result"] != nil && r["id"] as? Int == 9)
    }

    @Test func listTasksCallReturnsJSONTextContent() throws {
        let t = TaskRecord(name: "alpha", branch: "b", adapterKind: "c", sessionRef: "s", supervised: true, workspaces: [])
        let r = try reply(server([t]), #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_tasks","arguments":{}}}"#)
        let result = try #require(r["result"] as? [String: Any])
        #expect(result["isError"] as? Bool != true)
        let text = try #require(((result["content"] as? [[String: Any]])?.first)?["text"] as? String)
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(((payload["tasks"] as? [[String: Any]])?.first)?["name"] as? String == "alpha")
    }

    // MARK: Proposal tools (slice 2)

    private let alpha = TaskRecord(name: "alpha", branch: "b", adapterKind: "c", sessionRef: "s", supervised: true, workspaces: [])

    private func call(_ s: MCPServer, _ name: String, _ args: String) throws -> (isError: Bool, text: String) {
        let r = try reply(s, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(args)}}"#)
        let result = try #require(r["result"] as? [String: Any])
        let text = try #require(((result["content"] as? [[String: Any]])?.first)?["text"] as? String)
        return (result["isError"] as? Bool == true, text)
    }

    @Test func proposeSendWithBadInputIsRejectedAndNeverSubmitted() throws {
        let sub = RecordingSubmitter(); let s = server([alpha], submitter: sub)
        let cases = [
            #"{"task":"alpha","text":"hi\nthere","reason":"r","based_on":"2026-10-23T08:00:00Z"}"#,   // newline
            #"{"task":"alpha","text":"hi","reason":"r"}"#,                                              // no based_on
            #"{"task":"alpha","text":"hi","reason":"r","based_on":"yesterday"}"#,                       // bad date
            #"{"task":"nope","text":"hi","reason":"r","based_on":"2026-10-23T08:00:00Z"}"#,            // unknown task
            #"{"task":"alpha","text":5,"reason":"r","based_on":"2026-10-23T08:00:00Z"}"#,              // wrong type
            #"{"task":"alpha","text":"hi","based_on":"2026-10-23T08:00:00Z"}"#,                         // no reason
            #"{}"#,
        ]
        for args in cases {
            let out = try call(s, "propose_send", args)
            #expect(out.isError, "should be an error: \(args)")
        }
        #expect(sub.submitted.isEmpty, "nothing invalid may reach the inbox")
    }

    @Test func unsupervisedTaskIsRefusedLikeAnUnknownOne() throws {
        let hidden = TaskRecord(name: "hidden", branch: "b", adapterKind: "c", sessionRef: "s", supervised: false, workspaces: [])
        let s = server([hidden])
        let a = try call(s, "hold", #"{"task":"hidden","reason":"r"}"#)
        let b = try call(s, "hold", #"{"task":"nope","reason":"r"}"#)
        #expect(a.isError && b.isError)
        #expect(a.text.replacingOccurrences(of: "hidden", with: "X") == b.text.replacingOccurrences(of: "nope", with: "X"))
    }

    @Test func validProposeSendIsSubmittedAndReportedAsQueuedNotSent() throws {
        let sub = RecordingSubmitter(); let s = server([alpha], submitter: sub)
        let out = try call(s, "propose_send", #"{"task":"alpha","text":"go ahead with change 1","reason":"turn finished cleanly","based_on":"2026-10-23T08:00:00Z"}"#)
        #expect(!out.isError)
        #expect(out.text.localizedCaseInsensitiveContains("queued"))
        #expect(out.text.contains("Nothing has been sent"), "the reply must disclaim any send")
        #expect(!out.text.contains("\"status\":\"sent\"") && !out.text.contains("\"status\":\"accepted\""))
        let d = try #require(sub.submitted.first)
        #expect(d.kind == .send && d.task == "alpha" && d.text == "go ahead with change 1" && d.basedOn != nil)
    }

    @Test func holdAndAskUserAreSubmittedWithTheirKinds() throws {
        let sub = RecordingSubmitter(); let s = server([alpha], submitter: sub)
        #expect(!(try call(s, "hold", #"{"task":"alpha","reason":"VPN is down; do not advance"}"#)).isError)
        #expect(!(try call(s, "ask_user", #"{"task":"alpha","question":"Rebase or merge?"}"#)).isError)
        #expect(sub.submitted.map(\.kind) == [.hold, .askUser])
        #expect(sub.submitted[0].text == "VPN is down; do not advance")
    }

    @Test func aFailingInboxIsAToolErrorNotACrash() throws {
        struct Disk: Error {}
        let sub = RecordingSubmitter(); sub.failWith = Disk()
        let out = try call(server([alpha], submitter: sub), "hold", #"{"task":"alpha","reason":"r"}"#)
        #expect(out.isError)
    }

    @Test func listProposalsShowsTheQueueNewestFirstAndFiltersByTask() throws {
        let other = TaskRecord(name: "beta", branch: "b", adapterKind: "c", sessionRef: "s2", supervised: true, workspaces: [])
        func p(_ t: TaskRecord, _ text: String, at: TimeInterval, status: ProposalStatus = .pending, why: String? = nil) -> Proposal {
            Proposal(id: UUID(), taskId: t.id, taskRef: t.name, kind: .send, text: text, reason: "r",
                     basedOn: nil, createdAt: Date(timeIntervalSince1970: at), status: status, rejectionReason: why)
        }
        let s = server([alpha, other], proposals: [
            p(alpha, "old", at: 1), p(other, "theirs", at: 2), p(alpha, "new", at: 3, status: .rejected, why: "too long"),
        ])
        let all = try call(s, "list_proposals", "{}")
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(all.text.utf8)) as? [String: Any])
        let items = try #require(payload["proposals"] as? [[String: Any]])
        #expect(items.map { $0["text"] as? String } == ["new", "theirs", "old"])
        #expect(items[0]["rejection_reason"] as? String == "too long")

        let mine = try call(s, "list_proposals", #"{"task":"alpha"}"#)
        let mineItems = try #require((try JSONSerialization.jsonObject(with: Data(mine.text.utf8)) as? [String: Any])?["proposals"] as? [[String: Any]])
        #expect(mineItems.map { $0["text"] as? String } == ["new", "old"])
        #expect(try call(s, "list_proposals", #"{"task":"ghost"}"#).isError)
    }

    @Test func unreadableProposalQueueIsReportedNotHidden() throws {
        let s = MCPServer(
            source: FixedSource(result: .success(SupervisorSnapshot(
                tasks: [alpha], events: [], proposals: [], proposalsError: "corrupt"))),
            submitter: RecordingSubmitter())
        #expect(try call(s, "list_proposals", "{}").isError)
        #expect(!(try call(s, "list_tasks", "{}")).isError, "a bad queue must not take the read tools down")
    }

    /// A just-queued submission sits in the inbox until the app drains it (a couple of
    /// seconds). Without a count the supervisor sees an empty queue right after
    /// proposing and may propose the same thing again.
    @Test func listProposalsSaysHowManySubmissionsAreStillAwaitingTheApp() throws {
        let s = MCPServer(
            source: FixedSource(result: .success(SupervisorSnapshot(
                tasks: [alpha], events: [], proposals: [], proposalsAwaitingApp: 2))),
            submitter: RecordingSubmitter())
        let out = try call(s, "list_proposals", "{}")
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(out.text.utf8)) as? [String: Any])
        #expect(payload["awaiting_app"] as? Int == 2)
    }

    @Test func listProposalsExposesOutcomesSoTheSupervisorCanSeeWhatBecameOfThem() throws {
        let p = Proposal(id: UUID(), taskId: alpha.id, taskRef: "alpha", kind: .send, text: "go on", reason: "r",
                         basedOn: nil, createdAt: Date(timeIntervalSince1970: 1), status: .expired,
                         rejectionReason: nil, resolvedAt: Date(timeIntervalSince1970: 9), resolutionNote: "Overtaken by a newer event")
        let out = try call(server([alpha], proposals: [p]), "list_proposals", "{}")
        let item = try #require(((try JSONSerialization.jsonObject(with: Data(out.text.utf8)) as? [String: Any])?["proposals"] as? [[String: Any]])?.first)
        #expect(item["status"] as? String == "expired")
        #expect(item["resolution_note"] as? String == "Overtaken by a newer event")
        #expect(item["resolved_at"] != nil)
    }
}
