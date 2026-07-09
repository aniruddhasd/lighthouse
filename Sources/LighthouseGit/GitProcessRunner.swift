import Foundation

struct GitCommandResult: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String {
        String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs git as a subprocess with an argument array — never a shell, never
/// string interpolation. Branch names, task names, and paths are data.
enum GitProcessRunner {

    static func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL
    ) async throws -> GitCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        // The termination handler must be installed before run() — installing
        // it after the process has already exited is not guaranteed to fire.
        let exitCode = ValuePromise<Int32>()
        process.terminationHandler = { exitCode.fulfill($0.terminationStatus) }

        do {
            try process.run()
        } catch {
            throw GitClientError.launchFailed(
                executable: executable, reason: String(describing: error))
        }

        // Drain both pipes concurrently while the process runs; draining
        // sequentially can deadlock once either pipe's buffer fills.
        async let stdoutData = drain(stdoutPipe.fileHandleForReading)
        async let stderrData = drain(stderrPipe.fileHandleForReading)

        let status = await exitCode.value
        return GitCommandResult(
            exitCode: status,
            stdout: await stdoutData,
            stderr: await stderrData)
    }

    private static func drain(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = (try? handle.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }
}

/// Single-assignment promise bridging a callback (Process.terminationHandler)
/// to async/await without racing the handler installation.
private final class ValuePromise<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    private var waiter: CheckedContinuation<T, Never>?

    func fulfill(_ value: T) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: value)
        } else {
            stored = value
            lock.unlock()
        }
    }

    var value: T {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let stored {
                    lock.unlock()
                    continuation.resume(returning: stored)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }
    }
}
