import Foundation
import LighthouseAdapter
import LighthouseAppCore
import LighthouseTaskEngine
import Testing
@testable import LighthouseSupervisor

@MainActor
final class FakeEvaluator: SupervisorEvaluating {
    var automaticEnabled = true
    var results: [EvaluationResult] = []
    private(set) var triggers: [WakeTrigger] = []
    private var inFlight = 0
    /// The most evaluations ever running at once — the runner must never be asked twice at once.
    private(set) var maxConcurrent = 0
    /// When set, `evaluate` suspends here until released — lets a test inject events mid-run.
    var gate: CheckedContinuation<Void, Never>?
    var holdFirst = false
    var onEvaluate: (() -> Void)?

    func evaluate(trigger: WakeTrigger) async -> EvaluationResult {
        triggers.append(trigger)
        inFlight += 1; maxConcurrent = max(maxConcurrent, inFlight)
        defer { inFlight -= 1 }
        onEvaluate?()
        if holdFirst && triggers.count == 1 { await withCheckedContinuation { gate = $0 } }
        await Task.yield()
        return results.isEmpty ? .skipped(.nothingNew) : results.removeFirst()
    }
    func release() { gate?.resume(); gate = nil }
}

@MainActor
@Suite("SupervisorAutoWaker", .serialized)
struct SupervisorAutoWakerTests {
    private let t0 = Date(timeIntervalSince1970: 3_000_000)
    private func ev(_ name: String, agent: String? = nil, attribution: HookAttribution = .primary) -> LoggedHookEvent {
        LoggedHookEvent(taskId: UUID(), attribution: attribution, event: HookEvent(
            receivedAt: t0, eventName: name, sessionId: "s", agentId: agent))
    }
    private func ran() -> EvaluationResult {
        .ran(RunRecord(startedAt: t0, trigger: .automatic, taskNames: ["a"], ok: true, costUSD: 0.02, note: "n"))
    }
    private func make(_ e: FakeEvaluator, slept: SleepLog = SleepLog(), maxDebounceWaits: Int = 20) -> SupervisorAutoWaker {
        SupervisorAutoWaker(runner: e, sleep: { await slept.record($0) }, now: { Date(timeIntervalSince1970: 3_000_000) },
                            maxDebounceWaits: maxDebounceWaits)
    }

    // MARK: Things that must never trigger a run

    @Test func onlyAPrimaryTurnEndTriggers() async {
        let e = FakeEvaluator(); let w = make(e)
        for event in [ev("UserPromptSubmit"), ev("SessionStart"), ev("PermissionRequest"), ev("PostToolUse"),
                      ev("Notification"), ev("SessionEnd"),
                      ev("SubagentStop", agent: "h"), ev("Stop", agent: "sub"),
                      ev("Stop", attribution: .otherSessionInTask), ev("Stop", attribution: .unattributed)] {
            w.eventRecorded(event)
        }
        await w.idle()
        #expect(e.triggers.isEmpty)
    }

    @Test func nothingRunsWhileAutomaticIsOffOrTheSupervisorIsHalted() async {
        let e = FakeEvaluator(); e.automaticEnabled = false
        let w = make(e)
        w.eventRecorded(ev("Stop")); w.eventRecorded(ev("StopFailure"))
        await w.idle()
        #expect(e.triggers.isEmpty)
    }

    @Test func switchingAutomaticOffMidLoopStopsIt() async {
        let e = FakeEvaluator()
        e.results = [.skipped(.debouncing(until: t0.addingTimeInterval(5))), ran()]
        e.onEvaluate = { [unowned e] in if e.triggers.count == 1 { e.automaticEnabled = false } }
        let w = make(e)
        w.eventRecorded(ev("Stop"))
        await w.idle()
        #expect(e.triggers.count == 1, "after the first pass the switch is off, so no second pass")
    }

    // MARK: Triggering and coalescing

    @Test func aTurnEndRunsOneAutomaticEvaluation() async {
        let e = FakeEvaluator(); e.results = [ran()]
        let w = make(e)
        w.eventRecorded(ev("Stop"))
        await w.idle()
        #expect(e.triggers == [.automatic])
    }

    @Test func aStopFailureTriggersToo() async {
        let e = FakeEvaluator(); let w = make(e)
        w.eventRecorded(ev("StopFailure"))
        await w.idle()
        #expect(e.triggers == [.automatic])
    }

    @Test func aBurstOfTurnEndsIsOneEvaluation() async {
        let e = FakeEvaluator(); let w = make(e)
        for _ in 0..<5 { w.eventRecorded(ev("Stop")) }
        await w.idle()
        #expect(e.triggers.count == 1)
    }

