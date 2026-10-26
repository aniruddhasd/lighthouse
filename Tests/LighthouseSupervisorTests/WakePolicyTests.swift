import Foundation
import LighthouseAdapter
import LighthouseAppCore
import LighthouseTaskEngine
import Testing
@testable import LighthouseSupervisor

/// The wake policy decides when the supervisor model runs, so every way it could wake
/// wrongly — or fail to stop — is a test before the happy path.
@Suite("WakePolicy")
struct WakePolicyTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let a = TaskRecord(name: "a", branch: "b", adapterKind: "c", sessionRef: "s", supervised: true, workspaces: [])
    private var enabled: SupervisorSettings {
        var s = SupervisorSettings()
        s.enabled = true
        s.instructions = "when a finishes, tell b to start"
        return s
    }
    private func state(since: TimeInterval = -1_000) -> SupervisorState {
        var s = SupervisorState()
        s.since = t0.addingTimeInterval(since)
        return s
    }
    private func ev(_ name: String, at offset: TimeInterval, agent: String? = nil,
                    attribution: HookAttribution = .primary, task: TaskRecord? = nil) -> LoggedHookEvent {
        LoggedHookEvent(taskId: (task ?? a).id, attribution: attribution, event: HookEvent(
            receivedAt: t0.addingTimeInterval(offset), eventName: name, sessionId: "s", agentId: agent))
    }
    private func decide(
        _ trigger: WakeTrigger = .automatic, settings: SupervisorSettings? = nil, state st: SupervisorState? = nil,
        tasks: [TaskRecord]? = nil, events: [LoggedHookEvent], now: TimeInterval = 100
    ) -> WakeDecision {
        WakePolicy.decide(
            trigger: trigger, settings: settings ?? enabled, state: st ?? state(), tasks: tasks ?? [a],
            events: events, now: t0.addingTimeInterval(now), calendar: Calendar(identifier: .gregorian))
    }
    private func skipReason(_ d: WakeDecision) -> SkipReason? {
        if case .skip(let r) = d { return r }
        return nil
    }
    private func run(at offset: TimeInterval, cost: Double = 0.1, ok: Bool = true, note: String = "n") -> RunRecord {
        RunRecord(startedAt: t0.addingTimeInterval(offset), trigger: .automatic, taskNames: ["a"], ok: ok, costUSD: cost, note: note)
    }

    // MARK: Things that must never wake it

    @Test func disabledNeverWakes() {
        var s = enabled; s.enabled = false
        #expect(skipReason(decide(settings: s, events: [ev("Stop", at: 10)])) == .disabled)
    }

    @Test func haltedNeverWakesEvenWhenManual() {
        var st = state(); st.haltReason = "3 runs failed"
        for t in [WakeTrigger.automatic, .manual] {
            #expect(skipReason(decide(t, state: st, events: [ev("Stop", at: 10)])) == .halted("3 runs failed"))
        }
    }

    @Test func missingInstructionsOrBadSettingsNeverWake() {
        var s = enabled; s.instructions = "  \n "
        #expect(skipReason(decide(settings: s, events: [ev("Stop", at: 10)])) == .noInstructions)
        var bad = enabled; bad.model = "--dangerously-skip-permissions"
        if case .invalidSettings(let p)? = skipReason(decide(settings: bad, events: [ev("Stop", at: 10)])) {
            #expect(!p.isEmpty)
        } else { Issue.record("a model name that parses as a flag must stop the run") }
    }

    @Test func subagentNextPromptHelperAndNotificationsNeverTrigger() {
        let events = [ev("UserPromptSubmit", at: 0), ev("SubagentStop", at: 10, agent: "h"), ev("Notification", at: 11)]
        #expect(skipReason(decide(events: events)) == .nothingNew)
        let sub = [ev("Stop", at: 10, agent: "sub-1")]
        #expect(skipReason(decide(events: sub)) == .nothingNew, "a subagent's Stop is not a turn boundary")
    }

    @Test func otherSessionsAndUnsupervisedTasksNeverTrigger() {
        #expect(skipReason(decide(events: [ev("Stop", at: 10, attribution: .otherSessionInTask)])) == .nothingNew)
        var off = a; off.supervised = false
        #expect(skipReason(decide(tasks: [off], events: [ev("Stop", at: 10, task: off)])) == .nothingNew)
    }

    @Test func historyBeforeTheEnabledPeriodNeverTriggers() {
        // The turn ended at -500; the supervisor was enabled at -100.
        #expect(skipReason(decide(state: state(since: -100), events: [ev("Stop", at: -500)])) == .nothingNew)
    }

    @Test func noEnabledPeriodMeansNothingAutomaticallyFailClosed() {
        var st = state(); st.since = nil
        #expect(skipReason(decide(state: st, events: [ev("Stop", at: 10)])) == .nothingNew)
    }

    @Test func aTurnTheUserAlreadyMovedPastIsNotPending() {
        #expect(skipReason(decide(events: [ev("Stop", at: 10), ev("UserPromptSubmit", at: 20)])) == .nothingNew)
        #expect(skipReason(decide(events: [ev("Stop", at: 10), ev("SessionEnd", at: 20)])) == .nothingNew)
    }

    @Test func aDanglingQuestionnaireAfterTheStopIsNotPending() {
        #expect(skipReason(decide(events: [ev("Stop", at: 10), ev("PermissionRequest", at: 20)])) == .nothingNew)
    }

    // MARK: Watermark and retries

    @Test func aConsideredTurnDoesNotWakeAgainEvenAfterARestart() {
        var st = state()
        st.watermarks[a.id.uuidString] = t0.addingTimeInterval(10.4) // persisted with whole seconds only
        #expect(skipReason(decide(state: st, events: [ev("Stop", at: 10.9)])) == .nothingNew)
        #expect(decide(state: st, events: [ev("Stop", at: 30)]) != .skip(.nothingNew))
    }

    @Test func aTurnThatFailedTwiceIsGivenUpOnButANewTurnIsNot() {
        var st = state()
        st.attempts[a.id.uuidString] = TurnAttempt(turn: t0.addingTimeInterval(10), count: SupervisorState.maxAttemptsPerTurn)
        #expect(skipReason(decide(state: st, events: [ev("Stop", at: 10)])) == .nothingNew)
        #expect(decide(state: st, events: [ev("Stop", at: 50)]) != .skip(.nothingNew))
        st.attempts[a.id.uuidString]?.count = 1
        #expect(decide(state: st, events: [ev("Stop", at: 10)]) != .skip(.nothingNew), "one failure still allows a retry")
    }

    // MARK: Caps and debounce

    @Test func hourlyCapSkipsWithItsReason() {
        var s = enabled; s.maxWakesPerHour = 2
        var st = state(); st.runs = [run(at: 10), run(at: 20)]
        #expect(skipReason(decide(settings: s, state: st, events: [ev("Stop", at: 50)])) == .hourlyCap(2))
        st.runs = [run(at: -4_000), run(at: -3_700)] // older than an hour
        #expect(decide(settings: s, state: st, events: [ev("Stop", at: 50)]) != .skip(.hourlyCap(2)))
    }

    @Test func dailyCapCountsSpendSinceMidnightAndSkips() {
        var s = enabled; s.maxDailySpendUSD = 1.0
        var st = state(); st.runs = [run(at: 5, cost: 0.6), run(at: 6, cost: 0.5)]
        if case .dailyCap(let spent, let cap)? = skipReason(decide(settings: s, state: st, events: [ev("Stop", at: 50)])) {
            #expect(abs(spent - 1.1) < 1e-9 && cap == 1.0)
        } else { Issue.record("spend at the cap must skip") }
    }

    @Test func debounceWaitsForABurstToSettleButManualDoesNot() {
        let events = [ev("Stop", at: 98)] // 2 s ago, debounce is 5 s
        #expect(skipReason(decide(events: events)) == .debouncing(until: t0.addingTimeInterval(103)))
        #expect(decide(.manual, events: events) != .skip(.debouncing(until: t0.addingTimeInterval(103))))
        #expect(decide(events: events, now: 104) != .skip(.debouncing(until: t0.addingTimeInterval(103))))
    }

    // MARK: Waking

    @Test func aFinishedTurnWakesWithItsFacts() {
        guard case .wake(let turns) = decide(events: [ev("UserPromptSubmit", at: 0), ev("Stop", at: 10), ev("SubagentStop", at: 12, agent: "h")]) else {
            Issue.record("expected a wake"); return
        }
        #expect(turns == [PendingTurn(taskId: a.id, taskName: "a", endedAt: t0.addingTimeInterval(10), outcome: "stop")])
    }

    @Test func aFailedTurnWakesAsStopFailure() {
        guard case .wake(let turns) = decide(events: [ev("StopFailure", at: 10)]) else { Issue.record("expected a wake"); return }
        #expect(turns.first?.outcome == "stop_failure")
    }

    @Test func manualLooksAtTheLatestTurnEvenIfAlreadyConsideredOrGivenUp() {
        var st = state()
        st.watermarks[a.id.uuidString] = t0.addingTimeInterval(50)
        #expect(decide(.manual, state: st, events: [ev("Stop", at: 10)]) != .skip(.nothingNew))
        // …but not a turn the user already moved past
        #expect(skipReason(decide(.manual, state: st, events: [ev("Stop", at: 10), ev("UserPromptSubmit", at: 11)])) == .nothingNew)
    }

    // MARK: Breaker

    @Test func breakerTripsOnTrailingFailuresOnly() {
        let runs = [run(at: 1, ok: false), run(at: 2), run(at: 3, ok: false, note: "boom"), run(at: 4, ok: false)]
        #expect(WakePolicy.haltReason(afterRuns: runs, threshold: 3) == nil)
        #expect(WakePolicy.haltReason(afterRuns: runs, threshold: 2)?.contains("2 supervisor runs") == true)
        #expect(WakePolicy.haltReason(afterRuns: [], threshold: 1) == nil)
    }
}
