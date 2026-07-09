import Foundation

/// Pure parser for `git status --porcelain=v2 --branch -z` output.
/// Field layout verified against git-status(1) from git 2.50.1:
///   1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
///   2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path><NUL><origPath>
///   u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
///   ? <path>      ! <path>
/// With -z, records are NUL-terminated and paths are unquoted, so paths with
/// spaces need no special handling. Unknown `#` headers are ignored, as the
/// docs require of parsers.
public enum StatusV2Parser {

    public static func parse(_ data: Data) throws -> RepoStatus {
        var headBranch: String?
        var detached = false
        var headObject: String?
        var initial = false
        var upstream: String?
        var aheadBehind: AheadBehind?
        var changed: [ChangedEntry] = []
        var renamed: [RenamedEntry] = []
        var unmerged: [UnmergedEntry] = []
        var untracked: [String] = []
        var ignored: [String] = []

        let tokens = data.split(separator: UInt8(0), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }

        var index = 0
        while index < tokens.count {
            let line = tokens[index]
            defer { index += 1 }
            if line.isEmpty { continue }

            switch true {
            case line.hasPrefix("# branch.oid "):
                let value = String(line.dropFirst("# branch.oid ".count))
                if value == "(initial)" { initial = true } else { headObject = value }

            case line.hasPrefix("# branch.head "):
                let value = String(line.dropFirst("# branch.head ".count))
                if value == "(detached)" { detached = true } else { headBranch = value }

            case line.hasPrefix("# branch.upstream "):
                upstream = String(line.dropFirst("# branch.upstream ".count))

            case line.hasPrefix("# branch.ab "):
                aheadBehind = try parseAheadBehind(String(line.dropFirst("# branch.ab ".count)), line: line)

            case line.hasPrefix("#"):
                continue // unknown header: ignore per the format contract

            case line.hasPrefix("1 "):
                changed.append(try parseChanged(line))

            case line.hasPrefix("2 "):
                // With -z the original path is the NEXT NUL-separated token.
                guard index + 1 < tokens.count else {
                    throw GitClientError.unexpectedOutput(
                        description: "rename entry missing original path", output: line)
                }
                index += 1
                renamed.append(try parseRenamed(line, originalPath: tokens[index]))

            case line.hasPrefix("u "):
                unmerged.append(try parseUnmerged(line))

            case line.hasPrefix("? "):
                untracked.append(String(line.dropFirst(2)))

            case line.hasPrefix("! "):
                ignored.append(String(line.dropFirst(2)))

            default:
                throw GitClientError.unexpectedOutput(
                    description: "unrecognized status line", output: line)
            }
        }

        let head: RepoStatus.Head
        if detached {
            head = .detached
        } else if let headBranch {
            head = initial ? .unborn(headBranch) : .branch(headBranch)
        } else {
            throw GitClientError.unexpectedOutput(
                description: "status output has no branch.head header (was --branch passed?)",
                output: tokens.prefix(5).joined(separator: "\n"))
        }

        return RepoStatus(
            head: head, headObject: headObject, upstream: upstream, aheadBehind: aheadBehind,
            changed: changed, renamed: renamed, unmerged: unmerged,
            untracked: untracked, ignored: ignored)
    }

    // MARK: - Line parsers

    private static func parseAheadBehind(_ value: String, line: String) throws -> AheadBehind {
        // Format: "+<ahead> -<behind>"
        let parts = value.split(separator: " ")
        guard parts.count == 2, parts[0].hasPrefix("+"), parts[1].hasPrefix("-"),
              let ahead = Int(parts[0].dropFirst()), let behind = Int(parts[1].dropFirst())
        else {
            throw GitClientError.unexpectedOutput(description: "malformed branch.ab header", output: line)
        }
        return AheadBehind(ahead: ahead, behind: behind)
    }

    private static func fileState(_ char: Character, line: String) throws -> FileState {
        guard let state = FileState(rawValue: char) else {
            throw GitClientError.unexpectedOutput(
                description: "unknown file state '\(char)'", output: line)
        }
        return state
    }

    /// Splits a line into exactly `fieldCount` space-separated fields plus a
    /// trailing remainder (the path, which may itself contain spaces).
    private static func fields(of line: String, count fieldCount: Int) throws -> [String] {
        let parts = line.split(separator: " ", maxSplits: fieldCount, omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == fieldCount + 1, !parts.contains(where: \.isEmpty) else {
            throw GitClientError.unexpectedOutput(
                description: "expected \(fieldCount) fields plus path", output: line)
        }
        return parts
    }

    private static func xy(_ field: String, line: String) throws -> (Character, Character) {
        guard field.count == 2 else {
            throw GitClientError.unexpectedOutput(description: "malformed XY field", output: line)
        }
        return (field[field.startIndex], field[field.index(after: field.startIndex)])
    }

    private static func parseChanged(_ line: String) throws -> ChangedEntry {
        // 1 XY sub mH mI mW hH hI path  → 8 fields + path
        let f = try fields(of: line, count: 8)
        let (x, y) = try xy(f[1], line: line)
        return ChangedEntry(
            indexState: try fileState(x, line: line),
            worktreeState: try fileState(y, line: line),
            path: f[8])
    }

    private static func parseRenamed(_ line: String, originalPath: String) throws -> RenamedEntry {
        // 2 XY sub mH mI mW hH hI Xscore path  → 9 fields + path
        let f = try fields(of: line, count: 9)
        let (x, y) = try xy(f[1], line: line)
        return RenamedEntry(
            indexState: try fileState(x, line: line),
            worktreeState: try fileState(y, line: line),
            score: f[8],
            path: f[9],
            originalPath: originalPath)
    }

    private static func parseUnmerged(_ line: String) throws -> UnmergedEntry {
        // u XY sub m1 m2 m3 mW h1 h2 h3 path  → 10 fields + path
        let f = try fields(of: line, count: 10)
        guard let kind = ConflictKind(rawValue: f[1]) else {
            throw GitClientError.unexpectedOutput(
                description: "unknown conflict XY '\(f[1])'", output: line)
        }
        return UnmergedEntry(
            kind: kind, path: f[10],
            stage1Mode: f[3], stage2Mode: f[4], stage3Mode: f[5], worktreeMode: f[6],
            stage1Object: f[7], stage2Object: f[8], stage3Object: f[9])
    }
}