    @Test func aTurnEndDuringARunGetsExactlyOneFollowUp() async {
        let e = FakeEvaluator(); e.holdFirst = true; e.results = [ran(), .skipped(.nothingNew)]
        let w = make(e)
        w.eventRecorded(ev("Stop"))
        await Task.yield(); await Task.yield()
        #expect(e.triggers.count == 1, "the first run is in flight")
        for _ in 0..<3 { w.eventRecorded(ev("Stop")) }
        e.release()
        await w.idle()
        #expect(e.triggers.count == 2, "the burst during the run is one re-check, not three")
        #expect(e.maxConcurrent == 1, "evaluations must never overlap")
    }

    @Test func aRunThatSeesNoNewEventsIsNotRepeated() async {
        let e = FakeEvaluator(); e.results = [ran(), ran(), ran()]
        let w = make(e)
        w.eventRecorded(ev("Stop"))
        await w.idle()
        #expect(e.triggers.count == 1, "a failed or finished run is not retried without a new event")
    }

    // MARK: Debounce

    @Test func aDebounceSkipSleepsUntilTheTimeThenTriesAgain() async {
        let e = FakeEvaluator()
        e.results = [.skipped(.debouncing(until: t0.addingTimeInterval(4))), ran()]
        let slept = SleepLog(); let w = make(e, slept: slept)
        w.eventRecorded(ev("Stop"))
        await w.idle()
        #expect(e.triggers.count == 2)
        let durations = await slept.values
        #expect(durations.count == 1 && abs(durations[0] - 4.05) < 0.001, "\(durations)")
    }

    @Test func aDebounceThatNeverClearsIsGivenUpOnNotLoopedForever() async {
        let e = FakeEvaluator()
        e.results = Array(repeating: .skipped(.debouncing(until: t0.addingTimeInterval(1))), count: 100)
        let w = make(e, maxDebounceWaits: 3)
        w.eventRecorded(ev("Stop"))
        await w.idle()
        #expect(e.triggers.count == 4, "the first look plus three waits")
        // A later turn end starts a fresh round.
        e.results = [ran()]
        w.eventRecorded(ev("Stop"))
        await w.idle()
        #expect(e.triggers.count == 5)
    }

    @Test func otherSkipsEndTheRoundWithoutSleeping() async {
        for reason in [SkipReason.nothingNew, .hourlyCap(20), .dailyCap(spent: 5, cap: 5), .misconfigured("x"), .automaticOff] {
            let e = FakeEvaluator(); e.results = [.skipped(reason)]
            let slept = SleepLog(); let w = make(e, slept: slept)
            w.eventRecorded(ev("Stop"))
            await w.idle()
            #expect(e.triggers.count == 1)
            #expect(await slept.values.isEmpty)
        }
    }
}

actor SleepLog {
    private(set) var values: [TimeInterval] = []
    func record(_ d: TimeInterval) { values.append(d) }
}

@Suite("Automatic policy")
struct AutomaticPolicyTests {
    private let a = TaskRecord(name: "a", branch: "b", adapterKind: "c", sessionRef: "s", supervised: true, workspaces: [])
    private func decide(_ trigger: WakeTrigger, automatic: Bool) -> WakeDecision {
        var s = SupervisorSettings(); s.enabled = true; s.automatic = automatic; s.instructions = "x"; s.debounceSeconds = 0
        var st = SupervisorState(); st.since = Date(timeIntervalSince1970: 0)
        let stop = LoggedHookEvent(taskId: a.id, attribution: .primary, event: HookEvent(
            receivedAt: Date(timeIntervalSince1970: 100), eventName: "Stop", sessionId: "s"))
        return WakePolicy.decide(trigger: trigger, settings: s, state: st, tasks: [a], events: [stop],
                                 now: Date(timeIntervalSince1970: 200), calendar: Calendar(identifier: .gregorian))
    }

    @Test func automaticOffBlocksAutomaticButNeverManual() {
        #expect(decide(.automatic, automatic: false) == .skip(.automaticOff))
        if case .wake = decide(.manual, automatic: false) {} else { Issue.record("manual must still run") }
        if case .wake = decide(.automatic, automatic: true) {} else { Issue.record("automatic on must wake") }
    }

    @Test func automaticIsOffByDefault() {
        #expect(SupervisorSettings().automatic == false)
    }
}

