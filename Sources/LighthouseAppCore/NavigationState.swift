import Foundation
import LighthouseTaskEngine

/// The two top-level views of the Phase-2 shell (spec §3.4). Harbor is the
/// fleet overview ("who needs me"); Focus is a single task with the terminal
/// as the hero.
public enum NavView: String, Sendable, Equatable, CaseIterable {
    case harbor
    case focus
}

/// Pure, unit-testable navigation state for the two-mode shell (spec §3.4,
/// Phase-2 subset). Deliberately lean: `view` only. The status-filter chips
/// were removed with the attention system (2026-07-29) — tasks are no longer
/// bucketed into automatic statuses, so the Harbor shows one ordered list and
/// ⌘K search covers finding a specific one.
///
/// Selection (`selectedTaskId`) and ⌘K visibility (`switcherPresented`) are
/// runtime state; the Focus internals stay on `WorkbenchModel`.
public struct NavigationState: Equatable, Sendable {
    public private(set) var view: NavView

    public init(view: NavView = .harbor) {
        self.view = view
    }

    /// Open a task → Focus (spec §3.4 `open(id)`). The runtime wrapper applies
    /// the selection and closes ⌘K; this pure reducer only flips the view.
    public mutating func open() { view = .focus }

    /// Back to the Harbor overview (spec §3.4 `backToHarbor`).
    public mutating func backToHarbor() { view = .harbor }
}
