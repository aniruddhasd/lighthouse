import Foundation
import Testing
@testable import LighthouseGit

/// Pure parser tests for the delimiter-safe `git log` format. Failure/edge
/// cases first: malformed records must throw, not silently drop or mis-map;
/// delimiters inside a subject (spaces, quotes, angle brackets) must survive.
@Suite("CommitLogParser")
struct CommitLogParserTests {

    private let us = "\u{1f}" // Unit Separator (0x1f)
    private let rs = "\u{1e}" // Record Separator (0x1e)

    private func record(_ full: String, _ short: String, _ author: String,
                        _ date: String, _ subject: String) -> String {
        [full, short, author, date, subject].joined(separator: us) + rs
    }

    // MARK: - Failure / edge cases

    @Test func emptyInputYieldsNoCommits() throws {
        #expect(try CommitLogParser.parse(Data()) == [])
    }

    @Test func recordWithWrongFieldCountThrows() {
        // Only four fields (missing subject delimiter) → must throw, never a
        // 4-field commit silently accepted.
        let bad = ["abc", "abc", "Name", "2026-01-01T00:00:00Z"].joined(separator: us) + rs
        #expect(throws: GitClientError.self) {
            _ = try CommitLogParser.parse(Data(bad.utf8))
        }
    }

    @Test func subjectWithDelimiterLookalikeCharsSurvives() throws {
        // Spaces, quotes, and angle brackets are ordinary bytes here — only
        // 0x1f/0x1e delimit — so the subject must round-trip verbatim.
        let subject = #"fix: handle "weird" <input> & spaces"#
        let data = Data(record(
            String(repeating: "a", count: 40), "aaaaaaa", "Jane Doe",
            "2026-07-14T18:12:48+05:30", subject).utf8)
        let commits = try CommitLogParser.parse(data)
        #expect(commits.count == 1)
        #expect(commits[0].subject == subject)
        #expect(commits[0].authorName == "Jane Doe")
        #expect(commits[0].authorDate == "2026-07-14T18:12:48+05:30")
    }

    @Test func emptySubjectIsAllowedAsFiveEmptyFields() throws {
        // A commit can have an empty subject; the trailing US must yield a 5th
        // empty field, not a 4-field parse error.
        let data = Data((["h", "h", "A", "2026-01-01T00:00:00Z", ""].joined(separator: us) + rs).utf8)
        let commits = try CommitLogParser.parse(data)
        #expect(commits.count == 1)
        #expect(commits[0].subject == "")
    }

    // MARK: - Happy path

    @Test func multipleRecordsWithInterveningNewlinesParseInOrder() throws {
        // git prints a newline after each record separator; the parser strips
        // that boundary newline without corrupting fields.
        let stream = record("f1", "s1", "One", "2026-01-01T00:00:00Z", "first")
            + "\n" + record("f2", "s2", "Two", "2026-01-02T00:00:00Z", "second")
            + "\n"
        let commits = try CommitLogParser.parse(Data(stream.utf8))
        #expect(commits.map(\.subject) == ["first", "second"])
        #expect(commits.map(\.hash) == ["f1", "f2"])
        #expect(commits.map(\.authorName) == ["One", "Two"])
    }
}
