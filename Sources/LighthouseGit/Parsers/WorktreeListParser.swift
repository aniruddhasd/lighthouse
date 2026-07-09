import Foundation

/// Pure parser for `git worktree list --porcelain -z` output.
/// Format verified against git-worktree(1) from git 2.50.1: one attribute per
/// line ("label" or "label value"); boolean attributes are label-only; a
/// record always starts with `worktree <path>` and ends with an empty line
/// (with -z: NUL-terminated lines, so an empty token ends a record and paths
/// are unquoted).
public enum WorktreeListParser {

    public static func parse(_ data: Data) throws -> [Worktree] {
        let tokens = data.split(separator: UInt8(0), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }

        var worktrees: [Worktree] = []
        var current: PartialRecord?

        for token in tokens {
            if token.isEmpty {
                if let record = current {
                    worktrees.append(record.build())
                    current = nil
                }
                continue
            }

            let (label, value) = splitAttribute(token)

            if label == "worktree" {
                if let record = current {
                    // Defensive: a new record without the blank separator.
                    worktrees.append(record.build())
                }
                guard let value else {
                    throw GitClientError.unexpectedOutput(
                        description: "worktree attribute without a path", output: token)
                }
                current = PartialRecord(path: value)
                continue
            }

            guard var record = current else {
                throw GitClientError.unexpectedOutput(
                    description: "attribute '\(label)' before any worktree record", output: token)
            }
            switch label {
            case "HEAD": record.headObject = value
            case "branch": record.branch = value
            case "bare": record.isBare = true
            case "detached": record.isDetached = true
            case "locked":
                record.isLocked = true
                record.lockReason = value
            case "prunable":
                record.isPrunable = true
                record.prunableReason = value
            default:
                break // unknown attribute: tolerate, the format is extensible
            }
            current = record
        }

        if let record = current {
            worktrees.append(record.build())
        }
        return worktrees
    }

    private static func splitAttribute(_ token: String) -> (label: String, value: String?) {
        guard let space = token.firstIndex(of: " ") else { return (token, nil) }
        return (String(token[..<space]), String(token[token.index(after: space)...]))
    }

    private struct PartialRecord {
        var path: String
        var headObject: String?
        var branch: String?
        var isBare = false
        var isDetached = false
        var isLocked = false
        var lockReason: String?
        var isPrunable = false
        var prunableReason: String?

        func build() -> Worktree {
            Worktree(
                path: path, headObject: headObject, branch: branch,
                isBare: isBare, isDetached: isDetached,
                isLocked: isLocked, lockReason: lockReason,
                isPrunable: isPrunable, prunableReason: prunableReason)
        }
    }
}
