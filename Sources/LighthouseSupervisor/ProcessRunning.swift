import Foundation

public struct ProcessOutput: Sendable, Equatable {
    public let exitStatus: Int32
    public let stdout: Data
    public let stderr: Data
}

public enum ProcessRunError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut
    case outputTooLarge
}

/// Runs a prepared invocation. A protocol so the runner's policy is tested with a
/// fake and the real process handling is tested against a stub executable.
public protocol ProcessRunning: Sendable {
    func run(_ invocation: SupervisorInvocation, timeout: TimeInterval) async throws -> ProcessOutput
}
