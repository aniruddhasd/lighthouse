import Foundation
import LighthouseGit

/// Which surface the center stage shows. Terminal is the default; selecting a
/// navigator item swaps to the content viewer (the "auto-expand"), and an
/// explicit control/keystroke swaps back to the still-running terminal.
public enum CenterStageMode: Equatable, Sendable {
    case terminal
    case viewer

    public var toggled: CenterStageMode { self == .terminal ? .viewer : .terminal }
}

/// The three navigator surfaces over the selected repo. Raw values are stable
/// (used as tags / ids); `title` and `systemImage` drive the segmented control.
public enum NavigatorMode: String, CaseIterable, Identifiable, Sendable {
    case changes
    case files
    case history

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .changes: return "Changes"
        case .files: return "Files"
        case .history: return "History"
        }
    }

    public var systemImage: String {
        switch self {
        case .changes: return "plusminus.circle"
        case .files: return "folder"
        case .history: return "clock"
        }
    }
}

/// A fully-built page to load into the center content viewer, plus how the
/// viewer should behave after load. A pure value so the navigator→viewer
/// mapping is unit-testable without SwiftUI, WebKit, or a live git repo — the
/// async git reads happen in the model; every HTML/decision step lives here.
public enum ViewerRequest: Equatable, Sendable {
    /// A rendered diff page (diff2html). `scrollToFile`, when set, is the
    /// repo-relative path the viewer scrolls to after the page loads.
    case diff(html: String, scrollToFile: String?)
    /// A rendered read-only file page. `scrollToLine`, when set, is the 1-based
    /// line the viewer scrolls to and highlights after the page loads (the ⌘F
    /// content-search jump).
    case file(html: String, scrollToLine: Int?)

    public var html: String {
        switch self {
        case .diff(let html, _): return html
        case .file(let html, _): return html
        }
    }

    public var scrollToFile: String? {
        switch self {
        case .diff(_, let file): return file
        case .file: return nil
        }
    }

    public var scrollToLine: Int? {
        switch self {
        case .diff: return nil
        case .file(_, let line): return line
        }
    }
}

/// Pure mapping from a navigator selection (plus the data already fetched for
/// it) to a `ViewerRequest`. Same untrusted-content discipline as the page
/// builders it delegates to: no repo byte — content, filename, or placeholder
/// message — is ever emitted raw; it all flows through the base64/CSP renderers.
public enum NavigatorPresenter {

    /// Changes: promote the whole live diff into the center and scroll to the
    /// picked file (the tree click-to-scroll, now against the center viewer).
    public static func changesSelection(patch: String, file: String) -> ViewerRequest {
        .diff(html: DiffPageBuilder.page(diff: patch), scrollToFile: file)
    }

    /// History: render the picked commit's diff (no scroll target — the whole
    /// commit is the subject).
    public static func commitSelection(patch: String) -> ViewerRequest {
        .diff(html: DiffPageBuilder.page(diff: patch), scrollToFile: nil)
    }

    /// Files: render the picked file, mapping the non-text states to safe
    /// placeholders (never a throw, never raw content — the placeholder message
    /// is carried through the SAME escaped renderer as real file content, so it
    /// cannot itself become an injection vector).
    public static func fileSelection(
        contents: FileContents, filename: String, scrollToLine: Int? = nil
    ) -> ViewerRequest {
        .file(html: filePage(for: contents, filename: filename), scrollToLine: scrollToLine)
    }

    /// The file → HTML step in isolation (the piece worth testing directly:
    /// binary and too-large render to placeholders, not a crash and not raw).
    public static func filePage(for contents: FileContents, filename: String) -> String {
        switch contents {
        case .text(let text):
            return FilePageBuilder.page(
                content: text, filename: filename,
                rendering: FileRendering.forFile(named: filename, content: text))
        case .binary:
            return FilePageBuilder.page(
                content: "Binary file — not shown.", filename: filename)
        case .tooLarge(let bytes):
            return FilePageBuilder.page(
                content: "File is too large to display (\(bytes) bytes).", filename: filename)
        }
    }
}

/// Formats git's strict-ISO author date (`%aI`) as a short relative string for
/// the history list. Pure and total: an unparseable input falls back to the raw
/// string rather than throwing or showing nothing.
public enum CommitDateFormatter {
    public static func relativeString(from isoDate: String, now: Date = Date()) -> String {
        // Formatters are non-Sendable and cheap enough to build per call; a
        // shared static would be a concurrency hazard for no meaningful win.
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: isoDate) else { return isoDate }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: now)
    }
}
