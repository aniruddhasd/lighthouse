import Foundation
import Testing
import LighthouseTaskEngine
@testable import LighthouseAppCore

@Suite("NotificationDecider (full matrix)")
struct NotificationDeciderTests {
    private let task = UUID()

    private func t(_ event: AttentionEvent, _ old: TaskAttentionState, _ new: TaskAttentionState) -> AttentionTransition {
        AttentionTransition(taskId: task, event: event, oldState: old, newState: new)
    }

    // MARK: Never notify for the task the user is looking at

    @Test func viewedTaskNeverNotifies() {
        // Even the money transition is suppressed when currently viewed.
        for transition in [
            t(.agentNeedsInput, .working, .needsInput),
            t(.agentStopped, .working, .done),
            t(.sessionDied, .working, .dirty),
        ] {
            #expect(NotificationDecider.decide(transition, isCurrentlyViewed: true) == nil)
        }
    }

    // MARK: The three notifying transitions (when NOT viewed)

    @Test func needsInputNotifiesOnEntry() {
        #expect(NotificationDecider.decide(
            t(.agentNeedsInput, .working, .needsInput), isCurrentlyViewed: false) == .needsInput)
        #expect(NotificationDecider.decide(
            t(.mergeConflicted, .working, .needsInput), isCurrentlyViewed: false) == .needsInput)
    }

    @Test func doneNotifiesOnEntry() {
        #expect(NotificationDecider.decide(
            t(.agentStopped, .working, .done), isCurrentlyViewed: false) == .done)
        #expect(NotificationDecider.decide(
            t(.mergeCompleted, .working, .done), isCurrentlyViewed: false) == .done)
    }

    @Test func sessionDiedNotifies() {
        #expect(NotificationDecider.decide(
            t(.sessionDied, .working, .dirty), isCurrentlyViewed: false) == .sessionDied)
    }

    // MARK: No notification on non-entry / irrelevant transitions

    @Test func repeatEntryDoesNotRenotify() {
        // needsInput → needsInput isn't a real transition (guarded upstream),
        // but if oldState already is the target, don't notify.
        #expect(NotificationDecider.decide(
            t(.agentNeedsInput, .needsInput, .needsInput), isCurrentlyViewed: false) == nil)
        #expect(NotificationDecider.decide(
            t(.agentStopped, .done, .done), isCurrentlyViewed: false) == nil)
    }

    @Test func workingAndWorkspaceEventsNeverNotify() {
        for event in [AttentionEvent.agentWorking, .mergeStarted,
                      .workspaceDirtyDetected, .workspaceCleanDetected] {
            #expect(NotificationDecider.decide(
                t(event, .done, .working), isCurrentlyViewed: false) == nil)
        }
    }

    @Test func dirtyFromWorkspaceEditIsNotASessionDeath() {
        // workspaceDirtyDetected → dirty must NOT masquerade as sessionDied.
        #expect(NotificationDecider.decide(
            t(.workspaceDirtyDetected, .done, .dirty), isCurrentlyViewed: false) == nil)
    }
}

@Suite("InboxOrder (table)")
struct InboxOrderTests {
    private func item(_ name: String, _ state: TaskAttentionState, _ secondsAgo: TimeInterval) -> InboxItem {
        InboxItem(id: UUID(), name: name, state: state,
                  since: Date(timeIntervalSince1970: 1_000_000 - secondsAgo))
    }

    @Test func groupOrderNeedsInputWorkingDirtyDone() {
        let items = [
            item("d", .done, 0), item("c", .dirty, 0),
            item("b", .working, 0), item("a", .needsInput, 0),
        ]
        #expect(InboxOrder.ordered(items).map(\.state)
            == [.needsInput, .working, .dirty, .done])
    }

    @Test func needsInputOldestBlockedFirst() {
        let items = [
            item("recent", .needsInput, 10),   // blocked 10s ago
            item("oldest", .needsInput, 300),   // blocked 300s ago — most urgent
            item("mid", .needsInput, 100),
        ]
        #expect(InboxOrder.ordered(items).map(\.name) == ["oldest", "mid", "recent"])
    }

    @Test func nonNeedsInputMostRecentFirst() {
        let items = [
            item("stale", .working, 300),
            item("fresh", .working, 5),
        ]
        #expect(InboxOrder.ordered(items).map(\.name) == ["fresh", "stale"])
    }

    @Test func tiesBreakByNameThenStable() {
        // Same state + same since → name order, deterministic.
        let items = [item("charlie", .done, 0), item("alpha", .done, 0), item("bravo", .done, 0)]
        #expect(InboxOrder.ordered(items).map(\.name) == ["alpha", "bravo", "charlie"])
    }

    @Test func orderingIsTotalAndStableAcrossRuns() {
        let items = [
            item("z", .needsInput, 50), item("a", .working, 10),
            item("m", .dirty, 200), item("b", .done, 1), item("y", .needsInput, 50),
        ]
        let first = InboxOrder.ordered(items).map(\.name)
        for _ in 0..<20 { #expect(InboxOrder.ordered(items).map(\.name) == first) }
        // needs-input group first, and the tie (z,y at 50s) breaks by name.
        #expect(first.prefix(2) == ["y", "z"])
    }
}

@Suite("PrerequisiteChecks")
struct PrerequisiteChecksTests {

    @Test(arguments: [
        ("git version 2.50.1 (Apple Git-155)", 2, 50),
        ("git version 2.35.0", 2, 35),
        ("git version 2.9.5", 2, 9),
        ("git version 3.0", 3, 0),
    ])
    func parsesLeadingVersion(output: String, major: Int, minor: Int) {
        let v = PrerequisiteChecks.parseGitVersion(output)
        #expect(v?.major == major)
        #expect(v?.minor == minor)
    }

    @Test func rejectsUnparseable() {
        #expect(PrerequisiteChecks.parseGitVersion("git version") == nil)
        #expect(PrerequisiteChecks.parseGitVersion("no numbers here") == nil)
    }

    @Test func minimumComparison() {
        #expect(PrerequisiteChecks.gitMeetsMinimum(.init(major: 2, minor: 50)))
        #expect(PrerequisiteChecks.gitMeetsMinimum(.init(major: 2, minor: 35)))
        #expect(!PrerequisiteChecks.gitMeetsMinimum(.init(major: 2, minor: 34)))
        #expect(!PrerequisiteChecks.gitMeetsMinimum(.init(major: 1, minor: 99)))
        #expect(PrerequisiteChecks.gitMeetsMinimum(.init(major: 3, minor: 0)))
    }

    @Test func socketPathLimit() {
        #expect(PrerequisiteChecks.socketPathFits("/tmp/x.sock"))
        #expect(!PrerequisiteChecks.socketPathFits(String(repeating: "a", count: 104)))
        #expect(PrerequisiteChecks.socketPathFits(String(repeating: "a", count: 103)))
    }
}
