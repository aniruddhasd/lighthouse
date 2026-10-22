import Foundation

public enum HookSocketError: Error, Sendable, Equatable {
    /// sun_path on macOS holds ~104 bytes — a too-long container path must
    /// fail loudly at start, not truncate silently.
    case socketPathTooLong(path: String, limit: Int)
    case systemCallFailed(call: String, errno: Int32)
    case alreadyStarted
}

/// Listens on a Unix domain socket for hook deliveries (curl POSTs the hook's
/// stdin JSON over the socket). Spec §8 posture: the socket is 0600
/// owner-only, and every payload is hostile until proven otherwise —
/// size-capped, schema-validated by `ClaudeHookParser`, never executed, never
/// interpolated. Malformed input and unknown sessions are counted and
/// dropped; the listener never crashes and never blocks an agent (hooks run
/// async with their own timeout).
public actor HookEventListener {
    /// Hard caps, documented here: 8 KiB of HTTP headers, 64 KiB of body.
    /// Real payloads observed live are well under 8 KiB; 64 KiB leaves room
    /// for a large last_assistant_message without accepting unbounded input.
    public static let maxHeaderBytes = 8 * 1024
    public static let maxBodyBytes = 64 * 1024
    /// Whole-request wall-clock deadline. The per-recv SO_RCVTIMEO (5s) only
    /// bounds a SINGLE stalled read — a same-UID client that drips one byte
    /// every few seconds resets it forever and holds the serial accept loop
    /// indefinitely (a slow-loris that stalls event delivery). 10s is far
    /// above any legitimate localhost hook POST (real payloads deliver in
    /// milliseconds) yet closes the drip; enforced across BOTH read loops so
    /// total connection time is bounded regardless of read cadence. Kept as
    /// a simple deadline check — no concurrent-connection redesign needed.
    public static let requestDeadline: TimeInterval = 10
    static let socketFileName = "hooks.sock"

    private let directory: URL
    private let deadlineInterval: TimeInterval
    private let core = ListenerCore()

    /// Observability for tests and debugging — how many payloads were
    /// dropped and why the last one was.
    public private(set) var droppedCount = 0
    public private(set) var lastDropReason: String?

    public nonisolated var socketURL: URL {
        directory.appendingPathComponent(Self.socketFileName)
    }

    /// - Parameters:
    ///   - directory: injected socket location (prod: app container; tests:
    ///     temp dir). Never a shared world-writable path.
    ///   - requestDeadline: whole-request wall-clock cap; the default is the
    ///     production value, overridable so tests can drive it fast.
    public init(
        directory: URL,
        requestDeadline: TimeInterval = HookEventListener.requestDeadline
    ) {
        self.directory = directory
        self.deadlineInterval = requestDeadline
    }

    deinit {
        core.shutdown()
    }

    /// Single-consumer stream of parsed hook events (unattributed — the event log attributes them).
    public func events() -> AsyncStream<HookEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: HookEvent.self)
        core.setContinuation(continuation)
        return stream
    }

    // MARK: - Lifecycle

    @discardableResult
    public func start() throws -> URL {
        let path = socketURL.path

        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard path.utf8.count <= capacity else {
            throw HookSocketError.socketPathTooLong(path: path, limit: capacity)
        }
        guard !core.isStarted else { throw HookSocketError.alreadyStarted }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Owner-only PARENT directory: no other user can traverse to the socket
        // even in the brief window between bind and the explicit chmod below.
        // This is thread-safe (a chmod of one path) — unlike a process-global
        // umask, which would race the whole test/app process's concurrent
        // directory creation and strip the execute bit off unrelated dirs.
        // Fail secure: if we cannot lock the parent to owner-only, do NOT bind
        // the socket inside a potentially world-traversable directory.
        guard chmod(directory.path, 0o700) == 0 else {
            let chmodErrno = errno  // capture before anything can perturb the global
            throw HookSocketError.systemCallFailed(call: "chmod", errno: chmodErrno)
        }
        unlink(path) // stale socket from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HookSocketError.systemCallFailed(call: "socket", errno: errno)
        }

        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8))
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let savedErrno = errno
            close(fd)
            throw HookSocketError.systemCallFailed(call: "bind", errno: savedErrno)
        }
        // Owner-only, before anyone can connect (spec §8).
        guard chmod(path, 0o600) == 0 else {
            let savedErrno = errno
            close(fd)
            unlink(path)
            throw HookSocketError.systemCallFailed(call: "chmod", errno: savedErrno)
        }
        guard listen(fd, 16) == 0 else {
            let savedErrno = errno
            close(fd)
            unlink(path)
            throw HookSocketError.systemCallFailed(call: "listen", errno: savedErrno)
        }

        guard core.markStarted(fd: fd, path: path) else {
            close(fd)
            unlink(path)
            throw HookSocketError.alreadyStarted
        }

        // Single ordered consumer: the accept thread frames requests serially
        // and enqueues them; this one task drains them IN ORDER onto the actor.
        // (Previously each request spawned its own Task, whose scheduling order
        // was undefined — two quick deliveries could process out of order.)
        let (stream, inboxContinuation) = AsyncStream.makeStream(of: Inbound.self)
        core.setInbox(inboxContinuation)
        Task { [weak self] in
            for await item in stream {
                guard let self else { return }
                await self.consume(item)
            }
        }

        // Blocking accept loop on its own thread; connections are handled
        // serially (hook payloads are tiny and rare; a stalled client is
        // bounded by the 5s receive timeout).
        let deadline = deadlineInterval
        let thread = Thread { [weak self, fd] in
            Self.acceptLoop(listenFD: fd, owner: self, deadlineInterval: deadline)
        }
        thread.name = "lighthouse.hook-socket"
        thread.start()

        return socketURL
    }

    /// Drains one inbox item on the actor, in order. Accepted bodies go through
    /// the same `process`/`recordDrop` as before — only the delivery is now
    /// serialized rather than one detached Task per request.
    private func consume(_ item: Inbound) {
        switch item {
        case .body(let data): process(body: data)
        case .drop(let reason): recordDrop(reason)
        }
    }

    /// Synchronous and callable from anywhere (deinit, defer): closes the
    /// socket, unlinks the path, finishes the signal stream. Idempotent.
    public nonisolated func stop() {
        core.shutdown()
    }

    // MARK: - Payload handling (actor-isolated)

    private func process(body: Data) {
        guard let event = ClaudeHookParser.parse(body, receivedAt: Date()) else {
            recordDrop("unparseable payload (\(body.count) bytes)")
            return
        }
        core.yield(event)
    }

    private func recordDrop(_ reason: String) {
        droppedCount += 1
        lastDropReason = reason
        FileHandle.standardError.write(Data("[lighthouse hook-socket] dropped: \(reason)\n".utf8))
    }

    // MARK: - Accept loop + minimal HTTP framing (listener thread)

    private static func acceptLoop(
        listenFD: Int32, owner: HookEventListener?, deadlineInterval: TimeInterval
    ) {
        while true {
            let connection = accept(listenFD, nil, nil)
            guard connection >= 0 else { return } // listener closed

            // A crashed peer must not SIGPIPE the app.
            var noSigpipe: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe,
                       socklen_t(MemoryLayout<Int32>.size))
            // Per-recv timeout, never longer than the whole-request deadline
            // so a short (test) deadline is not masked by a blocked read.
            let recvTimeout = max(1, min(5, Int(deadlineInterval)))
            var timeout = timeval(tv_sec: recvTimeout, tv_usec: 0)
            setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))

            switch readRequest(from: connection, deadlineInterval: deadlineInterval) {
            case .success(let body):
                respond(connection, status: "200 OK")
                // Enqueue in accept order onto the single ordered consumer
                // (core is a Sendable `let`, safe to touch off the actor).
                owner?.core.enqueue(.body(body))
            case .failure(let reason):
                respond(connection, status: "400 Bad Request")
                owner?.core.enqueue(.drop(reason))
            }
            close(connection)
        }
    }

    private enum FrameResult {
        case success(Data)
        case failure(String)
    }

    /// Reads exactly one HTTP request with hard caps. Anything that isn't a
    /// well-formed POST within the limits is rejected — the framing itself
    /// treats input as hostile.
    private static func readRequest(from fd: Int32, deadlineInterval: TimeInterval) -> FrameResult {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let separator = Data("\r\n\r\n".utf8)
        let deadline = Date().addingTimeInterval(deadlineInterval)

        // Headers.
        var headerEnd: Range<Data.Index>? = buffer.range(of: separator)
        while headerEnd == nil {
            if Date() > deadline {
                return .failure("request exceeded \(Int(deadlineInterval))s deadline (slow client, headers)")
            }
            if buffer.count > maxHeaderBytes {
                return .failure("headers exceed \(maxHeaderBytes) bytes")
            }
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else {
                return .failure("connection closed before headers completed")
            }
            buffer.append(contentsOf: chunk[0..<n])
            headerEnd = buffer.range(of: separator)
        }

        let headerData = buffer[buffer.startIndex..<headerEnd!.lowerBound]
        let headerText = String(decoding: headerData, as: UTF8.self)
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first, requestLine.hasPrefix("POST ") else {
            return .failure("not a POST request")
        }

        var contentLength: Int?
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        guard let length = contentLength else {
            return .failure("missing Content-Length")
        }
        guard length >= 0, length <= maxBodyBytes else {
            return .failure("body length \(length) exceeds \(maxBodyBytes) bytes")
        }

        var body = Data(buffer[headerEnd!.upperBound...])
        guard body.count <= length else {
            return .failure("body longer than Content-Length")
        }
        while body.count < length {
            if Date() > deadline {
                return .failure("request exceeded \(Int(deadlineInterval))s deadline (slow client, body)")
            }
            let n = recv(fd, &chunk, min(chunk.count, length - body.count), 0)
            guard n > 0 else {
                return .failure("connection closed mid-body (\(body.count)/\(length) bytes)")
            }
            body.append(contentsOf: chunk[0..<n])
        }
        return .success(body)
    }

    private static func respond(_ fd: Int32, status: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = response.withCString { pointer in
            write(fd, pointer, strlen(pointer))
        }
    }
}

