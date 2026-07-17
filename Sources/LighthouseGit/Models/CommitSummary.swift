import Foundation

/// One row of `git log` for the history navigator: identity plus the fields
/// shown in the list. `authorDate` is the author date in strict ISO-8601
/// (git `%aI`) — carried as the string git emits so no timezone information is
/// lost to a `Date` round-trip; the UI formats it.
public struct CommitSummary: Sendable, Equatable {
    /// Full 40-hex object name — the identity, and what `commitDiff` is called with.
    public let hash: String
    /// Abbreviated hash (git `%h`) for display.
    public let shortHash: String
    /// Author name (git `%an`).
    public let authorName: String
    /// Author date, strict ISO-8601 (git `%aI`), e.g. `2026-07-14T18:12:48+05:30`.
    public let authorDate: String
    /// Commit subject — the first line of the message (git `%s`), single line.
    public let subject: String

    public init(hash: String, shortHash: String, authorName: String, authorDate: String, subject: String) {
        self.hash = hash
        self.shortHash = shortHash
        self.authorName = authorName
        self.authorDate = authorDate
        self.subject = subject
    }
}
