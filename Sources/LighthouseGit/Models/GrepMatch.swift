import Foundation

/// One `git grep` hit: a repo-relative path, the 1-based line number, and the
/// full text of the matching line. Powers the ⌘F content search.
public struct GrepMatch: Sendable, Equatable, Identifiable {
    public let path: String
    public let line: Int
    public let text: String

    public init(path: String, line: Int, text: String) {
        self.path = path
        self.line = line
        self.text = text
    }

    /// Stable within one result set (git grep never repeats a path+line).
    public var id: String { "\(path):\(line)" }
}