/// One framed unit of work handed from the (background) accept thread to the
/// single ordered consumer on the actor. Routing BOTH accepted bodies and
/// framing-drops through one FIFO is what guarantees in-order processing:
/// spawning a `Task` per request let two quick deliveries (UserPromptSubmit
/// then Stop) land out of order and corrupt the log.
private enum Inbound: Sendable {
    case body(Data)
    case drop(String)
}

/// Lock-guarded socket lifecycle + signal continuation, so shutdown is
/// synchronous, idempotent, and callable from deinit/defer while the accept
/// thread and the actor both stay race-free.
private final class ListenerCore: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var path: String?
    private var started = false
    private var continuation: AsyncStream<HookEvent>.Continuation?
    /// Ordered hand-off from the accept thread to the actor's single consumer.
    private var inbox: AsyncStream<Inbound>.Continuation?

    var isStarted: Bool {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    func markStarted(fd: Int32, path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return false }
        started = true
        self.fd = fd
        self.path = path
        return true
    }

    func setContinuation(_ new: AsyncStream<HookEvent>.Continuation) {
        lock.lock(); defer { lock.unlock() }
        continuation = new
    }

    func setInbox(_ new: AsyncStream<Inbound>.Continuation) {
        lock.lock(); defer { lock.unlock() }
        inbox = new
    }

    /// Order-preserving enqueue from the accept thread. AsyncStream buffers in
    /// yield order and the single consumer drains it serially, so the order a
    /// connection was framed in is the order it is processed in.
    func enqueue(_ item: Inbound) {
        lock.lock(); defer { lock.unlock() }
        inbox?.yield(item)
    }

    func yield(_ signal: HookEvent) {
        lock.lock(); defer { lock.unlock() }
        continuation?.yield(signal)
    }

    func shutdown() {
        lock.lock()
        let fd = self.fd
        let path = self.path
        let continuation = self.continuation
        let inbox = self.inbox
        self.fd = -1
        self.path = nil
        self.continuation = nil
        self.inbox = nil
        started = false
        lock.unlock()

        if fd >= 0 {
            // Wake a thread blocked in accept() before closing the fd: closing
            // alone is not a guaranteed wake-up on macOS, and shutdown(2) is the
            // conventional nudge (its return is irrelevant — the close still
            // happens). Prevents the accept loop lingering on a dead fd.
            Darwin.shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        if let path { unlink(path) }
        inbox?.finish() // ends the ordered consumer loop
        continuation?.finish()
    }
}
