import Foundation
import Testing
import LighthouseTaskEngine
@testable import LighthouseAppCore

// Failure-first: every transition, the filter predicate mapping, and the
// Harbor sort are pure over value inputs — table-tested here without a window
// server (the SwiftUI shell is proven by the HARBOR runtime gate).

@Suite("NavigationState transitions")
struct NavigationStateTests {

    @Test func defaultsToHarborAll() {
        let nav = NavigationState()
        #expect(nav.view == .harbor)
        #expect(nav.filter == .all)
    }

    @Test func openFlipsToFocus() {
        var nav = NavigationState()
        nav.open()
        #expect(nav.view == .focus)
    }

    @Test func backToHarborFlipsToHarborAndKeepsFilter() {
        var nav = NavigationState(view: .focus, filter: .needs)
        nav.backToHarbor()
        #expect(nav.view == .harbor)
        // backToHarbor keeps the filter chip (spec §3.4).
        #expect(nav.filter == .needs)
    }

    @Test func setFilterChangesOnlyFilter() {
        var nav = NavigationState(view: .focus)
        nav.setFilter(.stale)
        #expect(nav.filter == .stale)
        // setFilter does not touch the view.
        #expect(nav.view == .focus)
    }

    @Test func transitionsAreIdempotent() {
        var nav = NavigationState(view: .focus, filter: .working)
        nav.open()
        nav.open()
        #expect(nav.view == .focus)
        var harbor = NavigationState(view: .harbor)
        harbor.backToHarbor()
        harbor.backToHarbor()
        #expect(harbor.view == .harbor)
        nav.setFilter(.idle)
        nav.setFilter(.idle)
        #expect(nav.filter == .idle)
    }

    @Test func initHonorsExplicitStartView() {
        #expect(NavigationState(view: .focus).view == .focus)
        #expect(NavigationState(view: .harbor).view == .harbor)
    }
}

@Suite("HarborFilter predicate mapping")
struct HarborFilterTests {

    @Test func eachFilterMapsToItsAttentionState() {
        #expect(HarborFilter.all.attentionState == nil)
        #expect(HarborFilter.needs.attentionState == .needsInput)
        #expect(HarborFilter.working.attentionState == .working)
        #expect(HarborFilter.idle.attentionState == .done)
        #expect(HarborFilter.stale.attentionState == .dirty)
    }

    @Test func allMatchesEveryState() {
        for state in TaskAttentionState.allCases {
            #expect(HarborFilter.all.matches(state))
        }
    }

    @Test func specificFilterMatchesOnlyItsState() {
        // needs matches ONLY needsInput; it must reject the other three.
        #expect(HarborFilter.needs.matches(.needsInput))
        #expect(!HarborFilter.needs.matches(.working))
        #expect(!HarborFilter.needs.matches(.done))
        #expect(!HarborFilter.needs.matches(.dirty))
        // idle maps to done, stale maps to dirty (the redesign's naming).
        #expect(HarborFilter.idle.matches(.done))
        #expect(!HarborFilter.idle.matches(.dirty))
        #expect(HarborFilter.stale.matches(.dirty))
        #expect(!HarborFilter.stale.matches(.done))
        #expect(HarborFilter.working.matches(.working))
        #expect(!HarborFilter.working.matches(.needsInput))
    }
}

@Suite("HarborOrder (table)")
struct HarborOrderTests {
    private func item(_ name: String, _ state: TaskAttentionState, _ secondsAgo: TimeInterval = 0) -> InboxItem {
        InboxItem(id: UUID(), name: name, state: state,
                  since: Date(timeIntervalSince1970: 1_000_000 - secondsAgo))
    }

    @Test func groupOrderNeedsWorkingIdleStale() {
        // Deliberately shuffled input; the ONLY correct output is
        // needs → working → done(idle) → dirty(stale). If HarborOrder fell back
        // to InboxOrder's ranking, done and dirty would swap and this fails.
        let items = [
            item("c", .dirty), item("b", .done),
            item("a", .working), item("z", .needsInput),
        ]
        #expect(HarborOrder.ordered(items).map(\.state)
            == [.needsInput, .working, .done, .dirty])
    }

    @Test func differsFromInboxOrderOnDoneVsDirty() {
        let items = [item("x", .done), item("y", .dirty)]
        // Harbor: done (idle) before dirty (stale).
        #expect(HarborOrder.ordered(items).map(\.state) == [.done, .dirty])
        // Inbox: the opposite — dirty before done. Proves they diverge.
        #expect(InboxOrder.ordered(items).map(\.state) == [.dirty, .done])
    }

    @Test func needsInputOldestWaitingFirst() {
        let items = [
            item("recent", .needsInput, 10),
            item("oldest", .needsInput, 300),   // waiting longest → most urgent
            item("mid", .needsInput, 100),
        ]
        #expect(HarborOrder.ordered(items).map(\.name) == ["oldest", "mid", "recent"])
    }

    @Test func nonNeedsGroupsOrderByNameNotSince() {
        // Unlike the inbox, the working group ignores `since` and sorts by name.
        let items = [
            item("charlie", .working, 5),
            item("alpha", .working, 300),
            item("bravo", .working, 100),
        ]
        #expect(HarborOrder.ordered(items).map(\.name) == ["alpha", "bravo", "charlie"])
    }

    @Test func tiesBreakByNameThenIdStable() {
        let a = InboxItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                          name: "same", state: .done, since: Date(timeIntervalSince1970: 0))
        let b = InboxItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                          name: "same", state: .done, since: Date(timeIntervalSince1970: 0))
        // Same name + state + since → id order, deterministic.
        #expect(HarborOrder.ordered([b, a]).map(\.id) == [a.id, b.id])
    }

    @Test func orderingIsTotalAndStableAcrossRuns() {
        let items = [
            item("z", .needsInput, 50), item("a", .working, 10),
            item("m", .dirty, 200), item("b", .done, 1), item("y", .needsInput, 50),
        ]
        let first = HarborOrder.ordered(items).map(\.name)
        for _ in 0..<20 { #expect(HarborOrder.ordered(items).map(\.name) == first) }
        // needs group first; the 50s tie (z,y) breaks by name → y before z.
        #expect(Array(first.prefix(2)) == ["y", "z"])
        // Full order: needs(y,z) → working(a) → done/idle(b) → dirty/stale(m).
        #expect(first == ["y", "z", "a", "b", "m"])
    }
}
