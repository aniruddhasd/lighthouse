import Foundation

/// The real `ProcessRunning`: spawns the executable, feeds stdin, captures bounded
/// output, and enforces the timeout (SIGTERM, then SIGKILL after a grace period).
/// Only the direct child is signalled; descendants are expected to exit when their stdin
/// closes (stdio MCP servers do) — not verified against a hung child process tree.
public struct FoundationProcessRunner: ProcessRunning {
    public static let maxOutputBytes = 1_000_000
    /// How long a process gets between SIGTERM and SIGKILL.
    public let killGrace: TimeInterval
    /// How long to wait for the pipes to close once the process has exited.
    public let drainGrace: TimeInterval

    public init(killGrace: TimeInterval = 3, drainGrace: TimeInterval = 2) {
        self.killGrace = killGrace
        self.drainGrace = drainGrace
    }

    public func run(_ invocation: SupervisorInvocation, timeout: TimeInterval) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = invocation.currentDirectory
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // Writing to a process that already exited must fail with EPIPE, not deliver
        // SIGPIPE (which would terminate the whole app).
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let state = Capture(limit: Self.maxOutputBytes)
        func watch(_ pipe: Pipe, stream: Capture.Stream) {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    state.closed(stream)
                } else if state.append(data, to: stream) == .overflow {
                    Self.signal(process, SIGKILL)
                }
            }
        }
        watch(stdout, stream: .out)
        watch(stderr, stream: .err)

        return try await withCheckedThrowingContinuation { continuation in
            state.onFinish = {
                continuation.resume(with: state.result())
            }
            process.terminationHandler = { finished in
                state.exited(finished.terminationStatus)
                // A grandchild holding the pipes open must not hang the run forever.
                DispatchQueue.global().asyncAfter(deadline: .now() + drainGrace) {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    state.forceFinish()
                }
            }
            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                state.fail(.launchFailed("\(error)"))
                return
            }
            // Feed stdin off the caller's thread; a process that exits early must not
            // take us down with a broken pipe.
            let input = Data(invocation.stdin.utf8)
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
            let grace = killGrace
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                state.markTimedOut()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
                    if process.isRunning { Self.signal(process, SIGKILL) }
                }
            }
        }
    }

    private static func signal(_ process: Process, _ sig: Int32) {
        let pid = process.processIdentifier
        if pid > 0 { kill(pid, sig) }
    }

    /// Everything the pipe handlers and the exit handler share, behind one lock.
    private final class Capture: @unchecked Sendable {
        enum Stream { case out, err }
        enum Append { case ok, overflow }

        private let lock = NSLock()
        private let limit: Int
        private var out = Data(), err = Data()
        private var openStreams = 2
        private var status: Int32?
        private var timedOut = false, overflowed = false, finished = false
        private var failure: ProcessRunError?
        var onFinish: (() -> Void)?

        init(limit: Int) { self.limit = limit }

        func append(_ data: Data, to stream: Stream) -> Append {
            lock.lock(); defer { lock.unlock() }
            if out.count + err.count + data.count > limit {
                overflowed = true
                return .overflow
            }
            if stream == .out { out.append(data) } else { err.append(data) }
            return .ok
        }

        func closed(_ stream: Stream) { locked { openStreams -= 1 }; finishIfDone() }
        func exited(_ code: Int32) { locked { status = code }; finishIfDone() }
        func markTimedOut() { locked { timedOut = true } }
        func fail(_ error: ProcessRunError) { locked { failure = error; status = -1; openStreams = 0 }; finishIfDone() }
        func forceFinish() { locked { openStreams = 0 }; finishIfDone() }

        private func locked(_ body: () -> Void) { lock.lock(); body(); lock.unlock() }

        private func finishIfDone() {
            lock.lock()
            let done = status != nil && openStreams <= 0 && !finished
            if done { finished = true }
            lock.unlock()
            if done { onFinish?() }
        }

        func result() -> Result<ProcessOutput, ProcessRunError> {
            lock.lock(); defer { lock.unlock() }
            if let failure { return .failure(failure) }
            if timedOut { return .failure(.timedOut) }
            if overflowed { return .failure(.outputTooLarge) }
            return .success(ProcessOutput(exitStatus: status ?? -1, stdout: out, stderr: err))
        }
    }
}
