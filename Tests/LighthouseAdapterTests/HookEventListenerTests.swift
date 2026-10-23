import Foundation
import Testing
import LighthouseGit
@testable import LighthouseAdapter

/// Raw test client for sending arbitrary (including deliberately broken)
/// bytes to the listener — the hostile-input harness.
private enum RawSocketClient {
    static func send(_ bytes: Data, to socketPath: String, awaitResponse: Bool = true, timeoutSeconds: Int = 5) -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return "" }
        defer { close(fd) }
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: Array(socketPath.utf8))
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return "" }
        bytes.withUnsafeBytes { raw in
            _ = write(fd, raw.baseAddress, raw.count)
        }
        guard awaitResponse else { return "" }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let n = recv(fd, &buffer, buffer.count, 0)
        return n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : ""
    }

    static func post(json: String, to socketPath: String) -> String {
        let body = Data(json.utf8)
        var request = Data("POST /lighthouse-hook HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        request.append(body)
        return send(request, to: socketPath)
    }

    /// Opens a connection and drips `dripCount` bytes one at a time with
    /// `intervalMs` between each — never completing the request. Each write
    /// resets the server's per-recv timeout, so only a WHOLE-REQUEST deadline
    /// can close it. Returns the (400) response once the server drops us, or
    /// "" if it never did. Blocks up to a few seconds.
    static func dripForever(to socketPath: String, dripCount: Int, intervalMs: UInt64) -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return "" }
        defer { close(fd) }
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: Array(socketPath.utf8))
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return "" }
        // A valid partial header start, then a byte at a time — never the
        // terminating \r\n\r\n.
        _ = "POST / HTTP/1.1\r\n".withCString { write(fd, $0, strlen($0)) }
        for _ in 0..<dripCount {
            usleep(useconds_t(intervalMs * 1000))
            var byte: UInt8 = 0x58 // 'X'
            if write(fd, &byte, 1) <= 0 { break } // server closed → done dripping
        }
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = recv(fd, &buffer, buffer.count, 0)
        return n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : ""
    }
}

private final class DropBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reasons: [String] = []
    func add(_ r: String) { lock.lock(); reasons.append(r); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return reasons.count }
}

