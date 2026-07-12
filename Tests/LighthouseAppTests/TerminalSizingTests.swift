import AppKit
import Foundation
import Testing
import LighthouseAdapter
@testable import LighthouseApp

/// AppKit-layer contracts for the terminal: TerminalHostView.embed geometry
/// and the registry's retain-don't-recreate guarantee.
///
/// HONEST LIMIT (learned the hard way, 2026-07-12): these tests passed while
/// the real app still mis-sized, because the actual bug lived in SwiftUI's
/// layout (HSplitView sizing itself to its children's ideal heights and the
/// representable's default sizeThatFits) — and SwiftUI performs layout only
/// with a window server, which `swift test` does not have. The REGRESSION
/// GATE for that layer is the scripted geometry check in
/// Scripts/smoke-run.sh (LIGHTHOUSE_DEBUG_GEOMETRY=1), which asserts the
/// terminal fills the pane at two window sizes inside the running app.
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
