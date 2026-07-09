import Foundation
import LighthouseTaskEngine

/// An attention event attributed to a task via the registration table.
public struct TaskAttentionSignal: Sendable, Equatable {
    public let taskId: UUID
    public let sessionRef: String
    public let event: AttentionEvent

    public init(taskId: UUID, sessionRef: String, event: AttentionEvent) {
        self.taskId = taskId
        self.sessionRef = sessionRef
        self.event = event
    }
}

public enum AttentionSocketError: Error, Sendable, Equatable {
    /// sun_path on macOS holds ~104 bytes — a too-long container path must
    /// fail loudly at start, not truncate silently.
    case socketPathTooLong(path: String, limit: Int)
    case systemCallFailed(call: String, errno: Int32)
    case alreadyStarted
}

/// Listens on a Unix domain socket for hook deliveries (curl POSTs the hook's
/// stdin JSON over the socket). Spec §8 posture: the socket is 0600
/// owner-only, and every payload is hostile until proven otherwise —
/// size-capped, schema-validated by the adapter, never executed, never
/// interpolated. Malformed input and unknown sessions are counted and
/// dropped; the listener never crashes and never blocks an agent (hooks run
/// async with their own timeout).
public actor AttentionSocketListener {
    /// Hard caps, documented here: 8 KiB of HTTP headers, 64 KiB of body.
    /// Real payloads observed live are well under 8 KiB; 64 KiB leaves room
    /// for a large last_assistant_message without accepting unbounded input.
    public static let maxHeaderBytes = 8 * 1024
    public static let maxBodyBytes = 64 * 1024
    static let socketFileName = "attention.sock"

    private let directory: URL
    private let translate: @Sendable (Data) -> AgentAttentionSignal?
    private let core = ListenerCore()

    private var registrations: [String: UUID] = [:]

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
    ///   - adapter: translates raw payloads; the listener itself knows no
    ///     agent-specific schema.
    public init(directory: URL, adapter: some AgentAdapter) {
        self.directory = directory
        self.translate = { adapter.attentionSignal(fromPayload: $0) }
    }

    deinit {
        core.shutdown()
    }

    // MARK: - Registration table

    public func register(sessionRef: String, taskId: UUID) {
        registrations[sessionRef] = taskId
    }

    public func unregister(sessionRef: String) {
        registrations.removeValue(forKey: sessionRef)
    }

    /// Single-consumer stream of attributed attention signals.
    public func signals() -> AsyncStream<TaskAttentionSignal> {
        let (stream, continuation) = AsyncStream.makeStream(of: TaskAttentionSignal.self)
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
            throw AttentionSocketError.socketPathTooLong(path: path, limit: capacity)
        }
        guard !core.isStarted else { throw AttentionSocketError.alreadyStarted }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        unlink(path) // stale socket from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw AttentionSocketError.systemCallFailed(call: "socket", errno: errno)
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
            throw AttentionSocketError.systemCallFailed(call: "bind", errno: savedErrno)
        }
        // Owner-only, before anyone can connect (spec §8).
        guard chmod(path, 0o600) == 0 else {
            let savedErrno = errno
            close(fd)
            unlink(path)
            throw AttentionSocketError.systemCallFailed(call: "chmod", errno: savedErrno)
        }
        guard listen(fd, 16) == 0 else {
            let savedErrno = errno
            close(fd)
            unlink(path)
            throw AttentionSocketError.systemCallFailed(call: "listen", errno: savedErrno)
        }

        guard core.markStarted(fd: fd, path: path) else {
            close(fd)
            unlink(path)
            throw AttentionSocketError.alreadyStarted
        }

        // Blocking accept loop on its own thread; connections are handled
        // serially (hook payloads are tiny and rare; a stalled client is
        // bounded by the 5s receive timeout).
        let thread = Thread { [weak self, fd] in
            Self.acceptLoop(listenFD: fd, owner: self)
        }
        thread.name = "lighthouse.attention-socket"
        thread.start()

        return socketURL
    }

    /// Synchronous and callable from anywhere (deinit, defer): closes the
    /// socket, unlinks the path, finishes the signal stream. Idempotent.
    public nonisolated func stop() {
        core.shutdown()
    }

    // MARK: - Payload handling (actor-isolated)

    private func process(body: Data) {
        guard let signal = translate(body) else {
            recordDrop("unparseable payload (\(body.count) bytes)")
            return
        }
        guard let event = signal.event else {
            // Valid payload, irrelevant event type: not an error, but still
            // counted for observability.
            recordDrop("irrelevant event for session \(signal.sessionRef)")
            return
        }
        guard let taskId = registrations[signal.sessionRef] else {
            recordDrop("unknown session \(signal.sessionRef)")
            return
        }
        core.yield(TaskAttentionSignal(taskId: taskId, sessionRef: signal.sessionRef, event: event))
    }

    private func recordDrop(_ reason: String) {
        droppedCount += 1
        lastDropReason = reason
        FileHandle.standardError.write(Data("[lighthouse attention-socket] dropped: \(reason)\n".utf8))
    }

    // MARK: - Accept loop + minimal HTTP framing (listener thread)

    private static func acceptLoop(listenFD: Int32, owner: AttentionSocketListener?) {
        while true {
            let connection = accept(listenFD, nil, nil)
            guard connection >= 0 else { return } // listener closed

            // A crashed peer must not SIGPIPE the app.
            var noSigpipe: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe,
                       socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))

            switch readRequest(from: connection) {
            case .success(let body):
                respond(connection, status: "200 OK")
                if let owner {
                    Task { await owner.process(body: body) }
                }
            case .failure(let reason):
                respond(connection, status: "400 Bad Request")
                if let owner {
                    Task { await owner.recordDrop(reason) }
                }
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
    private static func readRequest(from fd: Int32) -> FrameResult {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let separator = Data("\r\n\r\n".utf8)

        // Headers.
        var headerEnd: Range<Data.Index>? = buffer.range(of: separator)
        while headerEnd == nil {
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

/// Lock-guarded socket lifecycle + signal continuation, so shutdown is
/// synchronous, idempotent, and callable from deinit/defer while the accept
/// thread and the actor both stay race-free.
private final class ListenerCore: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var path: String?
    private var started = false
    private var continuation: AsyncStream<TaskAttentionSignal>.Continuation?

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

    func setContinuation(_ new: AsyncStream<TaskAttentionSignal>.Continuation) {
        lock.lock(); defer { lock.unlock() }
        continuation = new
    }

    func yield(_ signal: TaskAttentionSignal) {
        lock.lock(); defer { lock.unlock() }
        continuation?.yield(signal)
    }

    func shutdown() {
        lock.lock()
        let fd = self.fd
        let path = self.path
        let continuation = self.continuation
        self.fd = -1
        self.path = nil
        self.continuation = nil
        started = false
        lock.unlock()

        if fd >= 0 { close(fd) }
        if let path { unlink(path) }
        continuation?.finish()
    }
}
