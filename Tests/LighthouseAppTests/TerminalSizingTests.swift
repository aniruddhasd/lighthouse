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
        let controller = TerminalController(key: TabKey(taskId: UUID(), tabId: TabID.agent))
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
        let controller = TerminalController(key: TabKey(taskId: UUID(), tabId: TabID.agent))
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
        let controller = TerminalController(key: TabKey(taskId: UUID(), tabId: TabID.agent))
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

    @Test func registryRetainsControllerAndViewAcrossReopens() {
        let registry = SessionRegistry()
        let taskId = UUID()
        let plan = LaunchPlan(
            executable: "/bin/cat", arguments: [], environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory,
            sessionRef: "test-session")

        let first = registry.open(taskId: taskId, tabId: TabID.agent, plan: plan) { _, _ in }
        let viewBefore = ObjectIdentifier(first.terminalView)
        defer { registry.discardTask(taskId: taskId) }

        // Reopening the same tab must reuse controller AND view — recreating
        // either would orphan the pty or drop scrollback.
        let second = registry.open(taskId: taskId, tabId: TabID.agent, plan: plan) { _, _ in }
        #expect(first === second)
        #expect(ObjectIdentifier(second.terminalView) == viewBefore)
        #expect(registry.agentController(taskId: taskId) === first)
    }

    @Test func distinctTabsGetDistinctRetainedTerminals() {
        let registry = SessionRegistry()
        let taskId = UUID()
        let shellId = UUID()
        let plan = LaunchPlan(
            executable: "/bin/cat", arguments: [], environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory, sessionRef: "")
        defer { registry.discardTask(taskId: taskId) }

        let agent = registry.open(taskId: taskId, tabId: TabID.agent, plan: plan) { _, _ in }
        let shell = registry.open(taskId: taskId, tabId: shellId, plan: plan) { _, _ in }
        #expect(agent !== shell)
        #expect(ObjectIdentifier(agent.terminalView) != ObjectIdentifier(shell.terminalView))
        // Each key resolves to its own retained instance across lookups.
        #expect(registry.controller(taskId: taskId, tabId: shellId) === shell)
        #expect(registry.agentController(taskId: taskId) === agent)
        // Closing one tab leaves the other's terminal instance intact.
        registry.closeTab(taskId: taskId, tabId: shellId)
        #expect(registry.controller(taskId: taskId, tabId: shellId) == nil)
        #expect(registry.agentController(taskId: taskId) === agent)
    }
}
