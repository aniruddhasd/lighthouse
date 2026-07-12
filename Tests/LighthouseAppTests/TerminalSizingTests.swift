import AppKit
import Foundation
import Testing
import LighthouseAdapter
@testable import LighthouseApp

/// Regression tests for the 2026-07-12 sizing bug: the terminal rendered as
/// a small fixed box centered in the pane instead of filling it, because the
/// bare terminal view's autolayout fitting size drove SwiftUI's sizing.
/// These pin the geometry contract of TerminalHostView.embed and the
/// registry's retain-don't-recreate guarantee. (SwiftUI's own layout pass
/// and the live TIOCSWINSZ reflow are not unit-testable — the smoke run and
/// SwiftTerm 1.13.0's setFrameSize→sizeChanged source cover those.)
@MainActor
@Suite("Terminal sizing and retention")
struct TerminalSizingTests {

    @Test func embeddedTerminalFillsContainerAndTracksResize() {
        let controller = SessionController(taskId: UUID())
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        TerminalHostView.embed(controller.terminalView, in: container)
        #expect(controller.terminalView.frame == container.bounds)

        // The container resize must reach the terminal (autoresizing pin)...
        container.setFrameSize(NSSize(width: 1200, height: 800))
        container.layoutSubtreeIfNeeded()
        #expect(controller.terminalView.frame == container.bounds)
        #expect(controller.terminalView.frame.size == NSSize(width: 1200, height: 800))
    }

    @Test func widerFrameMeansMoreTerminalColumns() {
        // The grid must reflow with geometry — this is what makes the TUI
        // usable, not just the pixels.
        let controller = SessionController(taskId: UUID())
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        TerminalHostView.embed(controller.terminalView, in: container)
        let narrowCols = controller.terminalView.getTerminal().cols

        container.setFrameSize(NSSize(width: 1400, height: 200))
        container.layoutSubtreeIfNeeded()
        let wideCols = controller.terminalView.getTerminal().cols
        #expect(wideCols > narrowCols, "grid did not reflow: \(narrowCols) → \(wideCols)")
    }

    @Test func reembeddingIntoANewContainerAdoptsTheSameView() {
        // Task switch: SwiftUI builds a fresh container; the RETAINED view
        // moves over — never a new terminal instance.
        let controller = SessionController(taskId: UUID())
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        TerminalHostView.embed(controller.terminalView, in: first)
        let instanceBefore = ObjectIdentifier(controller.terminalView)

        let second = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        TerminalHostView.embed(controller.terminalView, in: second)
        #expect(controller.terminalView.superview === second)
        #expect(first.subviews.isEmpty)
        #expect(ObjectIdentifier(controller.terminalView) == instanceBefore)
        #expect(controller.terminalView.frame == second.bounds)
    }

    @Test func registryRetainsControllerAndViewAcrossStarts() {
        let registry = SessionRegistry()
        let taskId = UUID()
        let plan = LaunchPlan(
            executable: "/bin/cat", arguments: [], environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory,
            sessionRef: "test-session")

        let first = registry.start(taskId: taskId, plan: plan) { _, _ in }
        let viewBefore = ObjectIdentifier(first.terminalView)
        defer { registry.discard(taskId: taskId) }

        // A second start (the resume path) must reuse controller AND view —
        // recreating either would orphan the pty or drop scrollback.
        let second = registry.start(taskId: taskId, plan: plan) { _, _ in }
        #expect(first === second)
        #expect(ObjectIdentifier(second.terminalView) == viewBefore)
        #expect(registry.controller(for: taskId) === first)
    }
}
