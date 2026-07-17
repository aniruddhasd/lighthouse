import Testing
@testable import LighthouseAppCore

/// The exact §3.4 body-state rules (verified against the prototype). Pure and
/// headless — the SwiftUI geometry that renders `effective` is proven by the
/// FOCUS runtime gate; these lock the LOGIC so a refactor cannot drift it.
@Suite("Focus body state (§3.4)")
struct FocusBodyStateTests {

    @Test func defaultsToTerminalNoViewer() {
        let state = FocusBodyState()
        #expect(state.mode == .terminal)
        #expect(state.viewerActive == false)
        #expect(state.effective == .terminal)
    }

    // Rule: selecting a change/file/commit activates the viewer OVER the
    // current mode, without changing the mode.
    @Test func activatingViewerWinsButKeepsMode() {
        var state = FocusBodyState(mode: .terminal)
        state.activateViewer()
        #expect(state.viewerActive)
        #expect(state.mode == .terminal, "activating the viewer must not change the mode")
        #expect(state.effective == .viewer, "viewer takes precedence over terminal")
    }

    // Rule: the viewer wins over Summary too, and closing it returns to
    // whichever mode was active (Summary here, not Terminal).
    @Test func viewerWinsOverSummaryAndClosesBackToSummary() {
        var state = FocusBodyState(mode: .summary)
        state.activateViewer()
        #expect(state.effective == .viewer)
        state.closeViewer()
        #expect(state.viewerActive == false)
        #expect(state.effective == .summary, "closing the viewer returns to the active mode")
    }

    // Rule: ⌘J / showTerminal closes the viewer and returns to the mode.
    @Test func closeViewerReturnsToMode() {
        var state = FocusBodyState(mode: .terminal, viewerActive: true)
        #expect(state.effective == .viewer)
        state.closeViewer()
        #expect(state.effective == .terminal)
    }

    // Rule: the segmented control (setMode) CLEARS an active viewer — a mode
    // switch exits the viewer, for both destinations.
    @Test func setModeClearsActiveViewer() {
        var state = FocusBodyState(mode: .terminal, viewerActive: true)
        state.setMode(.summary)
        #expect(state.mode == .summary)
        #expect(state.viewerActive == false, "switching mode must clear the viewer")
        #expect(state.effective == .summary)

        state.activateViewer()
        #expect(state.effective == .viewer)
        state.setMode(.terminal)
        #expect(state.viewerActive == false)
        #expect(state.effective == .terminal)
    }

    // Setting the SAME mode still clears the viewer (mode switch semantics are
    // about the control being used, not about the value changing).
    @Test func setSameModeStillClearsViewer() {
        var state = FocusBodyState(mode: .terminal, viewerActive: true)
        state.setMode(.terminal)
        #expect(state.viewerActive == false)
        #expect(state.effective == .terminal)
    }
}
