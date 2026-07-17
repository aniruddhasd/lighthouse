import AppKit
import Foundation
import SwiftUI

/// Diagnostic scar from the terminal-sizing bug (2026-07-12): unit tests
/// proved the AppKit layer while the real app still mis-sized, because the
/// failure lived in the SwiftUI↔representable size negotiation that only a
/// running app exercises. This env-gated mode makes real-app geometry
/// observable and scriptable:
///
///   LIGHTHOUSE_DEBUG_GEOMETRY=1  → an ephemeral probe task with a /bin/cat
///   session is selected at launch, GEOMETRY lines are printed on every
///   layout pass, and after the first REAL layout is observed the window is
///   resized once (verified, retried — never fire-and-forget) so the check
///   sees two window sizes. Scripts/smoke-run.sh parses stage markers and
///   asserts fill at both sizes.
enum GeometryDebug {
    static let enabled = ProcessInfo.processInfo.environment["LIGHTHOUSE_DEBUG_GEOMETRY"] == "1"

    /// The last window content size a sample line was actually EMITTED for —
    /// the driver keys its phases off this instead of wall-clock settling
    /// (SwiftUI coalesces layout passes; a size read from the window can be
    /// true without any layout ever running at it). Main-thread only.
    nonisolated(unsafe) static var lastLoggedWindowSize: NSSize?

    static func log(window: NSSize, container: NSRect, terminal: NSRect) {
        guard enabled else { return }
        lastLoggedWindowSize = window
        let line = String(
            format: "GEOMETRY window=%.0fx%.0f container=%.0fx%.0f terminal=%.0fx%.0f terminalOrigin=%.0f,%.0f\n",
            window.width, window.height,
            container.width, container.height,
            terminal.width, terminal.height,
            terminal.origin.x, terminal.origin.y)
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    static func stage(_ message: String) {
        guard enabled else { return }
        FileHandle.standardOutput.write(Data("GEOMETRY-STAGE \(message)\n".utf8))
    }
}

/// Drives the scripted window resize EVENT-DRIVEN and SIZE-AGNOSTIC. Two
/// harness generations died here (2026-07-12):
///  1. a wall-clock timer raced window creation and silently no-opped
///     (`NSApp.windows.first?` on an empty array);
///  2. demanding an EXACT target size failed everywhere, because SwiftUI
///     clamps the window to its own minimum content width (observed: 1436) —
///     a restored frame already at that minimum changes by nothing at all.
/// Now: start from the first real layout pass (window handle in hand),
/// remember the initial content size, and walk a candidate ladder (shrink
/// width → shrink height → grow width) until the OBSERVED size differs from
/// the initial by more than 40pt in either dimension. Every stage is logged
/// so a stalled run says exactly where it stalled.
@MainActor
final class GeometryResizeDriver {
    static let shared = GeometryResizeDriver()

    private var started = false

