import Foundation
import Testing
import LighthouseTaskEngine
@testable import LighthouseAppCore

// Failure-first: every navigation transition is pure over value inputs —
// table-tested here without a window server (the SwiftUI shell is proven by the
// HARBOR runtime gate). The status-filter chips were removed with the attention
// system (2026-07-29), so NavigationState is now just the view.

@Suite("NavigationState transitions")
struct NavigationStateTests {

    @Test func defaultsToHarbor() {
        #expect(NavigationState().view == .harbor)
    }

    @Test func openFlipsToFocus() {
        var nav = NavigationState()
        nav.open()
        #expect(nav.view == .focus)
    }

    @Test func backToHarborFlipsToHarbor() {
        var nav = NavigationState(view: .focus)
        nav.backToHarbor()
        #expect(nav.view == .harbor)
    }

    @Test func transitionsAreIdempotent() {
        var nav = NavigationState(view: .focus)
        nav.open()
        nav.open()
        #expect(nav.view == .focus)
        var harbor = NavigationState(view: .harbor)
        harbor.backToHarbor()
        harbor.backToHarbor()
        #expect(harbor.view == .harbor)
    }

    @Test func initHonorsExplicitStartView() {
        #expect(NavigationState(view: .focus).view == .focus)
        #expect(NavigationState(view: .harbor).view == .harbor)
    }
}
