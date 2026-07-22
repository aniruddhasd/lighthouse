import Foundation
import Testing
@testable import LighthouseApp

/// The spawned-session environment rule. The load-bearing one is first: a
/// Claude Code child-session marker inherited by Lighthouse must NOT reach the
/// sessions it spawns, or every worktree `claude` silently stops saving its
/// transcript.
@MainActor
@Suite("Session environment")
struct SessionEnvironmentTests {

    @Test func stripsChildSessionMarkerSoSpawnedSessionsSaveTranscripts() {
        // Lighthouse launched from within a Claude Code shell inherits the
        // marker; it must not propagate to the top-level session it spawns.
        let env = TerminalController.sessionEnvironment(
            base: ["CLAUDE_CODE_CHILD_SESSION": "1", "PATH": "/usr/bin"],
            overrides: [:])
        #expect(env["CLAUDE_CODE_CHILD_SESSION"] == nil)
        #expect(env["PATH"] == "/usr/bin") // unrelated vars untouched
    }

    @Test func markerStrippedEvenWhenAnOverrideSetsIt() {
        let env = TerminalController.sessionEnvironment(
            base: [:], overrides: ["CLAUDE_CODE_CHILD_SESSION": "1"])
        #expect(env["CLAUDE_CODE_CHILD_SESSION"] == nil)
    }

    @Test func setsTerminalDefaults() {
        let env = TerminalController.sessionEnvironment(base: [:], overrides: [:])
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["LANG"] == "en_US.UTF-8") // defaulted when absent
    }

    @Test func preservesInheritedLangAndAppliesOverrides() {
        let env = TerminalController.sessionEnvironment(
            base: ["LANG": "fr_FR.UTF-8"],
            overrides: ["FOO": "bar"])
        #expect(env["LANG"] == "fr_FR.UTF-8") // not clobbered by the default
        #expect(env["FOO"] == "bar")
    }
}