@Suite("HookEventListener", .serialized)
final class HookEventListenerTests {
    private let directory: URL
    private let listener: HookEventListener

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lh-sock-\(UUID().uuidString.prefix(8))", isDirectory: true)
        listener = HookEventListener(directory: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func payload(session: String, event: String, notificationType: String? = nil) -> String {
        var fields = [
            "\"session_id\": \"\(session)\"",
            "\"hook_event_name\": \"\(event)\"",
            "\"cwd\": \"/tmp/x\"",
        ]
        if let notificationType {
            fields.append("\"notification_type\": \"\(notificationType)\"")
        }
        return "{" + fields.joined(separator: ", ") + "}"
    }

    /// Waits for the actor to drain pending payload tasks.
    private func waitForDrops(atLeast count: Int) async throws {
        for _ in 0..<100 {
            if await listener.droppedCount >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("expected at least \(count) drops, got \(await listener.droppedCount)")
    }

    // MARK: Broken input first

    @Test func socketIsOwnerOnly() async throws {
        let url = try await listener.start()
        defer { listener.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.uint16Value & 0o777 == 0o600)
    }

    @Test func oversizedBodyRejectedAndListenerSurvives() async throws {
        let url = try await listener.start()
        defer { listener.stop() }

        let huge = String(repeating: "A", count: HookEventListener.maxBodyBytes + 1)
        let response = RawSocketClient.post(json: huge, to: url.path)
        #expect(response.contains("400"))
        try await waitForDrops(atLeast: 1)

        // Still alive: a good payload right after is accepted.
        let good = RawSocketClient.post(
            json: payload(session: "s1", event: "Stop"), to: url.path)
        #expect(good.contains("200"))
    }

    @Test func oversizedHeadersRejected() async throws {
        let url = try await listener.start()
        defer { listener.stop() }
        let request = "POST / HTTP/1.1\r\nX-Junk: " + String(repeating: "j", count: 10_000)
        let response = RawSocketClient.send(Data(request.utf8), to: url.path)
        #expect(response.contains("400"))
    }

    @Test func truncatedRequestRejected() async throws {
        let url = try await listener.start()
        defer { listener.stop() }
        // Claims 100 bytes, sends 5, closes.
        let request = "POST / HTTP/1.1\r\nContent-Length: 100\r\n\r\nhello"
        // The server gives a stalled body 5s before rejecting; outlast it.
        let response = RawSocketClient.send(Data(request.utf8), to: url.path, timeoutSeconds: 8)
        #expect(response.contains("400"))
        try await waitForDrops(atLeast: 1)
    }

    @Test func nonPostAndMissingContentLengthRejected() async throws {
        let url = try await listener.start()
        defer { listener.stop() }
        #expect(RawSocketClient.send(
            Data("GET / HTTP/1.1\r\n\r\n".utf8), to: url.path).contains("400"))
        #expect(RawSocketClient.send(
            Data("POST / HTTP/1.1\r\n\r\n{}".utf8), to: url.path).contains("400"))
    }

    @Test func malformedJSONBodyDroppedWithoutCrash() async throws {
        let url = try await listener.start()
        defer { listener.stop() }
        let response = RawSocketClient.post(json: "{{{{ not json", to: url.path)
        #expect(response.contains("200")) // framing fine; payload dropped later
        try await waitForDrops(atLeast: 1)
        #expect(await listener.lastDropReason?.contains("unparseable") == true)
    }

    @Test func payloadMissingSessionIdOrEventNameDropped() async throws {
        let url = try await listener.start()
        defer { listener.stop() }
        _ = RawSocketClient.post(json: "{\"hook_event_name\": \"Stop\"}", to: url.path)
        _ = RawSocketClient.post(json: "{\"session_id\": \"s\"}", to: url.path)
        _ = RawSocketClient.post(json: "[1,2,3]", to: url.path)
        try await waitForDrops(atLeast: 3)
        #expect(await listener.lastDropReason?.contains("unparseable") == true)
    }

    @Test func hostileStringsInEveryFieldAreInertData() async throws {
        let url = try await listener.start()
        defer { listener.stop() }
        let evil = "$(touch /tmp/lighthouse-sock-pwned); `id`; ;|&"
        let json = """
        {"session_id": "\(evil.replacingOccurrences(of: "\"", with: ""))",
         "hook_event_name": "Stop", "cwd": "; reboot", "message": "'; drop table"}
        """
        _ = RawSocketClient.post(json: json, to: url.path)
        // Hostile strings are inert data: parsed as a normal event, never executed.
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: "/tmp/lighthouse-sock-pwned"))
    }

    @Test func socketPathTooLongFailsLoud() async throws {
        let deep = FileManager.default.temporaryDirectory
            .appendingPathComponent(String(repeating: "d", count: 120), isDirectory: true)
        let long = HookEventListener(directory: deep)
        await #expect {
            try await long.start()
        } throws: { error in
            guard case .socketPathTooLong = error as? HookSocketError else { return false }
            return true
        }
    }

    @Test func doubleStartThrows() async throws {
        _ = try await listener.start()
        defer { listener.stop() }
        await #expect {
            try await self.listener.start()
        } throws: { error in
            error as? HookSocketError == .alreadyStarted
        }
    }

    @Test func dropCallbackFiresForEveryDrop() async throws {
        let seen = DropBox()
        let l = HookEventListener(
            directory: directory.appendingPathComponent("cb"), onDrop: { seen.add($0) })
        let url = try await l.start()
        defer { l.stop() }
        _ = RawSocketClient.post(json: "not json", to: url.path)
        _ = RawSocketClient.post(json: "[1]", to: url.path)
        for _ in 0..<100 where seen.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(seen.count == 2)
    }

    // MARK: Event delivery

    @Test func eventsArriveParsedAndInSendOrder() async throws {
        let url = try await listener.start()
        defer { listener.stop() }
        let stream = await listener.events()

        _ = RawSocketClient.post(
            json: payload(session: "sess-42", event: "UserPromptSubmit"), to: url.path)
        _ = RawSocketClient.post(
            json: payload(session: "sess-42", event: "Notification",
                          notificationType: "permission_prompt"),
            to: url.path)
        _ = RawSocketClient.post(
            json: payload(session: "sess-42", event: "Stop"), to: url.path)

        var received: [HookEvent] = []
        for await event in stream {
            received.append(event)
            if received.count == 3 { break }
        }
        #expect(received.map(\.eventName) == ["UserPromptSubmit", "Notification", "Stop"])
        #expect(received.allSatisfy { $0.sessionId == "sess-42" })
        #expect(received[1].notificationType == "permission_prompt")
    }

    /// A burst of back-to-back deliveries must surface in send order (one
    /// ordered consumer; a per-request `Task` had undefined scheduling order).
    @Test func burstOfDeliveriesArrivesInSendOrder() async throws {
        let url = try await listener.start()
        defer { listener.stop() }
        let count = 20
        let stream = await listener.events()

        for index in 0..<count {
            _ = RawSocketClient.post(
                json: payload(session: "burst-\(index)", event: "Stop"), to: url.path)
        }

        var received: [String] = []
        for await event in stream {
            received.append(event.sessionId)
            if received.count == count { break }
        }
        #expect(received == (0..<count).map { "burst-\($0)" })
    }

    @Test func deliveryViaRealCurlMatchesProductionHookCommand() async throws {
        // Exactly the transport the installed hook uses: curl --unix-socket
        // with --data-binary @- reading the payload from stdin.
        let url = try await listener.start()
        defer { listener.stop() }
        let stream = await listener.events()

        let handler = HookInstaller.handler(socketPath: url)
        let args = try #require(handler["args"] as? [String])
        let body = payload(session: "curl-sess", event: "Stop")
        let result = try await ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf %s " + ShellQuoter.quote(body) + " | /usr/bin/curl " + ShellQuoter.command(args)],
            workingDirectory: FileManager.default.temporaryDirectory)
        #expect(result.exitCode == 0)

        for await event in stream {
            #expect(event.sessionId == "curl-sess" && event.eventName == "Stop")
            break
        }
    }
}

