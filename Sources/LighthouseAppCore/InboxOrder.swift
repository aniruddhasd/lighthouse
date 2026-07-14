import Foundation
import LighthouseTaskEngine

/// One task as the inbox sees it.
public struct InboxItem: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let state: TaskAttentionState
    /// When the task entered its current attention state (last transition).
    public let since: Date

    public init(id: UUID, name: String, state: TaskAttentionState, since: Date) {
        self.id = id
        self.name = name
        self.state = state
        self.since = since
    }
}

/// The ONE authoritative "what needs me" order (spec §6 step 7). A single
/// pure, total function so it is table-testable and identical everywhere the
/// inbox is shown.
///
/// Group order: needs-input first, then working, then dirty (incl. a dead
/// session), then done. Within needs-input, the LONGEST-waiting agent is most
/// urgent → oldest `since` first. Within every other group, most-recent
/// transition first. Ties break by name, then by id — so the order is a
/// deterministic total order with no unstable ambiguity.
public enum InboxOrder {

    static func groupRank(_ state: TaskAttentionState) -> Int {
        switch state {
        case .needsInput: return 0
        case .working: return 1
        case .dirty: return 2
        case .done: return 3
        }
    }

    public static func ordered(_ items: [InboxItem]) -> [InboxItem] {
        items.sorted(by: less)
    }

    static func less(_ a: InboxItem, _ b: InboxItem) -> Bool {
        let ra = groupRank(a.state), rb = groupRank(b.state)
        if ra != rb { return ra < rb }
        if a.since != b.since {
            // needs-input: oldest first; every other group: most recent first.
            return a.state == .needsInput ? a.since < b.since : a.since > b.since
        }
        let byName = a.name.localizedCompare(b.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return a.id.uuidString < b.id.uuidString
    }
}
