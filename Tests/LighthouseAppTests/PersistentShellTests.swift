import AppKit
import Foundation
import Testing
import LighthouseAdapter
@testable import LighthouseApp

/// The persistent-shell fix (2026-07-13): the pty runs a shell, the agent is
/// TYPED into it, so a command exiting does NOT kill the pty — only an
/// explicit `exit` does. Drives a real shell in SwiftTerm's pty and observes.
@MainActor
@Suite("Persistent shell terminal", .serialized)
final class PersistentShellTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lh-shell-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func shellSurvivesTypedCommandExitAndDiesOnlyOnExit() async throws {
        let controller = TerminalController(key: TabKey(taskId: UUID(), tabId: TabID.agent))
        var exited = false
        controller.onExit = { _, _ in exited = true }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir); controller.terminateIfRunning() }

        // A short-lived typed command: `true` runs and exits immediately.
        let plan = LaunchPlan(
            executable: "/bin/sh", arguments: ["-i"], environment: [:],
            workingDirectory: dir, sessionRef: "", typedCommand: "true")
        controller.start(plan: plan, typingDelay: .milliseconds(150))

        // After the typed command has run and exited, the SHELL (pty) is
        // still alive — the corpse bug would have killed it here.
        try await Task.sleep(for: .milliseconds(700))
        #expect(controller.isRunning)
        #expect(!exited)

        // Explicit exit ends the pty.
        controller.type(text: "exit\n")
        for _ in 0..<40 where !exited { try await Task.sleep(for: .milliseconds(50)) }
        #expect(exited)
        #expect(!controller.isRunning)
    }

    @Test func typedCommandRunsInTheWorkingDirectory() async throws {
        let dir = try tempDir()
        let capture = dir.appendingPathComponent("pwd.out")
        let controller = TerminalController(key: TabKey(taskId: UUID(), tabId: UUID()))
        defer { try? FileManager.default.removeItem(at: dir); controller.terminateIfRunning() }

        // The typed command writes the shell's cwd — proves both that the
        // command executes (item-1 mechanism) and that it runs in the
        // worktree (item-2 shell tab requirement).
        let plan = LaunchPlan(
            executable: "/bin/sh", arguments: ["-i"], environment: [:],
            workingDirectory: dir, sessionRef: "",
            typedCommand: "pwd > '\(capture.path)'")
        controller.start(plan: plan, typingDelay: .milliseconds(150))

        var contents = ""
        for _ in 0..<60 {
            if let text = try? String(contentsOf: capture, encoding: .utf8), !text.isEmpty {
                contents = text.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Resolve symlinks: /var → /private/var on macOS.
        let expected = dir.resolvingSymlinksInPath().path
        #expect(URL(fileURLWithPath: contents).resolvingSymlinksInPath().path == expected,
                "shell cwd was \(contents.debugDescription), expected \(expected)")
    }

    @Test func plainShellTabHasNoTypedCommandAndStaysAlive() async throws {
        // An extra Cmd+T tab is a plain shell (typedCommand nil) that stays
        // alive with no agent and no attention effect.
        let controller = TerminalController(key: TabKey(taskId: UUID(), tabId: UUID()))
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir); controller.terminateIfRunning() }
        let plan = LaunchPlan(
            executable: "/bin/sh", arguments: ["-i"], environment: [:],
            workingDirectory: dir, sessionRef: "", typedCommand: nil)
        controller.start(plan: plan, typingDelay: .milliseconds(50))
        try await Task.sleep(for: .milliseconds(400))
        #expect(controller.isRunning)
    }
}
