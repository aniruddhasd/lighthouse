import AppKit
import Foundation
import SwiftTerm

/// Mouse-wheel scrolling inside mouse-tracking TUIs (fixed 2026-07-13).
///
/// Verified facts:
///  - Claude Code enables `?1000h ?1002h ?1003h` (mouse tracking through
///    any-event), `?1006h` (SGR encoding), and `?1049h` (alternate screen) —
///    captured live from its startup bytes (CLI 2.1.205). It scrolls its
///    transcript on xterm wheel-button reports: SGR `ESC[<64;x;yM` (up) /
///    `ESC[<65;x;yM` (down) — what Ghostty/iTerm2/xterm send while an app
///    owns the mouse.
///  - SwiftTerm 1.13.0's `scrollWheel` only scrolls LOCAL scrollback
///    (Mac/MacTerminalView.swift) and never consults `mouseMode`; in an
///    alternate-screen TUI there is no scrollback, so the wheel did nothing.
///  - That `scrollWheel` is `public`, not `open` — it cannot be overridden
///    from outside SwiftTerm, so interception happens via a local NSEvent
///    monitor (WheelReportMonitor) that routes events over our terminals
///    through the testable core below and swallows them only when reported.
///  - `Terminal.encodeButton(button: 4/5, …)` yields the 64/65 codes;
///    `Terminal.sendEvent(buttonFlags:x:y:)` emits them in the negotiated
///    encoding (SGR here) straight to the pty.
final class LighthouseTerminalView: LocalProcessTerminalView {

    /// The monitor's entry point; returns true when the event was consumed
    /// as mouse reports (caller swallows it), false to let SwiftTerm's
    /// scrollback behavior run.
    func handleWheel(event: NSEvent) -> Bool {
        guard event.deltaY != 0 else { return false }
        return sendWheelReportIfTrackingMouse(
            deltaY: event.deltaY, at: gridPosition(of: event))
    }

    /// Testable core: when the app owns the mouse, forward the wheel as
    /// button-4/5 reports and return true. One report per wheel line,
    /// capped at 3 per event (a fast flick arrives as an event stream).
    @discardableResult
    func sendWheelReportIfTrackingMouse(deltaY: CGFloat, at grid: (col: Int, row: Int)) -> Bool {
        let terminal = getTerminal()
        guard allowMouseReporting, terminal.mouseMode != .off else { return false }
        let button = deltaY > 0 ? 4 : 5 // xterm: 4 = wheel up, 5 = wheel down
        let flags = terminal.encodeButton(
            button: button, release: false, shift: false, meta: false, control: false)
        let reports = max(1, min(3, Int(abs(deltaY))))
        for _ in 0..<reports {
            terminal.sendEvent(buttonFlags: flags, x: grid.col, y: grid.row)
        }
        return true
    }

    /// Approximate event → grid mapping from the view's own geometry (cell
    /// metrics are not public API). Wheel-report coordinates are advisory
    /// for full-screen TUIs; clamped to the grid.
    func gridPosition(of event: NSEvent) -> (col: Int, row: Int) {
        let terminal = getTerminal()
        let point = convert(event.locationInWindow, from: nil)
        let cellWidth = max(1, bounds.width / CGFloat(max(1, terminal.cols)))
        let cellHeight = max(1, bounds.height / CGFloat(max(1, terminal.rows)))
        let col = max(0, min(terminal.cols - 1, Int(point.x / cellWidth)))
        let rowFromTop = isFlipped ? point.y : bounds.height - point.y
        let row = max(0, min(terminal.rows - 1, Int(rowFromTop / cellHeight)))
        return (col, row)
    }
}

/// App-wide local monitor: wheel events whose hit view lives inside a
/// LighthouseTerminalView get the mouse-report treatment; everything else
/// (and non-tracking terminals) passes through untouched.
@MainActor
final class WheelReportMonitor {
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Monitors fire on the main thread; assumeIsolated must return a
            // Sendable, so only the consumed verdict crosses out.
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let window = event.window,
                      let hit = window.contentView?.hitTest(event.locationInWindow) else {
                    return false
                }
                var view: NSView? = hit
                while let current = view, !(current is LighthouseTerminalView) {
                    view = current.superview
                }
                guard let terminal = view as? LighthouseTerminalView else { return false }
                return terminal.handleWheel(event: event)
            }
            return consumed ? nil : event
        }
    }

    /// The monitor lives for the app's whole life (owned by AppRuntime);
    /// explicit teardown only — a nonisolated deinit cannot touch it under
    /// strict concurrency.
    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
