import Foundation
import Testing
import LighthouseGit
import LighthouseTaskEngine
@testable import LighthouseAdapter

@Suite("ClaudeCodeAdapter launch plans")
struct ClaudeCodeAdapterTests {
    private let adapter = ClaudeCodeAdapter()

    private func spec(
        primary: String = "/tmp/wt/primary repo",
        additional: [String] = []
    ) -> SessionSpec {
        SessionSpec(
            primaryWorktree: URL(fileURLWithPath: primary, isDirectory: true),
            additionalWorktrees: additional.map { URL(fileURLWithPath: $0, isDirectory: true) },
            loginShell: "/bin/zsh")
    }

    // MARK: Launch plans

    @Test func launchPlanRunsPersistentInteractiveLoginShell() throws {
        let plan = try adapter.launchPlan(for: spec())
        // Persistent shell: -l -i and NO -c/exec (2026-07-13). The claude
        // command is typed in, so Claude's exit returns the user's prompt.
        #expect(plan.executable == "/bin/zsh")
        #expect(plan.arguments == ["-l", "-i"])
        #expect(plan.workingDirectory.path == "/tmp/wt/primary repo")
        #expect(plan.environment.isEmpty)
        let command = try #require(plan.typedCommand)
        #expect(!command.contains("exec"))
        #expect(command.hasPrefix("'claude'") || command.hasPrefix("claude"))
    }

    @Test func launchPlanPreassignsSessionIdAsSessionRef() throws {
        let plan = try adapter.launchPlan(for: spec())
        let command = try #require(plan.typedCommand)
        #expect(UUID(uuidString: plan.sessionRef) != nil)
        #expect(command.contains("--session-id"))
        #expect(command.contains(plan.sessionRef))
        let second = try adapter.launchPlan(for: spec())
        #expect(second.sessionRef != plan.sessionRef)
    }

    @Test func resumePlanUsesStoredSessionRef() throws {
        let ref = "0e984725-c51c-4bf4-9960-e1c80e27aba0"
        let plan = try adapter.resumePlan(for: spec(), sessionRef: ref)
        let command = try #require(plan.typedCommand)
        #expect(command.contains("--resume"))
        #expect(command.contains(ref))
        #expect(plan.sessionRef == ref)
        #expect(!command.contains("--session-id"))
    }

    @Test func additionalWorktreesWithSpacesBecomeQuotedAddDirs() async throws {
        let plan = try adapter.launchPlan(for: spec(
            primary: "/tmp/wt/repo one",
            additional: ["/tmp/wt/repo two", "/tmp/wt/repo three (copy)"]))
        let command = try #require(plan.typedCommand)
        // Prove word boundaries with a real shell: the typed command, with
        // `claude` swapped for printf, must parse into exact words.
        let probe = command.replacingOccurrences(of: "'claude'", with: "printf '[%s]'")
        let result = try await ProcessRunner.run(
            executable: "/bin/zsh", arguments: ["-c", probe],
            workingDirectory: FileManager.default.temporaryDirectory)
        let words = String(decoding: result.stdout, as: UTF8.self)
        #expect(words.contains("[--add-dir][/tmp/wt/repo two][--add-dir][/tmp/wt/repo three (copy)]"))
    }

    @Test func hostileWorktreePathsCannotEscapeTheTypedCommand() async throws {
        let evil = "/tmp/x'; touch /tmp/lighthouse-pwned; '"
        let plan = try adapter.launchPlan(for: spec(additional: [evil]))
        let command = try #require(plan.typedCommand)
        let probe = command.replacingOccurrences(of: "'claude'", with: "printf '[%s]'")
        let result = try await ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", probe],
            workingDirectory: FileManager.default.temporaryDirectory)
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("[\(evil)]"))
        #expect(!FileManager.default.fileExists(atPath: "/tmp/lighthouse-pwned"))
    }

    @Test func hostileTaskNameInTypedCommandCannotBreakOut() async throws {
        // The task name flows into `-n <name>`; a hostile name must stay one
        // word (composed by ShellQuoter).
        let evil = "task$(touch /tmp/lighthouse-name-pwned)`id`; rm -rf /"
        let plan = try adapter.launchPlan(for: SessionSpec(
            primaryWorktree: URL(fileURLWithPath: "/tmp/wt"),
            loginShell: "/bin/zsh", displayName: evil))
        let command = try #require(plan.typedCommand)
        let probe = command.replacingOccurrences(of: "'claude'", with: "printf '[%s]'")
        let result = try await ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", probe],
            workingDirectory: FileManager.default.temporaryDirectory)
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("[\(evil)]"))
        #expect(!FileManager.default.fileExists(atPath: "/tmp/lighthouse-name-pwned"))
    }
}
