import Foundation

/// Subsequence matcher for the Cmd+K switcher. Case- and
/// diacritic-insensitive; deterministic; no regular expressions, no locale
/// surprises (folding uses the POSIX-independent option set).
public enum FuzzyMatcher {

    /// Returns nil when `query` is not a subsequence of `candidate`;
    /// otherwise a score (higher = better). The empty query matches
    /// everything with score 0.
    ///
    /// Scoring: +6 for each consecutive match, +5 when a match lands on a
    /// word boundary (start, or after space/-/_/.//), -1 for every skipped
    /// candidate character between matches. Consecutive outranks boundary so
    /// a real substring always beats letters scattered across separators.
    /// Greedy left-to-right, which keeps ranking stable and predictable.
    public static func score(query: String, candidate: String) -> Int? {
        let q = Array(fold(query))
        if q.isEmpty { return 0 }
        let c = Array(fold(candidate))
        if q.count > c.count { return nil }

        var score = 0
        var qi = 0
        var previousMatched = false
        var gap = 0

        for (index, char) in c.enumerated() {
            guard qi < q.count else { break }
            if char == q[qi] {
                score -= gap
                gap = 0
                if previousMatched {
                    score += 6
                } else if index == 0 || isBoundary(c[index - 1]) {
                    score += 5
                } else {
                    score += 1
                }
                previousMatched = true
                qi += 1
            } else {
                if qi > 0 { gap += 1 } // skips before the first match are free
                previousMatched = false
            }
        }
        return qi == q.count ? score : nil
    }

    private static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func isBoundary(_ char: Character) -> Bool {
        char == " " || char == "-" || char == "_" || char == "/" || char == "."
    }
}
