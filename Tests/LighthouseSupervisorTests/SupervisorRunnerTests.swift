import Foundation
import LighthouseAdapter
import LighthouseAppCore
import LighthouseTaskEngine
import Testing
@testable import LighthouseSupervisor

final class FakeProcess: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<ProcessOutput, ProcessRunError>]
    private var _calls: [SupervisorInvocation] = []
    var delay: TimeInterval = 0
    var onRun: (() -> Void)?
    init(_ results: [Result<ProcessOutput, ProcessRunError>]) { queue = results }
    var calls: [SupervisorInvocation] { lock.lock(); defer { lock.unlock() }; return _calls }
    func run(_ invocation: SupervisorInvocation, timeout: TimeInterval) async throws -> ProcessOutput {
        let next = record(invocation)
        onRun?()
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return try (next ?? .failure(.launchFailed("no more results"))).get()
    }
    private func record(_ invocation: SupervisorInvocation) -> Result<ProcessOutput, ProcessRunError>? {
        lock.withLock {
            _calls.append(invocation)
            return queue.isEmpty ? nil : queue.removeFirst()
        }
    }
    static func ok(cost: Double = 0.04, note: String = "proposed a send") -> Result<ProcessOutput, ProcessRunError> {
        .success(ProcessOutput(exitStatus: 0, stdout: Data(
            #"{"type":"result","subtype":"success","is_error":false,"total_cost_usd":\#(cost),"result":"\#(note)"}"#.utf8), stderr: Data()))
    }
    static func exit(_ code: Int32, stderr: String = "boom") -> Result<ProcessOutput, ProcessRunError> {
        .success(ProcessOutput(exitStatus: code, stdout: Data(), stderr: Data(stderr.utf8)))
    }
}

final class FakeSource: SupervisorSnapshotSource, @unchecked Sendable {
    var tasks: [TaskRecord]
    var events: [LoggedHookEvent]
    var failure: Error?
    init(tasks: [TaskRecord], events: [LoggedHookEvent]) { self.tasks = tasks; self.events = events }
    func snapshot() throws -> SupervisorSnapshot {
        if let failure { throw failure }
        return SupervisorSnapshot(tasks: tasks, events: events)
    }
}

@MainActor
@Suite("SupervisorRunner", .serialized)
struct SupervisorRunnerTests {
    private let clock = Clock()
    private let a = TaskRecord(name: "a", branch: "b", adapterKind: "c", sessionRef: "s", supervised: true, workspaces: [])

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 2_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
    }

    private func dir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("lh-sr-\(UUID().uuidString.prefix(8))") }
    private func stop(after seconds: TimeInterval, name: String = "Stop") -> LoggedHookEvent {
        LoggedHookEvent(taskId: a.id, attribution: .primary, event: HookEvent(
            receivedAt: Date(timeIntervalSince1970: 2_000_000).addingTimeInterval(seconds), eventName: name, sessionId: "s"))
    }
    private func paths(_ d: URL, claude: String = "/bin/sh") -> SupervisorPaths {
        SupervisorPaths(claude: URL(fileURLWithPath: claude), mcpServer: URL(fileURLWithPath: "/bin/sh"),
                        workDirectory: d.appendingPathComponent("work"), lighthouseDirectory: d, home: "/h", user: "u", path: "/usr/bin:/bin")
    }
    private func make(
        _ d: URL, process: FakeProcess, source: FakeSource, enabled: Bool = true, claude: String = "/bin/sh",
        tweak: (inout SupervisorSettings) -> Void = { _ in }
    ) throws -> SupervisorRunner {
        let clock = self.clock
        let runner = SupervisorRunner(
            directory: d, source: source, process: process, paths: paths(d, claude: claude),
            now: { clock.now }, calendar: Calendar(identifier: .gregorian))
        var s = SupervisorSettings()
        s.enabled = enabled; s.instructions = "when a finishes tell b"; s.debounceSeconds = 0
        tweak(&s)
        try runner.update(s)
        return runner
    }
    private func ran(_ r: EvaluationResult) -> RunRecord? { if case .ran(let rec) = r { return rec }; return nil }
    private func skipped(_ r: EvaluationResult) -> SkipReason? { if case .skipped(let s) = r { return s }; return nil }

    // MARK: Failure modes first

    @Test func disabledNeverRunsAnything() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let p = FakeProcess([FakeProcess.ok()])
        let r = try make(d, process: p, source: FakeSource(tasks: [a], events: [stop(after: 10)]), enabled: false)
        #expect(skipped(await r.evaluate(trigger: .manual)) == .disabled)
        #expect(p.calls.isEmpty)
    }

    @Test func enablingDoesNotWakeForHistory() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let p = FakeProcess([FakeProcess.ok()])
        clock.advance(1_000)
        let r = try make(d, process: p, source: FakeSource(tasks: [a], events: [stop(after: 10)]))
        #expect(skipped(await r.evaluate(trigger: .automatic)) == .nothingNew, "that turn ended before it was enabled")
        #expect(p.calls.isEmpty)
        #expect(r.state.since != nil)
    }

    @Test func aFailedRunNeverAdvancesTheWatermarkAndIsRetriedOnceThenGivenUpOn() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let p = FakeProcess([FakeProcess.exit(1), FakeProcess.exit(1), FakeProcess.ok()])
        let src = FakeSource(tasks: [a], events: [])
        let r = try make(d, process: p, source: src) { $0.failureBreaker = 10 }
        _ = await r.evaluate(trigger: .automatic) // opens the enabled period
        src.events = [stop(after: 10)]; clock.advance(60)

        #expect(ran(await r.evaluate(trigger: .automatic))?.ok == false)
        #expect(r.state.watermarks.isEmpty)
        #expect(ran(await r.evaluate(trigger: .automatic))?.ok == false, "one retry")
        #expect(skipped(await r.evaluate(trigger: .automatic)) == .nothingNew, "then given up on that turn")
        #expect(p.calls.count == 2)
    }

    @Test func timeoutMalformedOutputAndMissingCostAreFailuresAndSpendIsNeverFree() async throws {
        let cases: [(Result<ProcessOutput, ProcessRunError>, String)] = [
            (.failure(.timedOut), "timed out"),
            (.failure(.outputTooLarge), "too much output"),
            (.failure(.launchFailed("nope")), "could not be started"),
            (.success(ProcessOutput(exitStatus: 0, stdout: Data("garbage".utf8), stderr: Data())), "not a result"),
            (.success(ProcessOutput(exitStatus: 0, stdout: Data(#"{"type":"result","subtype":"success","is_error":false,"result":"x"}"#.utf8), stderr: Data())), "no cost"),
        ]
        for (result, fragment) in cases {
            let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
            let src = FakeSource(tasks: [a], events: [])
            let r = try make(d, process: FakeProcess([result]), source: src) { $0.maxBudgetPerRunUSD = 0.3 }
            _ = await r.evaluate(trigger: .automatic)
            src.events = [stop(after: 10)]; clock.advance(60)
            let rec = try #require(ran(await r.evaluate(trigger: .automatic)))
            #expect(!rec.ok && rec.note.contains(fragment), "\(fragment): \(rec.note)")
            #expect(rec.costUSD == 0.3, "unknown cost is recorded as the most the run could have cost")
            clock.advance(-60)
        }
    }

    @Test func aFailedRunThatReportedItsCostIsChargedExactly() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let budget = ProcessOutput(exitStatus: 1, stdout: Data(
            #"{"type":"result","subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":0.21}"#.utf8), stderr: Data())
        let src = FakeSource(tasks: [a], events: [])
        let r = try make(d, process: FakeProcess([.success(budget)]), source: src)
        _ = await r.evaluate(trigger: .automatic)
        src.events = [stop(after: 10)]; clock.advance(60)
        #expect(ran(await r.evaluate(trigger: .automatic))?.costUSD == 0.21)
    }

    @Test func breakerHaltsAfterConsecutiveFailuresAndTheHaltSurvivesARestart() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = FakeSource(tasks: [a], events: [])
        let r = try make(d, process: FakeProcess([FakeProcess.exit(1), FakeProcess.exit(1)]), source: src) { $0.failureBreaker = 2 }
        _ = await r.evaluate(trigger: .automatic)
        src.events = [stop(after: 10)]; clock.advance(60)
        _ = await r.evaluate(trigger: .automatic); _ = await r.evaluate(trigger: .automatic)
        #expect(r.state.haltReason != nil)

        let p2 = FakeProcess([FakeProcess.ok()])
        let again = SupervisorRunner(directory: d, source: src, process: p2, paths: paths(d),
                                     now: { [clock] in clock.now }, calendar: Calendar(identifier: .gregorian))
        if case .halted? = skipped(await again.evaluate(trigger: .manual)) {} else { Issue.record("halt must survive a restart and block manual runs") }
        #expect(p2.calls.isEmpty)

        try again.resume()
        src.events = [stop(after: 10), stop(after: 200)]
        #expect(ran(await again.evaluate(trigger: .manual)) != nil, "the user's explicit resume lifts the halt")
    }

    @Test func unreadableStateOrSettingsStopsEverythingAndIsNotOverwritten() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let bad = Data("{ not state".utf8)
        let file = d.appendingPathComponent("supervisor-state.json")
        try bad.write(to: file)
        let p = FakeProcess([FakeProcess.ok()])
        let r = SupervisorRunner(directory: d, source: FakeSource(tasks: [a], events: [stop(after: 10)]), process: p,
                                 paths: paths(d), now: { [clock] in clock.now })
        #expect(r.loadError != nil)
        #expect(throws: SupervisorError.self) { try r.update(SupervisorSettings()) }
        #expect(throws: SupervisorError.self) { try r.resume() }
        _ = await r.evaluate(trigger: .manual)
        #expect(p.calls.isEmpty)
        #expect(try Data(contentsOf: file) == bad)
    }

    @Test func ifTheRecordCannotBeSavedItHaltsRatherThanRunBlind() async throws {
        let d = dir(); defer { chmod(d.path, 0o700); try? FileManager.default.removeItem(at: d) }
        let p = FakeProcess([FakeProcess.ok(), FakeProcess.ok()])
        p.onRun = { chmod(d.path, 0o500) } // the state directory becomes unwritable mid-run
        let src = FakeSource(tasks: [a], events: [])
        let r = try make(d, process: p, source: src)
        _ = await r.evaluate(trigger: .automatic)
        src.events = [stop(after: 10)]; clock.advance(60)
        #expect(ran(await r.evaluate(trigger: .automatic)) != nil)
        #expect(r.state.haltReason?.contains("could not be saved") == true)
        if case .halted? = skipped(await r.evaluate(trigger: .automatic)) {} else { Issue.record("must not run again") }
        #expect(p.calls.count == 1)
    }

    @Test func missingBinariesSkipWithoutLaunching() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let p = FakeProcess([FakeProcess.ok()])
        let src = FakeSource(tasks: [a], events: [])
        let r = try make(d, process: p, source: src, claude: "/nonexistent/claude")
        _ = await r.evaluate(trigger: .automatic)
        src.events = [stop(after: 10)]; clock.advance(60)
        if case .misconfigured? = skipped(await r.evaluate(trigger: .automatic)) {} else { Issue.record("expected misconfigured") }
        #expect(p.calls.isEmpty)
    }

    @Test func aSnapshotThatCannotBeReadIsASkipNotAQuietSystem() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = FakeSource(tasks: [a], events: [])
        src.failure = CocoaError(.fileReadCorruptFile)
        let r = try make(d, process: FakeProcess([]), source: src)
        if case .snapshotUnavailable? = skipped(await r.evaluate(trigger: .automatic)) {} else { Issue.record("expected snapshotUnavailable") }
    }

    @Test func aSecondEvaluateDuringARunIsTurnedAway() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let p = FakeProcess([FakeProcess.ok()])
        p.delay = 0.3
        let src = FakeSource(tasks: [a], events: [])
        let r = try make(d, process: p, source: src)
        _ = await r.evaluate(trigger: .automatic)
        src.events = [stop(after: 10)]; clock.advance(60)
        async let first = r.evaluate(trigger: .automatic)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(skipped(await r.evaluate(trigger: .manual)) == .runInFlight)
        #expect(ran(await first) != nil)
        #expect(p.calls.count == 1)
    }

    // MARK: Happy path

    @Test func aFinishedTurnRunsOnceRecordsSpendAndDoesNotRepeatAfterARestart() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let p = FakeProcess([FakeProcess.ok(cost: 0.07, note: "queued a send to b")])
        let src = FakeSource(tasks: [a], events: [])
        let r = try make(d, process: p, source: src)
        _ = await r.evaluate(trigger: .automatic)
        src.events = [stop(after: 10)]; clock.advance(60)

        let rec = try #require(ran(await r.evaluate(trigger: .automatic)))
        #expect(rec.ok && rec.costUSD == 0.07 && rec.taskNames == ["a"] && rec.note == "queued a send to b")
        #expect(skipped(await r.evaluate(trigger: .automatic)) == .nothingNew)

        let again = SupervisorRunner(directory: d, source: src, process: FakeProcess([FakeProcess.ok()]), paths: paths(d),
                                     now: { [clock] in clock.now })
        #expect(skipped(await again.evaluate(trigger: .automatic)) == .nothingNew, "the watermark is persisted")
        #expect(again.state.runs.count == 1)

        let inv = try #require(p.calls.first)
        #expect(inv.stdin.contains(a.id.uuidString))
        let mcp = paths(d).mcpConfig
        #expect(FileManager.default.fileExists(atPath: mcp.path))
        #expect(((try FileManager.default.attributesOfItem(atPath: mcp.path)[.posixPermissions]) as? NSNumber)?.intValue == 0o600)
    }

    @Test func theLedgerOfEarlierNotesFeedsTheNextRun() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let p = FakeProcess([FakeProcess.ok(note: "told b to start"), FakeProcess.ok(note: "second")])
        let src = FakeSource(tasks: [a], events: [])
        let r = try make(d, process: p, source: src)
        _ = await r.evaluate(trigger: .automatic)
        src.events = [stop(after: 10)]; clock.advance(60)
        _ = await r.evaluate(trigger: .automatic)
        src.events.append(stop(after: 100)); clock.advance(200)
        _ = await r.evaluate(trigger: .automatic)
        #expect(p.calls.count == 2)
        #expect(p.calls[1].stdin.contains("told b to start"))
    }
}