/// Slow-loris hardening: a same-UID client dripping bytes must be dropped by
/// the whole-request deadline, and the listener must immediately serve the
/// next connection. Uses a short injected deadline so the test is fast.
@Suite("HookEventListener slow-loris deadline", .serialized)
final class HookEventDeadlineTests {
    private let directory: URL
    private let listener: HookEventListener

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lh-sock-dl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        listener = HookEventListener(
            directory: directory, requestDeadline: 1)
    }

    deinit {
        listener.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private func payload(session: String) -> String {
        "{\"session_id\": \"\(session)\", \"hook_event_name\": \"Stop\", \"cwd\": \"/x\"}"
    }

    @Test func slowClientDroppedThenNextConnectionServed() async throws {
        let url = try await listener.start()
        defer { listener.stop() }

        // Drip for ~3s against a 1s deadline: never completes the request.
        let response = RawSocketClient.dripForever(to: url.path, dripCount: 30, intervalMs: 100)
        #expect(response.contains("400"), "slow client not dropped: \(response.debugDescription)")

        // The drop reason names the deadline.
        for _ in 0..<50 where await listener.lastDropReason?.contains("deadline") != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await listener.lastDropReason?.contains("deadline") == true)

        // The listener immediately serves the next connection.
        let ok = RawSocketClient.post(json: payload(session: "after"), to: url.path)
        #expect(ok.contains("200"), "listener did not recover: \(ok.debugDescription)")
    }
}