    func noteLayout(of window: NSWindow?) {
        guard GeometryDebug.enabled, !started, let window else { return }
        started = true
        GeometryDebug.stage(
            "first-layout content=\(Int(window.contentLayoutRect.width))x\(Int(window.contentLayoutRect.height))")

        Task { @MainActor [weak window] in
            // Phase A — normalize: macOS saved-state restoration carries the
            // PREVIOUS run's resized frame into this one, so the starting
            // size is unpredictable run-to-run. Drive toward a baseline
            // (SwiftUI clamps to its own content minimums — that is fine,
            // any stable size works), then WAIT until a sample has actually
            // been LOGGED at the current size: a size read off the window
            // can be true without any layout pass ever running at it
            // (coalescing), and the parser can only assert on logged samples.
            let requested = NSSize(width: 1500, height: 800)
            for _ in 1...4 {
                guard let window else { return }
                window.setContentSize(requested)
                try? await Task.sleep(for: .milliseconds(250))
                if abs(window.contentLayoutRect.width - requested.width) <= 2 { break }
            }
            guard let window else { return }
            var initial = window.contentLayoutRect.size
            for _ in 1...20 {
                if let logged = GeometryDebug.lastLoggedWindowSize,
                   abs(logged.width - initial.width) <= 2,
                   abs(logged.height - initial.height) <= 2 {
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
                initial = window.contentLayoutRect.size
            }
            if let logged = GeometryDebug.lastLoggedWindowSize {
                // The parser asserts on logged samples; report THAT size.
                initial = logged
            }
            GeometryDebug.stage("baseline content=\(Int(initial.width))x\(Int(initial.height))")

            // Phase B — produce a DIFFERENT size. Exact targets are
            // SwiftUI-clamped (min content width ~1436 observed), so success
            // means "observed differs from baseline by >40pt in some
            // dimension", walking a ladder: shrink height (least likely to
            // clamp) → grow width → shrink width.
            let candidates = [
                NSSize(width: initial.width, height: max(420, initial.height - 300)),
                NSSize(width: initial.width + 250, height: initial.height),
                NSSize(width: max(800, initial.width - 400), height: initial.height),
            ]
            // `window` is strongly held from here on (guarded above) — fine
            // for a short-lived debug probe.
            for (index, target) in candidates.enumerated() {
                for attempt in 1...4 {
                    window.setContentSize(target)
                    try? await Task.sleep(for: .milliseconds(250))
                    let observed = window.contentLayoutRect.size
                    GeometryDebug.stage(
                        "resize-attempt candidate=\(index) attempt=\(attempt) target=\(Int(target.width))x\(Int(target.height)) observed=\(Int(observed.width))x\(Int(observed.height))")
                    guard abs(observed.width - initial.width) > 40
                        || abs(observed.height - initial.height) > 40 else { continue }
                    // Report the size a sample was actually LOGGED at, not the
                    // window's current size: SwiftUI coalesces layout passes,
                    // so a size can be true without a pass ever running at it,
                    // and the parser only sees logged samples. Wait for one.
                    for _ in 1...20 {
                        if let logged = GeometryDebug.lastLoggedWindowSize,
                           abs(logged.width - initial.width) > 40
                            || abs(logged.height - initial.height) > 40 {
                            GeometryDebug.stage(
                                "resize-applied observed=\(Int(logged.width))x\(Int(logged.height))")
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
            GeometryDebug.stage("resize-failed")
        }
    }
}

/// Container that reports its own and its terminal subview's frames on every
/// layout pass while the debug mode is on, and kicks the resize driver on
/// the first real pass.
final class TerminalContainerView: NSView {
    override func layout() {
        super.layout()
        guard let terminal = subviews.first else { return }
        if GeometryDebug.enabled {
            GeometryDebug.log(
                window: window?.contentLayoutRect.size ?? .zero,
                container: frame,
                terminal: terminal.frame)
            if let window, window.frame.width > 0 {
                MainActor.assumeIsolated {
                    GeometryResizeDriver.shared.noteLayout(of: window)
                }
            }
        }
        // The FOCUS gate reuses this real NSView measurement to prove the
        // terminal fills the center column's body (not centered/collapsed at
        // 181pt — the sizing scar) in the reshaped layout.
        if FocusDebug.enabled {
            let win = window?.contentLayoutRect.size ?? .zero
            FocusDebug.emit(String(
                format: "terminal window=%.0fx%.0f container=%.0fx%.0f terminal=%.0fx%.0f",
                win.width, win.height, frame.width, frame.height,
                terminal.frame.width, terminal.frame.height))
        }
    }
}

/// Which build is running — never ambiguous again. make-app.sh stamps the
/// git short hash into CFBundleVersion; bare `swift run` builds show "dev".
enum BuildInfo {
    static var stamp: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            .flatMap { $0 == "1" ? nil : $0 } ?? "dev"
    }
}

/// SwiftUI-side size probe: logs the ACTUAL laid-out size of the view it is
/// attached to, labeled, on every change. Debug mode only; otherwise inert.
struct DebugSizeModifier: ViewModifier {
    let label: String

    func body(content: Content) -> some View {
        if GeometryDebug.enabled {
            content.background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { report(geo.size) }
                        .onChange(of: geo.size) { _, new in report(new) }
                })
        } else {
            content
        }
    }

    private func report(_ size: CGSize) {
        let line = String(
            format: "GEOMETRY-SWIFTUI label=%@ size=%.0fx%.0f\n", label, size.width, size.height)
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}

extension View {
    func debugSize(_ label: String) -> some View {
        modifier(DebugSizeModifier(label: label))
    }
}
