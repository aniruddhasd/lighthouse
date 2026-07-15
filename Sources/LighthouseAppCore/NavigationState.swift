import Foundation
import LighthouseTaskEngine

/// The two top-level views of the Phase-2 shell (spec §3.4). Harbor is the
/// fleet overview ("who needs me"); Focus is a single task with the terminal
/// as the hero.
public enum NavView: String, Sendable, Equatable, CaseIterable {
    case harbor
    case focus
}

/// The Harbor grid's status filter (handoff §1 chips). `.all` selects every
/// task; each other case maps to exactly one attention state.
///
/// Mapping (spec §3.4 / handoff §"State Management"): needs→needsInput,
/// working→working, idle→done, stale→dirty. This is the redesign's four
/// statuses = today's four attention states, no new state machine.
public enum HarborFilter: String, Sendable, Equatable, CaseIterable, Identifiable {
    case all
    case needs
    case working
    case idle
    case stale

    public var id: String { rawValue }

    /// The attention state this filter selects, or nil for `.all`.
    public var attentionState: TaskAttentionState? {
        switch self {
        case .all: return nil
        case .needs: return .needsInput
        case .working: return .working
        case .idle: return .done
        case .stale: return .dirty
        }
    }

    /// Whether a task in `state` passes this filter. `.all` passes everything;
    /// every other case is an exact match on the mapped attention state.
    public func matches(_ state: TaskAttentionState) -> Bool {
        guard let target = attentionState else { return true }
        return state == target
    }
}

/// Pure, unit-testable navigation state for the two-mode shell (spec §3.4,
/// Phase-2 subset). Deliberately lean: `view` + `filter` only.
///
/// Everything else the handoff's `support.js` tracks lives elsewhere and is
/// out of scope for this value: selection (`selectedTaskId`) and ⌘K visibility
/// (`switcherPresented`) are runtime state; the Focus internals
/// (`termMode`/`viewerId`/`navOpen`) stay on `WorkbenchModel` and are Phase-3
/// work. Keeping this model small and stable is the point — no SwiftUI/AppKit
/// import, so every transition is testable headlessly (the established scar:
/// SwiftUI geometry is proven by the runtime gate, pure logic by unit tests).
public struct NavigationState: Equatable, Sendable {
    public private(set) var view: NavView
    public private(set) var filter: HarborFilter

    public init(view: NavView = .harbor, filter: HarborFilter = .all) {
        self.view = view
        self.filter = filter
    }

    /// Open a task → Focus (spec §3.4 `open(id)`). The runtime wrapper applies
    /// the selection and closes ⌘K; this pure reducer only flips the view.
    public mutating func open() { view = .focus }

    /// Back to the Harbor overview (spec §3.4 `backToHarbor`). Keeps `filter`
    /// so returning to Harbor lands on the same chip the user left on.
    public mutating func backToHarbor() { view = .harbor }

    /// Set the Harbor grid filter chip (spec §3.4 `setFilter`).
    public mutating func setFilter(_ newFilter: HarborFilter) { filter = newFilter }
}
