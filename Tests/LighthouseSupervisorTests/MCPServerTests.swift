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

@Suite("MCPServer")
struct MCPServerTests {
    private func server(_ tasks: [TaskRecord] = [], _ events: [LoggedHookEvent] = []) -> MCPServer {
        MCPServer(source: FixedSource(result: .success(
            SupervisorSnapshot(tasks: tasks, events: events, now: Date(timeIntervalSince1970: 100)))))
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
        let s = MCPServer(source: FixedSource(result: .failure(Boom())))
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

    /// The tool surface is a security boundary: exactly these three, all read-only.
    @Test func toolsListIsExactlyTheThreeReadOnlyTools() throws {
        let r = try reply(server(), #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let tools = try #require((r["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(Set(tools.compactMap { $0["name"] as? String }) == ["list_tasks", "recent_events", "last_turn"])
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
}
