import Foundation
import Testing
@testable import LighthouseSupervisor

/// The app must find `claude` without the user's shell function (docs §14). An explicit
/// setting is never silently overridden: a wrong path is an error, not a fallback.
@Suite("ClaudeLocator")
struct ClaudeLocatorTests {
    private func locate(
        override: String? = nil, executables: Set<String> = [], shell: String? = nil, home: String = "/Users/u"
    ) async -> Result<ClaudeLocation, ClaudeNotFound> {
        await ClaudeLocator.locate(
            override: override, home: home, isExecutable: { executables.contains($0) }, shellProbe: { shell })
    }
    private func found(_ r: Result<ClaudeLocation, ClaudeNotFound>) -> ClaudeLocation? { try? r.get() }

    @Test func anExplicitSettingWinsOverEverything() async {
        let r = await locate(override: "/opt/mine/claude",
                             executables: ["/opt/mine/claude", "/Users/u/.local/bin/claude"], shell: "/x/claude")
        #expect(found(r)?.url.path == "/opt/mine/claude" && found(r)?.source == "setting")
    }

    @Test func aWrongExplicitSettingIsAnErrorNotAFallback() async {
        let r = await locate(override: "/opt/typo/claude", executables: ["/Users/u/.local/bin/claude"], shell: "/x/claude")
        if case .failure(let e) = r { #expect(e.message.contains("/opt/typo/claude")) } else { Issue.record("must not fall back") }
    }

    @Test func aRelativeOrBlankSettingIsInvalidNotIgnored() async {
        for bad in ["claude", "../claude", "~/bin/claude"] {
            #expect(found(await locate(override: bad, executables: ["/Users/u/.local/bin/claude"])) == nil, "\(bad)")
        }
        #expect(found(await locate(override: "  ", executables: ["/Users/u/.local/bin/claude"]))?.source == "~/.local/bin")
    }

    @Test func knownLocationsAreTriedInOrder() async {
        let all: Set = ["/Users/u/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        #expect(found(await locate(executables: all))?.url.path == "/Users/u/.local/bin/claude")
        #expect(found(await locate(executables: ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]))?.url.path == "/opt/homebrew/bin/claude")
        #expect(found(await locate(executables: ["/usr/local/bin/claude"]))?.url.path == "/usr/local/bin/claude")
    }

    @Test func theLoginShellIsAskedOnlyWhenNothingElseMatchesAndItsAnswerIsChecked() async {
        #expect(found(await locate(executables: ["/x/claude"], shell: "/x/claude"))?.source == "login shell")
        #expect(found(await locate(executables: [], shell: "/x/claude")) == nil, "a path that is not executable is not trusted")
        #expect(found(await locate(executables: ["claude"], shell: "claude")) == nil, "a relative answer is not trusted")
    }

    @Test func notFoundSaysWhereItLooked() async {
        if case .failure(let e) = await locate() {
            #expect(e.message.contains(".local/bin") && e.message.contains("Claude binary"))
        } else { Issue.record("expected not found") }
    }

    @Test func theShellProbeTakesTheLastAbsolutePathAndIgnoresNoise() {
        #expect(LoginShellProbe.parse("(eval):1: can't change option: zle\n(eval):1: can't change option: zle\n/Users/u/.local/bin/claude\n") == "/Users/u/.local/bin/claude")
        #expect(LoginShellProbe.parse("claude: aliased to something\n") == nil)
        #expect(LoginShellProbe.parse("") == nil)
        #expect(LoginShellProbe.parse("/a/claude\nwarning: later noise\n") == "/a/claude", "the path need not be the last line")
        #expect(LoginShellProbe.parse("/a/claude\n/b/claude\n") == "/b/claude")
    }

    @Test func theShellProbeRunsTheLoginShellAndSurvivesFailures() async {
        let ok = LoginShellProbe(process: StubRunner(.success(ProcessOutput(exitStatus: 0, stdout: Data("noise\n/z/claude\n".utf8), stderr: Data()))), shell: "/bin/zsh", home: "/h", user: "u")
        #expect(await ok.probe() == "/z/claude")
        let bad = LoginShellProbe(process: StubRunner(.failure(.timedOut)), shell: "/bin/zsh", home: "/h", user: "u")
        #expect(await bad.probe() == nil)
        let exit = LoginShellProbe(process: StubRunner(.success(ProcessOutput(exitStatus: 1, stdout: Data(), stderr: Data()))), shell: "/bin/zsh", home: "/h", user: "u")
        #expect(await exit.probe() == nil)
    }
}

private struct StubRunner: ProcessRunning {
    let result: Result<ProcessOutput, ProcessRunError>
    init(_ result: Result<ProcessOutput, ProcessRunError>) { self.result = result }
    func run(_ invocation: SupervisorInvocation, timeout: TimeInterval) async throws -> ProcessOutput { try result.get() }
}
