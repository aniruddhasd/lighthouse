import Foundation
import LighthouseGit

/// Which changes the review pane shows.
public enum DiffScope: String, Sendable, CaseIterable, Equatable {
    /// Working tree (staged + unstaged) vs HEAD — uncommitted work only.
    case uncommitted
    /// The whole branch's change vs the merge base with its base branch.
    case vsBase
}

/// One snapshot of "what changed" for the review pane.
public struct LiveDiff: Sendable, Equatable {
    /// Raw git patch text (size-capped per file), including untracked files
    /// rendered as added-file patches.
    public let patch: String
    /// Tracked changes (committed + staged + unstaged vs merge base).
    public let entries: [DiffEntry]
    /// Untracked paths (already respecting .gitignore and info/exclude —
    /// so Lighthouse's own settings.local.json never shows up here).
    public let untracked: [String]

    public init(patch: String, entries: [DiffEntry], untracked: [String]) {
        self.patch = patch
        self.entries = entries
        self.untracked = untracked
    }
}

/// Produces the live diff-vs-base for a workspace: committed + staged +
/// unstaged relative to the merge base with the base branch (one
/// `git diff --merge-base` invocation, doc-verified), PLUS untracked files
/// rendered as added-file patches — agents write new files without staging
/// them, and a live review surface that hides new files would miss most of
/// the work in flight.
public struct LiveDiffService: Sendable {
    /// Per-file render cap. diff2html builds a DOM node per line; beyond a
    /// few hundred KB a single file makes the pane unusable, and real source
    /// files are far smaller — 500 KB keeps generated code visible while
    /// bounding the DOM. Capped files render as a one-line notice.
    public static let maxFileSectionBytes = 500_000

    private let git: GitClient

    public init(git: GitClient) {
        self.git = git
    }

    /// Diff-vs-base: the whole branch's change (committed + staged + unstaged)
    /// relative to the merge base with `baseBranch`, plus untracked files.
    public func liveDiff(workspace: URL, baseBranch: String) async throws -> LiveDiff {
        let patch = try await git.liveDiff(againstMergeBaseOf: baseBranch, in: workspace)
        let entries = try await git.liveDiffNameStatus(againstMergeBaseOf: baseBranch, in: workspace)
        return try await assemble(basePatch: patch, entries: entries, workspace: workspace)
    }

    /// Uncommitted-only: the working tree (staged + unstaged) relative to HEAD,
    /// plus untracked files — "what have I not committed yet", excluding
    /// already-committed branch work.
    public func uncommittedDiff(workspace: URL) async throws -> LiveDiff {
        let patch = try await git.uncommittedDiff(in: workspace)
        let entries = try await git.uncommittedNameStatus(in: workspace)
        return try await assemble(basePatch: patch, entries: entries, workspace: workspace)
    }

    /// Dispatch by the review pane's selected scope.
    public func diff(workspace: URL, baseBranch: String, scope: DiffScope) async throws -> LiveDiff {
        switch scope {
        case .uncommitted: return try await uncommittedDiff(workspace: workspace)
        case .vsBase: return try await liveDiff(workspace: workspace, baseBranch: baseBranch)
        }
    }

    /// Appends untracked files (as added-file patches, size-capped) to a tracked
    /// patch and caps oversized sections — shared by both scopes so untracked
    /// handling never diverges between them.
    private func assemble(
        basePatch: String, entries: [DiffEntry], workspace: URL
    ) async throws -> LiveDiff {
        var patch = basePatch
        let untracked = try await git.status(in: workspace).untracked.sorted()

        for path in untracked {
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: workspace.appendingPathComponent(path).path)
            let size = (attributes?[.size] as? Int) ?? 0
            if size > Self.maxFileSectionBytes {
                patch += Self.oversizedStub(path: path, bytes: size)
            } else {
                patch += try await git.untrackedFilePatch(for: path, in: workspace)
            }
        }

        return LiveDiff(
            patch: PatchCapper.cappingFileSections(of: patch, at: Self.maxFileSectionBytes),
            entries: entries,
            untracked: untracked)
    }

    static func oversizedStub(path: String, bytes: Int) -> String {
        """
        diff --git a/\(path) b/\(path)
        --- /dev/null
        +++ b/\(path)
        @@ -0,0 +1 @@
        +Lighthouse: diff omitted — \(bytes / 1024) KB exceeds the \(maxFileSectionBytes / 1000) KB render cap.

        """
    }
}

/// Caps individual per-file sections of a raw git patch. Pure and separately
/// testable; never alters sections under the cap byte-for-byte.
public enum PatchCapper {
    public static func cappingFileSections(of patch: String, at cap: Int) -> String {
        guard patch.utf8.count > cap else { return patch }
        var sections: [String] = []
        var current = ""
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git "), !current.isEmpty {
                sections.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { sections.append(current) }

        return sections.map { section in
            guard section.utf8.count > cap else { return section }
            let header = section.split(separator: "\n").first.map(String.init) ?? "diff --git a/? b/?"
            let path = header.components(separatedBy: " b/").last ?? "?"
            return LiveDiffService.oversizedStub(path: path, bytes: section.utf8.count)
        }.joined()
    }
}
