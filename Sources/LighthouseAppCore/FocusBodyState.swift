import Foundation

/// The persistent center-body choice in Focus (handoff §2 Terminal/Summary
/// segmented control; spec §3.4 `termMode`). Distinct from the transient file
/// viewer, which floats OVER whichever mode is active.
public enum BodyMode: String, Equatable, Sendable, CaseIterable, Identifiable {
    case terminal
    case summary
    public var id: String { rawValue }
}

/// The pane the Focus body actually shows — a pure projection of the state
/// below. The viewer is not a `BodyMode`: it is an overlay that WINS when a
/// navigator selection is active (spec §3.4 viewer precedence).
public enum FocusBody: String, Equatable, Sendable {
    case terminal
    case summary
    case viewer
}

/// Pure state machine for the Focus center body (spec §3.4, verified against
/// the prototype's `support.js`). `mode` is the persistent Terminal/Summary
/// choice (`termMode`); `viewerActive` is the transient file-viewer overlay
/// (`viewerId != nil`) that takes precedence whenever set.
///
/// This is the "rules are data, not code" core: every §3.4 transition is a
/// mutating method here and is unit-tested headlessly. The SwiftUI body just
/// renders `effective` from a mounted three-pane ZStack — it owns no rules.
public struct FocusBodyState: Equatable, Sendable {
    public private(set) var mode: BodyMode
    public private(set) var viewerActive: Bool

    public init(mode: BodyMode = .terminal, viewerActive: Bool = false) {
        self.mode = mode
        self.viewerActive = viewerActive
    }

    /// The pane actually shown: the viewer wins whenever active (spec §3.4
    /// "viewer precedence"), otherwise the current mode.
    public var effective: FocusBody {
        if viewerActive { return .viewer }
        switch mode {
        case .terminal: return .terminal
        case .summary: return .summary
        }
    }

    /// Selecting a change / file / commit activates the viewer OVER the current
    /// mode WITHOUT changing it — so closing the viewer returns to whichever
    /// mode was active (spec §3.4: "selecting a file … does not change termMode").
    public mutating func activateViewer() { viewerActive = true }

    /// ⌘J / the viewer's Terminal button closes the viewer and returns to
    /// `mode` (spec §3.4: "showTerminal/⌘J → close the viewer, return to
    /// bodyMode"). It does NOT force `mode` to terminal — a viewer opened over
    /// Summary returns to Summary.
    public mutating func closeViewer() { viewerActive = false }

    /// The Terminal/Summary segmented control: setting a mode also CLEARS the
    /// active viewer (spec §3.4: "setTerminal/setSummary both clear viewerId —
    /// a mode switch exits the viewer").
    public mutating func setMode(_ newMode: BodyMode) {
        mode = newMode
        viewerActive = false
    }
}
