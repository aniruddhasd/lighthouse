import Foundation
import Testing
import LighthouseFixtures
import LighthouseGit
import LighthouseTaskEngine
@testable import LighthouseAdapter

/// Delegates to the real adapter while capturing every raw payload — the
/// captured JSON is what docs/claude-code-contract.md quotes.
private final class PayloadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var payloads: [Data] = []
    func record(_ data: Data) {
        lock.lock(); payloads.append(data); lock.unlock()
    }
    var all: [Data] {
        lock.lock(); defer { lock.unlock() }; return payloads
    }
}

private struct RecordingAdapter: AgentAdapter {
    let base = ClaudeCodeAdapter()
    let recorder: PayloadRecorder
    var kind: String { base.kind }
    func launchPlan(for spec: SessionSpec) throws -> LaunchPlan { try base.launchPlan(for: spec) }
    func resumePlan(for spec: SessionSpec, sessionRef: String) throws -> LaunchPlan {
        try base.resumePlan(for: spec, sessionRef: sessionRef)
    }
    func prepareWorkspaceAttention(in workspace: URL, socketPath: URL) async throws {
        try await base.prepareWorkspaceAttention(in: workspace, socketPath: socketPath)
    }
    func removeWorkspaceAttention(from workspace: URL) async throws {
        try await base.removeWorkspaceAttention(from: workspace)
    }
    func attentionSignal(fromPayload payload: Data) -> AgentAttentionSignal? {
        recorder.record(payload)
        return base.attentionSignal(fromPayload: payload)
    }
}

/// ONE live end-to-end run against the real installed Claude Code CLI in -p
/// mode: project-local hooks (installed by our HookInstaller) → curl →
/// unix socket → listener → attributed signals. Gated because it spends one
/// real (haiku, single-turn) API call and needs a logged-in account:
///
///   LIGHTHOUSE_LIVE_CLAUDE_TEST=1 swift test --filter LiveClaudeHookCapture
///
/// Optional: LIGHTHOUSE_LIVE_CLAUDE_BIN (default ~/.local/bin/claude),
/// LIGHTHOUSE_LIVE_CLAUDE_CONFIG_DIR (default ~/.claude-enterprise, matching
/// the per-folder account this project runs under). Reads the account's
/// config; never writes to it beyond normal session history.
@Suite(
    "Live Claude Code hook capture",
    .enabled(if: ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_CLAUDE_TEST"] == "1"))
final class LiveClaudeHookCaptureTests {
    private let fixtures = try! FixtureFactory()

    deinit {
        try? fixtures.destroy()
    }

    @Test(.timeLimit(.minutes(5)))
    func printModeDeliversHooksThroughOurSocket() async throws {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let claudeBin = env["LIGHTHOUSE_LIVE_CLAUDE_BIN"] ?? "\(home)/.local/bin/claude"
        let configDir = env["LIGHTHOUSE_LIVE_CLAUDE_CONFIG_DIR"] ?? "\(home)/.claude-enterprise"
        try #require(FileManager.default.isExecutableFile(atPath: claudeBin),
                     "claude binary not found at \(claudeBin)")

        // Workspace fixture + listener + hooks, exactly as production wires
        // them. The socket lives in a SHORT temp path: sun_path caps unix
        // socket paths at ~104 bytes and the fixture root is too deep.
        let repo = try fixtures.cleanRepo()
        let socketDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lh-live-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: socketDir) }
        let recorder = PayloadRecorder()
        let listener = AttentionSocketListener(
            directory: socketDir, adapter: RecordingAdapter(recorder: recorder))
        let socketURL = try await listener.start()
        defer { listener.stop() }

        let installer = HookInstaller()
        try await installer.install(in: repo.path, socketPath: socketURL)

        let sessionId = UUID().uuidString.lowercased()
        let taskId = UUID()
        await listener.register(sessionRef: sessionId, taskId: taskId)
        let stream = await listener.signals()

        // Non-interactive one-shot; trust dialog is skipped in -p mode.
        var claudeEnv = env
        claudeEnv["CLAUDE_CONFIG_DIR"] = configDir
        async let run = ProcessRunner.run(
            executable: claudeBin,
            arguments: ["-p", "Reply with exactly: OK", "--model", "haiku",
                        "--session-id", sessionId],
            workingDirectory: repo.path,
            environment: claudeEnv)

        var received: [AttentionEvent] = []
        for await signal in stream {
            #expect(signal.taskId == taskId)
            received.append(signal.event)
            if received.contains(.agentWorking) && received.contains(.agentStopped) {
                break
            }
        }

        let result = try await run
        #expect(result.exitCode == 0, "claude -p failed: \(result.stderrText)")
        #expect(received.contains(.agentWorking), "UserPromptSubmit never arrived")
        #expect(received.contains(.agentStopped), "Stop never arrived")

        // Dump raw payloads for the contract doc (session id is not a secret,
        // but redact the home directory).
        print("=== captured live hook payloads (\(recorder.all.count)) ===")
        for payload in recorder.all {
            let text = String(decoding: payload, as: UTF8.self)
                .replacingOccurrences(of: home, with: "~")
            print(text)
        }
        print("=== end captured payloads ===")
    }
}
