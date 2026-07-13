import Foundation
import LighthouseGit

/// One zdiff3 conflict block rendered for the three-way UI. Strings are the
/// joined side content (terminators included) — display only; edits go
/// through `BlockResolution`, never free text (guardrail 2).
public struct ConflictBlockView: Sendable, Equatable, Identifiable {
    public let id: Int          // block index in file order
    public let current: String  // ours
    public let base: String?    // merge base (present with zdiff3)
    public let incoming: String // theirs

    public init(id: Int, current: String, base: String?, incoming: String) {
        self.id = id
        self.current = current
        self.base = base
        self.incoming = incoming
    }
}

/// A conflicted path, classified for the resolver. Binary and delete/modify
/// are recognised from status + numstat and NEVER parsed as text (spec §7).
public struct ClassifiedConflict: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// Text conflict with parseable marker blocks.
        case text(blocks: [ConflictBlockView])
        /// Binary conflict — only whole-file ours/theirs is offered.
        case binary
        /// One side deleted, the other modified. `modifiedSide` is the side
        /// that still has content; the resolver offers keep-modified /
        /// keep-deleted.
        case deleteModify(modifiedSide: GitClient.ConflictSide)
    }
    public let path: String
    public let kind: Kind
    public var id: String { path }
}

public enum ConflictResolverError: Error, Equatable {
    case fileUnreadable(path: String)
    case parseFailed(path: String, detail: String)
    /// A text file still has conflict markers after the transform — not
    /// resolved; must not be staged.
    case stillConflicted(path: String)
}

/// Ties the pure parser/transform to git for the resolution flow, all inside
/// the registered clone's checkout. The only file-content writes are
/// conflict transforms (delete one side + markers) — guardrail 2.
public struct ConflictResolver: Sendable {
    private let git: GitClient

    public init(git: GitClient) {
        self.git = git
    }

    /// Classifies each conflicted path in the clone from status `u` entries
    /// (delete/modify) and numstat (binary vs text), reading text content
    /// only for genuine text conflicts.
    public func classify(in clone: URL) async throws -> [ClassifiedConflict] {
        let status = try await git.status(in: clone)
        var result: [ClassifiedConflict] = []
        for entry in status.unmerged {
            let kind = try await classifyEntry(entry, in: clone)
            result.append(ClassifiedConflict(path: entry.path, kind: kind))
        }
        return result
    }

    private func classifyEntry(
        _ entry: UnmergedEntry, in clone: URL
    ) async throws -> ClassifiedConflict.Kind {
        if entry.kind.isDeleteModify {
            // stage2 (ours) missing → ours deleted, theirs modified.
            let modifiedSide: GitClient.ConflictSide =
                entry.stage2Mode == "000000" ? .theirs : .ours
            return .deleteModify(modifiedSide: modifiedSide)
        }
        if try await git.isConflictBinary(path: entry.path, in: clone) {
            return .binary
        }
        // Text: read the worktree file and parse its marker blocks.
        let fileURL = clone.appendingPathComponent(entry.path)
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            // Not decodable as UTF-8 — treat as binary rather than parse bytes.
            return .binary
        }
        let segments: [ConflictSegment]
        do {
            segments = try ConflictParser.parse(text)
        } catch {
            throw ConflictResolverError.parseFailed(path: entry.path, detail: String(describing: error))
        }
        var blocks: [ConflictBlockView] = []
        var index = 0
        for segment in segments {
            if case .conflict(let block) = segment {
                blocks.append(ConflictBlockView(
                    id: index,
                    current: block.current.map(\.full).joined(),
                    base: block.base?.map(\.full).joined(),
                    incoming: block.incoming.map(\.full).joined()))
                index += 1
            }
        }
        return .text(blocks: blocks)
    }

    // MARK: - Applying resolutions (writes only via transforms / git)

    /// Applies per-block choices to a text conflict, writes the byte-exact
    /// result, verifies no markers remain, and stages it.
    public func resolveText(
        path: String, resolution: FileResolution, in clone: URL
    ) async throws {
        let fileURL = clone.appendingPathComponent(path)
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw ConflictResolverError.fileUnreadable(path: path)
        }
        let resolved: String
        do {
            resolved = try ConflictTransform.apply(resolution, to: text)
        } catch {
            throw ConflictResolverError.parseFailed(path: path, detail: String(describing: error))
        }
        guard !ConflictParser.hasConflictMarkers(resolved) else {
            throw ConflictResolverError.stillConflicted(path: path)
        }
        try Data(resolved.utf8).write(to: fileURL)
        try await git.stage(paths: [path], in: clone)
    }

    /// Whole-file text resolution (every block to the same side), then stage.
    public func resolveWholeFileText(
        path: String, side: BlockResolution, in clone: URL
    ) async throws {
        let fileURL = clone.appendingPathComponent(path)
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw ConflictResolverError.fileUnreadable(path: path)
        }
        let resolved: String
        do {
            resolved = try ConflictTransform.resolveWholeFile(side, in: text)
        } catch {
            throw ConflictResolverError.parseFailed(path: path, detail: String(describing: error))
        }
        try Data(resolved.utf8).write(to: fileURL)
        try await git.stage(paths: [path], in: clone)
    }

    /// Binary whole-file resolution via git (no content parsing).
    public func resolveBinary(
        path: String, side: GitClient.ConflictSide, in clone: URL
    ) async throws {
        try await git.takeWholeFile(side, path: path, in: clone)
    }

    /// Delete/modify resolution: keep the modified content or the deletion.
    public func resolveDeleteModify(
        path: String, keepModified: Bool, modifiedSide: GitClient.ConflictSide, in clone: URL
    ) async throws {
        if keepModified {
            try await git.takeWholeFile(modifiedSide, path: path, in: clone)
        } else {
            try await git.removeConflictedPath(path, in: clone)
        }
    }

    /// Restart a file's conflict markers (zdiff3) — the "start over" action.
    public func rematerialize(path: String, in clone: URL) async throws {
        try await git.rematerializeConflict(path: path, in: clone)
    }
}
