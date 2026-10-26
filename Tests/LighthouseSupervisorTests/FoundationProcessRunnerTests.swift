import Foundation
import Testing
@testable import LighthouseSupervisor

/// The real process handling, against stub executables (no network, no Claude).
@Suite("FoundationProcessRunner", .serialized)
struct FoundationProcessRunnerTests {
    private let runner = FoundationProcessRunner(killGrace: 0.3, drainGrace: 0.3)

    private func scratch() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("lh-pr-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func script(_ body: String, in d: URL) throws -> URL {
        let url = d.appendingPathComponent("stub-\(UUID().uuidString.prefix(6)).sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        chmod(url.path, 0o700)
        return url
    }
    private func invocation(_ exe: URL, stdin: String = "", env: [String: String] = ["PATH": "/usr/bin:/bin"],
                            cwd: URL) -> SupervisorInvocation {
        SupervisorInvocation(executable: exe, arguments: [], environment: env, currentDirectory: cwd, stdin: stdin, supportFiles: [])
    }

    @Test func aLaunchFailureIsReportedNotThrownAsACrash() async throws {
        let d = try scratch(); defer { try? FileManager.default.removeItem(at: d) }
        do {
            _ = try await runner.run(invocation(URL(fileURLWithPath: "/nonexistent/x"), cwd: d), timeout: 5)
            Issue.record("expected a launch failure")
        } catch let e as ProcessRunError {
            if case .launchFailed = e {} else { Issue.record("wrong error \(e)") }
        }
    }

    @Test func aHungProcessIsTimedOutAndKilledEvenIfItIgnoresSIGTERM() async throws {
        let d = try scratch(); defer { try? FileManager.default.removeItem(at: d) }
        let exe = try script("trap '' TERM\nwhile :; do sleep 1; done", in: d)
        let start = Date()
        do {
            _ = try await runner.run(invocation(exe, cwd: d), timeout: 0.5)
            Issue.record("expected a timeout")
        } catch let e as ProcessRunError {
            #expect(e == .timedOut)
        }
        #expect(Date().timeIntervalSince(start) < 5, "SIGKILL must follow SIGTERM within the grace period")
    }

    @Test func runawayOutputIsCutOffAndReported() async throws {
        let d = try scratch(); defer { try? FileManager.default.removeItem(at: d) }
        let exe = try script("yes | head -c 5000000", in: d)
        do {
            _ = try await runner.run(invocation(exe, cwd: d), timeout: 20)
            Issue.record("expected an overflow")
        } catch let e as ProcessRunError {
            #expect(e == .outputTooLarge)
        }
    }

    @Test func aNonZeroExitKeepsItsStatusAndStderr() async throws {
        let d = try scratch(); defer { try? FileManager.default.removeItem(at: d) }
        let exe = try script("echo out; echo err >&2; exit 3", in: d)
        let out = try await runner.run(invocation(exe, cwd: d), timeout: 5)
        #expect(out.exitStatus == 3)
        #expect(String(decoding: out.stdout, as: UTF8.self) == "out\n")
        #expect(String(decoding: out.stderr, as: UTF8.self) == "err\n")
    }

    @Test func aProcessThatExitsWithoutReadingStdinDoesNotBreakTheRunner() async throws {
        let d = try scratch(); defer { try? FileManager.default.removeItem(at: d) }
        let exe = try script("exit 0", in: d)
        let big = String(repeating: "x", count: 2_000_000)
        let out = try await runner.run(invocation(exe, stdin: big, cwd: d), timeout: 10)
        #expect(out.exitStatus == 0)
    }

    @Test func aGrandchildHoldingThePipesOpenCannotHangTheRun() async throws {
        let d = try scratch(); defer { try? FileManager.default.removeItem(at: d) }
        let exe = try script("sleep 20 &\necho done", in: d)
        let start = Date()
        let out = try await runner.run(invocation(exe, cwd: d), timeout: 30)
        #expect(String(decoding: out.stdout, as: UTF8.self) == "done\n")
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func stdinArrivesIntactIncludingUnicodeAndTheEnvironmentIsExactlyWhatWasGiven() async throws {
        let d = try scratch(); defer { try? FileManager.default.removeItem(at: d) }
        let text = "line one\nünïcode ✓\n"
        let cat = try await runner.run(invocation(URL(fileURLWithPath: "/bin/cat"), stdin: text, cwd: d), timeout: 5)
        #expect(String(decoding: cat.stdout, as: UTF8.self) == text)

        let env = try await runner.run(invocation(
            URL(fileURLWithPath: "/usr/bin/env"), env: ["PATH": "/usr/bin:/bin", "ONLY": "this"], cwd: d), timeout: 5)
        let keys = Set(String(decoding: env.stdout, as: UTF8.self).split(separator: "\n").compactMap { $0.split(separator: "=").first.map(String.init) })
        #expect(keys == ["PATH", "ONLY"], "nothing from the app's own environment may leak: \(keys)")

        let pwd = try await runner.run(invocation(URL(fileURLWithPath: "/bin/pwd"), cwd: d), timeout: 5)
        // /var is a symlink to /private/var on macOS, so compare the unique last component.
        #expect(String(decoding: pwd.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                .hasSuffix("/" + d.lastPathComponent))
    }
}
