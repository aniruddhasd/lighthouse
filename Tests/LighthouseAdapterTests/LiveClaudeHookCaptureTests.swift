import Foundation
import Testing
import LighthouseFixtures
import LighthouseGit
@testable import LighthouseAdapter

/// ONE live end-to-end run against the real installed Claude Code CLI in -p
/// mode: hooks installed by our HookInstaller → curl → unix socket → listener →
/// parsed `HookEvent`s. Gated because it spends one real (haiku, single-turn)
/// API call and needs a logged-in account:
///
///   LIGHTHOUSE_LIVE_CLAUDE_TEST=1 swift test --filter LiveClaudeHookCapture
///
/// Optional: LIGHTHOUSE_LIVE_CLAUDE_BIN (default ~/.local/bin/claude),
/// LIGHTHOUSE_LIVE_CLAUDE_CONFIG_DIR (default ~/.claude-enterprise, matching the
/// per-folder account this project runs under). This covers -p mode only; the
/// interactive session is observed through the app's Supervision card.
@Suite(
    "Live Claude Code hook capture",
    .enabled(if: ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_CLAUDE_TEST"] == "1"))
final class LiveClaudeHookCaptureTests {
    private let fixtures = try! FixtureFactory()
    deinit { try? fixtures.destroy() }

    @Test(.timeLimit(.minutes(5)))
    func printModeDeliversHooksThroughOurSocket() async throws {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let claudeBin = env["LIGHTHOUSE_LIVE_CLAUDE_BIN"] ?? "\(home)/.local/bin/claude"
        let configDir = env["LIGHTHOUSE_LIVE_CLAUDE_CONFIG_DIR"] ?? "\(home)/.claude-enterprise"
        try #require(FileManager.default.isExecutableFile(atPath: claudeBin),
                     "claude binary not found at \(claudeBin)")

        let repo = try fixtures.cleanRepo()
        // SHORT socket path: sun_path caps at ~104 bytes.
        let socketDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lh-live-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: socketDir) }
        let listener = HookEventListener(directory: socketDir)
        let socketURL = try await listener.start()
        defer { listener.stop() }
        try await HookInstaller().install(in: repo.path, socketPath: socketURL)

        let sessionId = UUID().uuidString.lowercased()
        let stream = await listener.events()

        var claudeEnv = env
        claudeEnv["CLAUDE_CONFIG_DIR"] = configDir
        async let run = ProcessRunner.run(
            executable: claudeBin,
            arguments: ["-p", "Reply with exactly: OK", "--model", "haiku",
                        "--session-id", sessionId],
            workingDirectory: repo.path,
            environment: claudeEnv)

        var received: [HookEvent] = []
        for await event in stream {
            received.append(event)
            if event.eventName == "SessionEnd" { break }
            if received.count > 40 { break }
        }

        let result = try await run
        #expect(result.exitCode == 0, "claude -p failed: \(result.stderrText)")
        let names = received.map(\.eventName)
        #expect(names.contains("UserPromptSubmit"), "UserPromptSubmit never arrived: \(names)")
        #expect(names.contains("Stop"), "Stop never arrived: \(names)")
        // Attribution key: every event echoes the pre-assigned session id.
        #expect(received.allSatisfy { $0.sessionId == sessionId },
                "foreign session ids: \(Set(received.map(\.sessionId)))")
        let stop = received.first { $0.eventName == "Stop" }
        #expect(stop?.lastAssistantMessage?.contains("OK") == true)

        print("=== captured live hook events (\(received.count)) ===")
        for e in received {
            print("\(e.eventName) notif=\(e.notificationType ?? "-") agent=\(e.agentId ?? "-") reason=\(e.endReason ?? "-") keys=\(e.payloadKeys.joined(separator: ","))")
        }
        print("=== end ===")
    }
}
