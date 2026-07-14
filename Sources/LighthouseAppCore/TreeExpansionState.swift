import Foundation

/// Session-only expansion state for the changed-files tree, keyed by
/// directory id (path). A changed-files tree is small, so directories default
/// to EXPANDED — folding is the exception (2026-07-14: a collapsed dir with no
/// count read as data loss, twice). Only the user's explicit collapses are
/// recorded, so a diff rebuild with the same paths preserves them and a
/// disappeared path drops gracefully. Never persisted.
public struct TreeExpansionState: Sendable, Equatable {
    /// Directory ids the user has explicitly collapsed. Absent ⇒ expanded.
    private var collapsed: Set<String> = []

    public init() {}

    /// Expanded by default; only explicitly-collapsed dirs are folded.
    public func isExpanded(_ directoryID: String) -> Bool {
        !collapsed.contains(directoryID)
    }

    public mutating func setExpanded(_ expanded: Bool, for directoryID: String) {
        if expanded { collapsed.remove(directoryID) } else { collapsed.insert(directoryID) }
    }

    public mutating func toggle(_ directoryID: String) {
        setExpanded(!isExpanded(directoryID), for: directoryID)
    }

    /// Drops collapse entries for directories no longer in the tree (they
    /// disappeared from the diff) so state never leaks across unrelated
    /// paths; keeps entries for surviving dirs (the user's folds persist
    /// across refreshes). Call after each tree rebuild.
    public mutating func prune(toDirectoryIDs valid: some Sequence<String>) {
        collapsed.formIntersection(Set(valid))
    }

    /// Test/inspection accessor.
    public var collapsedIDs: Set<String> { collapsed }
}
