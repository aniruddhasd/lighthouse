import AppKit
import Foundation
import Testing
import LighthouseAdapter
@testable import LighthouseApp

@MainActor
@Suite("ForegroundProbe", .serialized)
final class ForegroundProbeTests {
    @Test func anInvalidDescriptorIsUnknownNotAGuess() {
        #expect(ForegroundProbe.foregroundProcessName(masterFD: -1) == nil)
        #expect(ForegroundProbe.foregroundProcessName(masterFD: 9_999) == nil)
    }

    /// "Is it Claude?" must be strict: unknown stays unknown, near-misses are no.
    @Test func isClaudeIsExactAndNeverGuesses() {
        #expect(ForegroundProbe.isClaude(name: nil) == nil)
        #expect(ForegroundProbe.isClaude(name: "claude") == true)
        for other in ["zsh", "sh", "node", "Claude", "claude-code", "claudette", " claude", ""] {
            #expect(ForegroundProbe.isClaude(name: other) == false, "\(other.debugDescription)")
        }
    }

    /// A real pty: at the shell prompt the foreground is the shell; while a command runs
    /// it is that command; after Ctrl-C it is the shell again. This is the same
    /// distinction as "Claude is running" versus "Claude exited to a prompt".
    @Test func readsTheForegroundProgramOfARealPty() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lh-fg-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let controller = TerminalController(key: TabKey(taskId: UUID(), tabId: TabID.agent))
        defer { controller.terminateIfRunning(); try? FileManager.default.removeItem(at: dir) }

        controller.start(plan: LaunchPlan(
            executable: "/bin/sh", arguments: ["-i"], environment: [:],
            workingDirectory: dir, sessionRef: "", typedCommand: nil), typingDelay: .milliseconds(50))

        /// Polls until the foreground name satisfies `done` (or the deadline), returning the last reading.
        func foreground(settleFor ms: Int = 1_200, until done: (String?) -> Bool) async throws -> String? {
            var last: String?
            for _ in 0..<(ms / 50) {
                try await Task.sleep(for: .milliseconds(50))
                last = controller.foregroundProcessName()
                if done(last) { return last }
            }
            return last
        }

        // macOS's /bin/sh is bash in POSIX mode, so the shell's own process name is
        // "bash" here — measure it instead of hard-coding it.
        let shell = try await foreground { $0 != nil }
        let shellName = try #require(shell, "the probe could not read the foreground of a live pty")
        #expect(["sh", "bash", "zsh"].contains(shellName), "at the prompt the shell is in the foreground: \(shellName)")

        controller.type(text: "sleep 30\n")
        let running = try await foreground { $0 == "sleep" }
        #expect(running == "sleep", "while a command runs, that command is in the foreground")
        #expect(ForegroundProbe.isClaude(name: running) == false)

        controller.type(text: "\u{03}")
        let back = try await foreground { $0 == shellName }
        #expect(back == shellName, "after Ctrl-C the shell is back in the foreground")
    }

    /// Text WE type is not the user typing: the programmatic path must leave the
    /// user-input clock untouched.
    @Test func typingProgrammaticallyDoesNotCountAsUserInput() async throws {
        let controller = TerminalController(key: TabKey(taskId: UUID(), tabId: TabID.agent))
        defer { controller.terminateIfRunning() }
        controller.start(plan: LaunchPlan(
            executable: "/bin/sh", arguments: ["-i"], environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory, sessionRef: "", typedCommand: nil),
            typingDelay: .milliseconds(50))
        controller.type(text: "echo hi")
        try await Task.sleep(for: .milliseconds(200))
        #expect(controller.lastUserInput == nil)
    }
}