/// The whole automatic chain with the real runner, the persisted event log and a fake
/// process: event → waker → policy → run → watermark.
@MainActor
@Suite("Automatic runs end to end", .serialized)
struct AutomaticEndToEndTests {
    private let base = Date(timeIntervalSince1970: 4_000_000)
    private let a = TaskRecord(name: "a", branch: "b", adapterKind: "c", sessionRef: "sa", supervised: true, workspaces: [])

    private func dir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("lh-auto-\(UUID().uuidString.prefix(8))") }
    private func logStop(_ sink: HookEventSink, at offset: TimeInterval, name: String = "Stop") throws -> LoggedHookEvent {
        let logged = LoggedHookEvent(taskId: a.id, attribution: .primary, event: HookEvent(
            receivedAt: base.addingTimeInterval(offset), eventName: name, sessionId: "sa"))
        try sink.append(logged)
        return logged
    }

    @Test func aFinishedTurnRunsOnceAndTheSameTurnIsNotRunAgain() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        try ConfigStore(directory: d).save(LighthouseConfig(tasks: [a]))
        let sink = HookEventSink(directory: d)
        let proc = FakeProcess([FakeProcess.ok(), FakeProcess.ok()])
        let clock = AutoClock(base.addingTimeInterval(1))
        let paths = SupervisorPaths(claude: URL(fileURLWithPath: "/bin/sh"), mcpServer: URL(fileURLWithPath: "/bin/sh"),
                                    workDirectory: d.appendingPathComponent("work"), lighthouseDirectory: d,
                                    home: "/h", user: "u", path: "/usr/bin:/bin")
        let runner = SupervisorRunner(directory: d, source: FileSnapshotSource(directory: d), process: proc,
                                      paths: paths, now: { clock.now }, calendar: Calendar(identifier: .gregorian))
        var s = SupervisorSettings(); s.enabled = true; s.automatic = true; s.instructions = "x"; s.debounceSeconds = 0
        try runner.update(s)
        let waker = SupervisorAutoWaker(runner: runner)

        // Opens the enabled period (nothing to look at yet).
        _ = await runner.evaluate(trigger: .automatic)
        clock.set(base.addingTimeInterval(100))

        waker.eventRecorded(try logStop(sink, at: 50))
        await waker.idle()
        #expect(proc.calls.count == 1, "the finished turn woke the supervisor")
        #expect(runner.state.runs.count == 1 && runner.state.runs[0].trigger == .automatic)

        // The trailing next-prompt helper and a notification must not wake it again.
        waker.eventRecorded(LoggedHookEvent(taskId: a.id, attribution: .primary, event: HookEvent(
            receivedAt: base.addingTimeInterval(52), eventName: "SubagentStop", sessionId: "sa", agentId: "h")))
        await waker.idle()
        #expect(proc.calls.count == 1)

        // A second, later turn does.
        clock.set(base.addingTimeInterval(300))
        waker.eventRecorded(try logStop(sink, at: 250))
        await waker.idle()
        #expect(proc.calls.count == 2)
        #expect(runner.state.runs.count == 2)
    }

    @Test func automaticOffNeverRunsEvenForAFinishedTurn() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        try ConfigStore(directory: d).save(LighthouseConfig(tasks: [a]))
        let sink = HookEventSink(directory: d)
        let proc = FakeProcess([FakeProcess.ok()])
        let clock = AutoClock(base.addingTimeInterval(1))
        let paths = SupervisorPaths(claude: URL(fileURLWithPath: "/bin/sh"), mcpServer: URL(fileURLWithPath: "/bin/sh"),
                                    workDirectory: d.appendingPathComponent("work"), lighthouseDirectory: d,
                                    home: "/h", user: "u", path: "/usr/bin:/bin")
        let runner = SupervisorRunner(directory: d, source: FileSnapshotSource(directory: d), process: proc,
                                      paths: paths, now: { clock.now }, calendar: Calendar(identifier: .gregorian))
        var s = SupervisorSettings(); s.enabled = true; s.automatic = false; s.instructions = "x"; s.debounceSeconds = 0
        try runner.update(s)
        let waker = SupervisorAutoWaker(runner: runner)
        clock.set(base.addingTimeInterval(100))
        waker.eventRecorded(try logStop(sink, at: 50))
        await waker.idle()
        #expect(proc.calls.isEmpty)
        // …while Run now still works.
        if case .ran = await runner.evaluate(trigger: .manual) {} else { Issue.record("manual must still run") }
    }
}

final class AutoClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date) { self.t = t }
    var now: Date { lock.withLock { t } }
    func set(_ new: Date) { lock.withLock { t = new } }
}
