import Foundation

/// One physical line plus its exact terminator ("\n", "\r\n", or "" for a
/// final line with no trailing newline). Preserving terminators verbatim is
/// what makes transform output byte-exact across LF/CRLF/no-final-newline.
struct RawLine: Equatable {
    let content: String
    let terminator: String

    var full: String { content + terminator }
}

/// A segment of a conflicted file: either untouched text, or one conflict
/// block with its three zdiff3 sides (base is nil when the merge was not
/// recorded with diff3/zdiff3 style).
enum ConflictSegment: Equatable {
    case text([RawLine])
    case conflict(ConflictBlock)
}

struct ConflictBlock: Equatable {
    /// The `<<<<<<<` … region ("current"/ours).
    let current: [RawLine]
    /// The `|||||||` … region (merge base); nil when absent.
    let base: [RawLine]?
    /// The `=======` … `>>>>>>>` region ("incoming"/theirs).
    let incoming: [RawLine]
    /// The four marker lines, kept verbatim so re-materialization and
    /// round-tripping preserve their exact labels and terminators.
    let openMarker: RawLine
    let baseMarker: RawLine?
    let separatorMarker: RawLine
    let closeMarker: RawLine
}

enum ConflictParseError: Error, Equatable {
    case unterminatedBlock(openedAtLine: Int)
    case unexpectedMarker(line: Int, text: String)
}

/// Splits a conflicted file's text into segments. Pure and total over
/// well-formed conflict markup; malformed markup throws (never silently
/// mis-parses). Handles nested-adjacent blocks, markers at file start/end,
/// missing final newline, and CRLF.
enum ConflictParser {
    static let markerWidth = 7

    static func parse(_ text: String) throws -> [ConflictSegment] {
        let lines = splitPreservingTerminators(text)
        var segments: [ConflictSegment] = []
        var pendingText: [RawLine] = []
        var index = 0

        func flushText() {
            if !pendingText.isEmpty {
                segments.append(.text(pendingText))
                pendingText = []
            }
        }

        while index < lines.count {
            let line = lines[index]
            switch markerKind(line.content) {
            case .open:
                flushText()
                let (block, next) = try parseBlock(lines, from: index)
                segments.append(.conflict(block))
                index = next
            case .base, .separator, .close:
                throw ConflictParseError.unexpectedMarker(line: index, text: line.content)
            case .none:
                pendingText.append(line)
                index += 1
            }
        }
        flushText()
        return segments
    }

    /// Reassembles segments into file text (identity for an unmodified parse).
    static func render(_ segments: [ConflictSegment]) -> String {
        var out = ""
        for segment in segments {
            switch segment {
            case .text(let lines):
                out += lines.map(\.full).joined()
            case .conflict(let block):
                out += block.openMarker.full
                out += block.current.map(\.full).joined()
                if let baseMarker = block.baseMarker, let base = block.base {
                    out += baseMarker.full
                    out += base.map(\.full).joined()
                }
                out += block.separatorMarker.full
                out += block.incoming.map(\.full).joined()
                out += block.closeMarker.full
            }
        }
        return out
    }

    /// True if the text still contains any conflict start marker — the
    /// "are we resolved?" check the resolution flow uses.
    static func hasConflictMarkers(_ text: String) -> Bool {
        splitPreservingTerminators(text).contains { markerKind($0.content) == .open }
    }

    // MARK: - Internals

    private enum MarkerKind { case open, base, separator, close, none }

    private static func markerKind(_ content: String) -> MarkerKind {
        func isRun(_ char: Character) -> Bool {
            guard content.count >= markerWidth else { return false }
            let prefix = content.prefix(markerWidth)
            guard prefix.allSatisfy({ $0 == char }) else { return false }
            // Exactly 7 (e.g. bare "=======") or 7 then a space+label — never
            // 8 of the same char (that is content, not a marker).
            if content.count == markerWidth { return true }
            let after = content[content.index(content.startIndex, offsetBy: markerWidth)]
            return after == " "
        }
        if isRun("<") { return .open }
        if isRun("|") { return .base }
        if isRun("=") { return .separator }
        if isRun(">") { return .close }
        return .none
    }

    private static func parseBlock(
        _ lines: [RawLine], from start: Int
    ) throws -> (ConflictBlock, Int) {
        let openMarker = lines[start]
        var index = start + 1
        var current: [RawLine] = []
        var base: [RawLine]?
        var baseMarker: RawLine?
        var separatorMarker: RawLine?

        // current region until ||||||| or =======
        while index < lines.count {
            let kind = markerKind(lines[index].content)
            if kind == .base {
                baseMarker = lines[index]
                index += 1
                var baseLines: [RawLine] = []
                while index < lines.count, markerKind(lines[index].content) != .separator {
                    if markerKind(lines[index].content) != .none {
                        throw ConflictParseError.unexpectedMarker(
                            line: index, text: lines[index].content)
                    }
                    baseLines.append(lines[index])
                    index += 1
                }
                base = baseLines
                break
            }
            if kind == .separator { break }
            if kind != .none {
                throw ConflictParseError.unexpectedMarker(line: index, text: lines[index].content)
            }
            current.append(lines[index])
            index += 1
        }

        guard index < lines.count, markerKind(lines[index].content) == .separator else {
            throw ConflictParseError.unterminatedBlock(openedAtLine: start)
        }
        separatorMarker = lines[index]
        index += 1

        // incoming region until >>>>>>>
        var incoming: [RawLine] = []
        while index < lines.count, markerKind(lines[index].content) != .close {
            if markerKind(lines[index].content) != .none {
                throw ConflictParseError.unexpectedMarker(line: index, text: lines[index].content)
            }
            incoming.append(lines[index])
            index += 1
        }
        guard index < lines.count, markerKind(lines[index].content) == .close else {
            throw ConflictParseError.unterminatedBlock(openedAtLine: start)
        }
        let closeMarker = lines[index]
        index += 1

        let block = ConflictBlock(
            current: current, base: base, incoming: incoming,
            openMarker: openMarker, baseMarker: baseMarker,
            separatorMarker: separatorMarker!, closeMarker: closeMarker)
        return (block, index)
    }

    /// Splits into lines each carrying its own terminator; a trailing line
    /// without a newline gets an empty terminator (so it round-trips exactly).
    /// Iterates UNICODE SCALARS, not Characters: Swift treats "\r\n" as a
    /// single grapheme cluster, so a Character-level scan would never see the
    /// CR — this cost a real bug (2026-07-13).
    static func splitPreservingTerminators(_ text: String) -> [RawLine] {
        var lines: [RawLine] = []
        var content = ""
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\r" {
                if index + 1 < scalars.count, scalars[index + 1] == "\n" {
                    lines.append(RawLine(content: content, terminator: "\r\n"))
                    content = ""
                    index += 2
                } else {
                    // Bare CR is not a terminator git emits; keep as content.
                    content.unicodeScalars.append(scalar)
                    index += 1
                }
            } else if scalar == "\n" {
                lines.append(RawLine(content: content, terminator: "\n"))
                content = ""
                index += 1
            } else {
                content.unicodeScalars.append(scalar)
                index += 1
            }
        }
        if !content.isEmpty {
            lines.append(RawLine(content: content, terminator: ""))
        }
        return lines
    }
}
