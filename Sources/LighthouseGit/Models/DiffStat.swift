import Foundation

/// Aggregate line/file counts from `git diff --numstat` — the deterministic
/// source for the Harbor card / Focus footer / Summary "Changes" fields. Every
/// number here is git's own, never estimated. A genuinely empty diff is
/// `DiffStat.zero` (a KNOWN zero — distinct from "unknown", which the digest
/// represents as an absent DiffStat and renders as blanks).
public struct DiffStat: Sendable, Equatable {
    /// Number of changed files (one per numstat record, including binary and
    /// renamed files — each is exactly one line of numstat output).
    public let filesChanged: Int
    /// Total added lines summed across text files (binary files contribute 0
    /// lines but still count toward `filesChanged`).
    public let added: Int
    /// Total deleted lines summed across text files.
    public let deleted: Int

    public init(filesChanged: Int, added: Int, deleted: Int) {
        self.filesChanged = filesChanged
        self.added = added
        self.deleted = deleted
    }

    public static let zero = DiffStat(filesChanged: 0, added: 0, deleted: 0)

    /// Combine two stats (used to total a multi-repo task across its worktrees).
    public func adding(_ other: DiffStat) -> DiffStat {
        DiffStat(
            filesChanged: filesChanged + other.filesChanged,
            added: added + other.added,
            deleted: deleted + other.deleted)
    }

    /// Parses `git diff --numstat` stdout. Pure and separately testable.
    ///
    /// Format is one record per line — `<added>\t<deleted>\t<path>` — so the
    /// line count IS the file count (git escapes/quotes unusual paths, and
    /// never emits a literal newline inside a numstat record). A binary file
    /// prints `-\t-\t<path>`: it contributes 0 lines but is still one changed
    /// file. A rename/copy is a single record (`{a => b}` or `a => b` in the
    /// path field), so it counts as one file with its real add/del numbers. A
    /// zero-change record (`0\t0\t<path>`, e.g. a mode-only change) counts the
    /// file with zero lines. Malformed lines are skipped, never crash.
    public static func parse(numstat: String) -> DiffStat {
        var files = 0
        var added = 0
        var deleted = 0
        for rawLine in numstat.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = rawLine.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            // A valid record has at least the two count fields plus a path.
            guard fields.count >= 3 else { continue }
            files += 1
            // "-" marks binary (no line counts); anything unparseable is 0.
            if fields[0] != "-" { added += Int(fields[0]) ?? 0 }
            if fields[1] != "-" { deleted += Int(fields[1]) ?? 0 }
        }
        return DiffStat(filesChanged: files, added: added, deleted: deleted)
    }
}
