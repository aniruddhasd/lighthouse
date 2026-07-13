import Foundation

/// The choice a user makes for one conflict block. These are the ONLY edits
/// the app performs on conflicted text (guardrail 2: conflict transforms
/// delete one side + marker lines — no free-form editing surface exists).
public enum BlockResolution: Sendable, Equatable {
    /// Keep the current (ours) side; drop base, incoming, and all markers.
    case current
    /// Keep the incoming (theirs) side.
    case incoming
    /// Keep current then incoming (in that order); drop base and markers.
    case both
}

/// A per-block resolution plan for one file: index → choice. Blocks are
/// numbered in file order (0-based).
public struct FileResolution: Sendable, Equatable {
    public var choices: [Int: BlockResolution]

    public init(choices: [Int: BlockResolution] = [:]) {
        self.choices = choices
    }
}

public enum ConflictTransformError: Error, Equatable {
    case parseFailed(String)
    /// A block index in the plan does not exist in the file.
    case unknownBlock(Int)
    /// Not every conflict block has a choice yet — the file is not resolved.
    case unresolvedBlocks([Int])
}

/// Applies block resolutions to conflicted file text, byte-exactly. The
/// engine only ever selects existing lines and deletes markers/the other
/// side; it never synthesises content.
public enum ConflictTransform {

    /// Number of conflict blocks in the text (for UI + validation).
    public static func blockCount(in text: String) throws -> Int {
        let segments = try parse(text)
        return segments.reduce(0) { count, segment in
            if case .conflict = segment { return count + 1 }
            return count
        }
    }

    /// Applies `resolution` to every block. Throws `.unresolvedBlocks` if any
    /// block lacks a choice — resolution must be complete before it is
    /// written (the flow only stages fully-resolved files).
    public static func apply(_ resolution: FileResolution, to text: String) throws -> String {
        let segments = try parse(text)
        var blockIndex = 0
        var missing: [Int] = []
        var unknown: [Int] = []
        for segment in segments {
            if case .conflict = segment {
                if resolution.choices[blockIndex] == nil { missing.append(blockIndex) }
                blockIndex += 1
            }
        }
        for key in resolution.choices.keys where key >= blockIndex || key < 0 {
            unknown.append(key)
        }
        if let first = unknown.first { throw ConflictTransformError.unknownBlock(first) }
        if !missing.isEmpty { throw ConflictTransformError.unresolvedBlocks(missing.sorted()) }

        return renderResolved(segments, resolution: resolution)
    }

    /// Whole-file "keep ours"/"keep theirs": resolve EVERY block to the same
    /// side. Convenience for the whole-file buttons.
    public static func resolveWholeFile(_ side: BlockResolution, in text: String) throws -> String {
        let count = try blockCount(in: text)
        var choices: [Int: BlockResolution] = [:]
        for index in 0..<count { choices[index] = side }
        return try apply(FileResolution(choices: choices), to: text)
    }

    // MARK: - Internals

    private static func parse(_ text: String) throws -> [ConflictSegment] {
        do {
            return try ConflictParser.parse(text)
        } catch {
            throw ConflictTransformError.parseFailed(String(describing: error))
        }
    }

    private static func renderResolved(
        _ segments: [ConflictSegment], resolution: FileResolution
    ) -> String {
        var out = ""
        var blockIndex = 0
        for segment in segments {
            switch segment {
            case .text(let lines):
                out += lines.map(\.full).joined()
            case .conflict(let block):
                let choice = resolution.choices[blockIndex] ?? .current
                switch choice {
                case .current:
                    out += block.current.map(\.full).joined()
                case .incoming:
                    out += block.incoming.map(\.full).joined()
                case .both:
                    out += block.current.map(\.full).joined()
                    out += block.incoming.map(\.full).joined()
                }
                blockIndex += 1
            }
        }
        return out
    }
}
