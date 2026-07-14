import Foundation

/// Pure parser for the delimiter-safe `git log` format this client requests.
///
/// The format (verified against git 2.50.1) is five placeholders joined by an
/// ASCII Unit Separator (0x1f), each commit terminated by an ASCII Record
/// Separator (0x1e):
///
///   %H %x1f %h %x1f %an %x1f %aI %x1f %s %x1e
///
/// 0x1f / 0x1e are control bytes that cannot occur in a hash, name, ISO date,
/// or a single-line subject (`%s` is one line), so splitting on the raw bytes
/// is unambiguous — no field can smuggle a delimiter, and a subject with
/// spaces, quotes, or angle brackets needs no escaping. git prints a newline
/// after each record, so records carry a leading/trailing newline that is
/// stripped at the record boundary (never inside a field).
public enum CommitLogParser {

    /// ASCII Unit Separator — between fields within one commit.
    static let unitSeparator: UInt8 = 0x1f
    /// ASCII Record Separator — after each commit.
    static let recordSeparator: UInt8 = 0x1e

    /// The `--format=` argument string. Single source of truth: `GitClient`
    /// builds the git invocation from this, and this parser splits on the
    /// bytes it names, so the writer and reader can never drift apart.
    static let format = "%H%x1f%h%x1f%an%x1f%aI%x1f%s%x1e"

    public static func parse(_ data: Data) throws -> [CommitSummary] {
        var commits: [CommitSummary] = []
        for record in data.split(separator: recordSeparator, omittingEmptySubsequences: true) {
            // Strip the newline git prints after each record separator; do NOT
            // trim field content, so a subject's own leading/trailing spaces
            // survive (only 0x0a/0x0d at the record edges are boundary noise).
            let trimmed = trimNewlines(record)
            if trimmed.isEmpty { continue }

            let fields = trimmed.split(
                separator: unitSeparator, omittingEmptySubsequences: false
            ).map { String(decoding: $0, as: UTF8.self) }

            guard fields.count == 5 else {
                throw GitClientError.unexpectedOutput(
                    description: "commit record has \(fields.count) fields, expected 5",
                    output: String(decoding: trimmed, as: UTF8.self))
            }
            commits.append(CommitSummary(
                hash: fields[0], shortHash: fields[1], authorName: fields[2],
                authorDate: fields[3], subject: fields[4]))
        }
        return commits
    }

    /// Drops leading and trailing CR/LF bytes from a record slice.
    private static func trimNewlines<S: Collection>(_ bytes: S) -> [UInt8]
    where S.Element == UInt8 {
        func isNewline(_ b: UInt8) -> Bool { b == 0x0a || b == 0x0d }
        var slice = Array(bytes)
        while let first = slice.first, isNewline(first) { slice.removeFirst() }
        while let last = slice.last, isNewline(last) { slice.removeLast() }
        return slice
    }
}
