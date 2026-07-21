import Foundation

/// Ranking for the ⌘P file finder — a VS-Code-style quick-open over a repo's
/// file list. Pure and deterministic so the whole ordering is unit-tested; the
/// UI (FileFinderOverlay) only renders what this returns and opens the pick.
///
/// Reuses `FuzzyMatcher` (subsequence, boundary-aware — `/` is a boundary) so
/// ranking matches the Cmd+K switcher's feel, then adds one rule quick-open
/// needs and the switcher doesn't: a match on the FILE NAME always outranks a
/// match that only lands in the directory portion of the path. Typing "model"
/// surfaces `.../AppModel.swift`, never a stray `models/` directory deep in an
/// unrelated path.
public enum FileFinder {

    /// The best `limit` paths for `query`, best first. A path qualifies when
    /// `query` is a subsequence of its file name OR its full path (basename
    /// wins). The empty query returns the first `limit` paths in a stable order
    /// (shortest, then lexicographic) so the palette shows the tree up front.
    public static func rank(query: String, paths: [String], limit: Int = 50) -> [String] {
        let scored: [(path: String, score: Int)] = paths.compactMap { path in
            guard let score = Self.score(query: query, path: path) else { return nil }
            return (path, score)
        }
        // Higher score first; ties broken by the shorter path, then
        // lexicographically — total and deterministic, no dependence on input
        // order.
        let ranked = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
            return lhs.path < rhs.path
        }
        return ranked.prefix(limit).map(\.path)
    }

    /// A path's score, or nil when `query` matches neither its file name nor its
    /// full path. A basename hit is lifted above every path-only hit by a fixed
    /// offset larger than any achievable `FuzzyMatcher` score for these lengths.
    static func score(query: String, path: String) -> Int? {
        let basename = String(path.split(separator: "/").last ?? Substring(path))
        if let base = FuzzyMatcher.score(query: query, candidate: basename) {
            return base + basenameBonus
        }
        return FuzzyMatcher.score(query: query, candidate: path)
    }

    /// Larger than any per-character bonus sum a realistic path length yields,
    /// so ANY basename match sorts above ANY path-only match.
    private static let basenameBonus = 100_000
}
