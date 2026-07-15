import Foundation
import LighthouseTaskEngine

/// The Harbor grid's task ordering (handoff §1 / spec §5.1): a pure, total
/// function so it is table-testable and identical to what the runtime feeds the
/// grid.
///
/// DISTINCT from `InboxOrder` (the ⌘K urgency inbox) and deliberately so:
/// - Harbor:  needs → working → idle → stale  = needsInput → working → done → dirty
/// - Inbox:   needsInput → working → dirty → done
/// The handoff's overview sorts idle (done) above stale (dirty); the inbox
/// surfaces stale (a dead/dirty session) above done because it is "what needs
/// me". `InboxOrder` is unchanged — ⌘K keeps it.
///
/// Tie-breaks (a deterministic total order, no unstable ambiguity):
/// - Within needs-input, the LONGEST-waiting agent is most urgent → oldest
///   `since` first (mirroring InboxOrder's needs semantics).
/// - Every other group orders by name, then id.
public enum HarborOrder {

    /// Group rank: needs(0) → working(1) → idle/done(2) → stale/dirty(3).
    static func groupRank(_ state: TaskAttentionState) -> Int {
        switch state {
        case .needsInput: return 0
        case .working: return 1
        case .done: return 2      // idle
        case .dirty: return 3     // stale
        }
    }

    public static func ordered(_ items: [InboxItem]) -> [InboxItem] {
        items.sorted(by: less)
    }

    static func less(_ a: InboxItem, _ b: InboxItem) -> Bool {
        let ra = groupRank(a.state), rb = groupRank(b.state)
        if ra != rb { return ra < rb }
        // needs-input: oldest-waiting first. Every other group falls straight
        // through to name/id (no since-based ordering — that is inbox-only).
        if a.state == .needsInput, a.since != b.since { return a.since < b.since }
        let byName = a.name.localizedCompare(b.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return a.id.uuidString < b.id.uuidString
    }
}
