import Foundation
import Testing
import LighthouseAdapter
import LighthouseAppCore
import LighthouseTaskEngine
@testable import LighthouseSupervisor

/// The read-only supervisor queries. The opt-in boundary and the untrusted-text
/// labelling are the load-bearing rules, so failure cases come first.
@Suite("SupervisorQueries")
struct SupervisorQueriesTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func task(_ name: String, supervised: Bool = true, status: String = "") -> TaskRecord {
        TaskRecord(name: name, branch: "lh/\(name)", adapterKind: "claude-code",
            sessionRef: "sess-\(name)", status: status, supervised: supervised,
            workspaces: [Workspace(repoId: UUID(), worktreePath: "/w/\(name)", mergeState: .unmerged)])
    }

    private func ev(
        _ task: TaskRecord?, _ name: String, at t: TimeInterval, message: String? = nil,
        agent: String? = nil, attribution: HookAttribution = .primary,
        notification: String? = nil, toolName: String? = nil, error: String? = nil
    ) -> LoggedHookEvent {
        LoggedHookEvent(taskId: task?.id, attribution: attribution, event: HookEvent(
            receivedAt: Date(timeIntervalSince1970: t), eventName: name,
            sessionId: task?.sessionRef ?? "x", agentId: agent, error: error, toolName: toolName,
            notificationType: notification, lastAssistantMessage: message))
    }

    private func queries(_ tasks: [TaskRecord], _ events: [LoggedHookEvent]) -> SupervisorQueries {
        SupervisorQueries(snapshot: SupervisorSnapshot(tasks: tasks, events: events, now: now))
    }

    // MARK: Opt-in boundary + lookup failures

    @Test func unsupervisedTasksAreInvisibleToEveryQuery() throws {
        let hidden = task("hidden", supervised: false)
        let q = queries([hidden], [ev(hidden, "Stop", at: 1, message: "secret")])
        #expect(try q.listTasks().tasks.isEmpty)
        #expect(throws: SupervisorToolError.self) { try q.recentEvents(task: "hidden", limit: nil) }
        #expect(throws: SupervisorToolError.self) { try q.lastTurn(task: hidden.id.uuidString) }
    }

    /// Existence of an opted-out task must not leak: the refusal for it reads exactly
    /// like the refusal for a name that never existed.
    @Test func unknownAndUnsupervisedLookupsAreIndistinguishable() {
        let q = queries([task("hidden", supervised: false)], [])
        var a = "", b = ""
        do { _ = try q.lastTurn(task: "hidden") } catch { a = "\(error)" }
        do { _ = try q.lastTurn(task: "nope") } catch { b = "\(error)" }
        #expect(!a.isEmpty)
        #expect(a.replacingOccurrences(of: "hidden", with: "X") == b.replacingOccurrences(of: "nope", with: "X"))
    }

    @Test func ambiguousNameIsRefusedNotGuessed() {
        let q = queries([task("dup"), task("DUP")], [])
        #expect(throws: SupervisorToolError.self) { try q.lastTurn(task: "dup") }
    }

    @Test func eventsOfOtherTasksNeverLeak() throws {
        let a = task("a"), b = task("b")
        let q = queries([a, b], [ev(a, "Stop", at: 1, message: "A-only"), ev(b, "Stop", at: 2, message: "B-only")])
        let turn = try #require(try q.lastTurn(task: "a").turn)
        #expect(turn.agentMessageUntrusted == "A-only")
    }

    // MARK: recent_events

    @Test func limitIsClampedAndNilDefaults() throws {
        let t = task("t")
        let events = (0..<80).map { ev(t, "UserPromptSubmit", at: TimeInterval($0)) }
        let q = queries([t], events)
        #expect(try q.recentEvents(task: "t", limit: nil).events.count == SupervisorQueries.defaultEventLimit)
        #expect(try q.recentEvents(task: "t", limit: 10_000).events.count == SupervisorQueries.maxEventLimit)
        #expect(try q.recentEvents(task: "t", limit: 0).events.count == 1)
        #expect(try q.recentEvents(task: "t", limit: -5).events.count == 1)
    }

    @Test func recentEventsAreOldestFirstAndCarryNoMessageText() throws {
        let t = task("t")
        let q = queries([t], [
            ev(t, "Stop", at: 5, message: "hello secret text"),
            ev(t, "UserPromptSubmit", at: 1),
        ])
        let out = try q.recentEvents(task: "t", limit: nil)
        #expect(out.events.map(\.event) == ["UserPromptSubmit", "Stop"])
        let json = String(decoding: try SupervisorJSON.encode(out), as: UTF8.self)
        #expect(!json.contains("hello secret text"))
        #expect(out.events[1].messageChars == 17)
    }

    @Test func subagentAndAttributionAreVisible() throws {
        let t = task("t")
        let q = queries([t], [
            ev(t, "SubagentStop", at: 1, message: "x", agent: "ag1"),
            ev(t, "Stop", at: 2, attribution: .otherSessionInTask),
        ])
        let out = try q.recentEvents(task: "t", limit: nil).events
        #expect(out[0].subagent == true && out[0].session == "primary")
        #expect(out[1].subagent == false && out[1].session == "other_session_in_task")
    }

    @Test func detailIsTheEventSpecificQualifier() throws {
        let t = task("t")
        let q = queries([t], [
            ev(t, "Notification", at: 1, notification: "permission_prompt"),
            ev(t, "PermissionRequest", at: 2, toolName: "AskUserQuestion"),
            ev(t, "StopFailure", at: 3, error: "unknown"),
        ])
        #expect(try q.recentEvents(task: "t", limit: nil).events.map(\.detail)
            == ["permission_prompt", "AskUserQuestion", "unknown"])
    }

    // MARK: last_turn

    @Test func noTurnYetIsNilNotAnError() throws {
        let t = task("t")
        #expect(try queries([t], [ev(t, "UserPromptSubmit", at: 1)]).lastTurn(task: "t").turn == nil)
    }

    @Test func aSubagentStopIsNeverTheTurn() throws {
        let t = task("t")
        let q = queries([t], [ev(t, "SubagentStop", at: 1, message: "suggestion", agent: "ag1")])
        #expect(try q.lastTurn(task: "t").turn == nil)
    }

    @Test func otherSessionsStopIsNotThePrimaryTurn() throws {
        let t = task("t")
        let q = queries([t], [ev(t, "Stop", at: 1, message: "other", attribution: .otherSessionInTask)])
        #expect(try q.lastTurn(task: "t").turn == nil)
    }

    @Test func stopFailureIsAFailureTurnWithItsError() throws {
        let t = task("t")
        let q = queries([t], [ev(t, "StopFailure", at: 1, message: "API Error", error: "unknown")])
        let turn = try #require(try q.lastTurn(task: "t").turn)
        #expect(turn.outcome == "failure" && turn.failureError == "unknown")
        #expect(turn.agentMessageUntrusted == "API Error")
    }

    @Test func suggestionAfterTheStopIsAttachedAndLabelledUntrusted() throws {
        let t = task("t")
        let q = queries([t], [
            ev(t, "Stop", at: 1, message: "done"),
            ev(t, "SubagentStop", at: 3, message: "rebase onto develop", agent: "ag1"),
        ])
        let turn = try #require(try q.lastTurn(task: "t").turn)
        #expect(turn.suggestionUntrusted == "rebase onto develop")
        #expect(turn.outcome == "stop")
    }

    @Test func newerPromptMeansTheTurnIsNoLongerTheLatestActivity() throws {
        let t = task("t")
        let q = queries([t], [
            ev(t, "Stop", at: 1, message: "done"),
            ev(t, "UserPromptSubmit", at: 5),
            ev(t, "PermissionRequest", at: 6, toolName: "AskUserQuestion"),
        ])
        let turn = try #require(try q.lastTurn(task: "t").turn)
        #expect(turn.eventsSince.map(\.event) == ["UserPromptSubmit", "PermissionRequest"])
    }

    @Test func aSuggestionFromAnEarlierTurnIsNotAttachedToALaterStop() throws {
        let t = task("t")
        let q = queries([t], [
            ev(t, "Stop", at: 1, message: "first"),
            ev(t, "SubagentStop", at: 2, message: "old suggestion", agent: "a"),
            ev(t, "UserPromptSubmit", at: 3),
            ev(t, "Stop", at: 4, message: "second"),
        ])
        let turn = try #require(try q.lastTurn(task: "t").turn)
        #expect(turn.agentMessageUntrusted == "second" && turn.suggestionUntrusted == nil)
    }

    // MARK: list_tasks

    @Test func listShowsOnlySupervisedTasksWithLastEventAndAge() throws {
        let a = task("a", status: "waiting on review"), b = task("b", supervised: false)
        let q = queries([a, b], [ev(a, "Stop", at: 9_940)])
        let out = try q.listTasks()
        #expect(out.tasks.map(\.name) == ["a"])
        #expect(out.tasks[0].status == "waiting on review")
        #expect(out.tasks[0].lastEvent?.event == "Stop" && out.tasks[0].lastEvent?.secondsAgo == 60)
        #expect(out.tasks[0].eventsLogged == 1)
    }

    @Test func taskWithNoEventsHasNilLastEvent() throws {
        #expect(try queries([task("a")], []).listTasks().tasks[0].lastEvent == nil)
    }
}
