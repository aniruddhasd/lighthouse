import Foundation

/// Result of `GitClient.fileContents` — a filesystem read of a repo file for
/// the content viewer. Non-text and oversized files are reported as distinct
/// cases (not thrown) so the viewer can show a purposeful placeholder instead
/// of failing. Text is decoded UTF-8, lossily (invalid bytes → U+FFFD).
///
/// Return shape chosen deliberately (spec left this open): the simplest set
/// that lets the viewer render text, refuse to render binary, and explain a
/// too-large file with its size. Errors (traversal, missing file) stay as
/// thrown `GitClientError`s — they are faults, not renderable states.
public enum FileContents: Sendable, Equatable {
    /// Decoded text ready to render.
    case text(String)
    /// A NUL byte appeared in the first ~8 KiB — treated as binary, not rendered.
    case binary
    /// The file exceeds the render cap; `bytes` is its actual size on disk.
    case tooLarge(bytes: Int)
}
