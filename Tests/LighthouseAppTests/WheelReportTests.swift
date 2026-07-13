import AppKit
import Foundation
import Testing
import LighthouseAdapter
@testable import LighthouseApp

/// Real-pty proof of the wheel fix: a child process captures its stdin to a
/// file; the emulator is put into the exact modes Claude Code enables
/// (`?1003h ?1006h`, captured live from its startup bytes); a wheel event
/// must arrive at the pty as SGR wheel-button reports ESC[<64/65;x;yM.
@MainActor
@Suite("Terminal wheel → mouse reports", .serialized)
final class WheelReportTests {
    private let registry = SessionRegistry()
    private let captureFile: URL
    private let taskId = UUID()

    init() {
        captureFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("wheel-capture-\(UUID().uuidString.prefix(8)).bin")
    }

    deinit {
        try? FileManager.default.removeItem(at: captureFile)
    }

    private func startCapturingController() -> SessionController {
        // raw -echo: like a real TUI, so report bytes (which carry no
        // newline) leave the tty's line buffer immediately instead of
        // being held and echoed.
        let plan = LaunchPlan(
            executable: "/bin/sh",
            arguments: ["-c", "stty raw -echo; cat > '\(captureFile.path)'"],
            environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory,
            sessionRef: "wheel-test")
        return registry.start(taskId: taskId, plan: plan) { _, _ in }
    }

    private func capturedBytes(deadline: Duration = .seconds(3)) async throws -> Data {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < deadline {
            if let data = try? Data(contentsOf: captureFile), !data.isEmpty {
                // Small settle for trailing reports.
                try await Task.sleep(for: .milliseconds(150))
                return (try? Data(contentsOf: captureFile)) ?? data
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return (try? Data(contentsOf: captureFile)) ?? Data()
    }

    // MARK: The negative first: no tracking → no reports

    @Test func withoutMouseTrackingWheelSendsNothingToThePty() async throws {
        let controller = startCapturingController()
        defer { registry.discard(taskId: taskId) }
        // mouseMode is .off by default — the core must decline.
        let consumed = controller.terminalView.sendWheelReportIfTrackingMouse(
            deltaY: 3, at: (col: 0, row: 0))
        #expect(!consumed)
        try await Task.sleep(for: .milliseconds(400))
        #expect(((try? Data(contentsOf: captureFile)) ?? Data()).isEmpty)
    }

    // MARK: Claude Code's exact modes

    @Test func wheelBecomesSGRReportsUnderClaudeCodeModes() async throws {
        let controller = startCapturingController()
        defer { registry.discard(taskId: taskId) }
        // Simulate the child enabling Claude Code's modes (any-event
        // tracking + SGR), as if these bytes came from the pty.
        controller.terminalView.feed(text: "\u{1b}[?1003h\u{1b}[?1006h")

        let consumed = controller.terminalView.sendWheelReportIfTrackingMouse(
            deltaY: 3, at: (col: 5, row: 2))
        #expect(consumed)

        let bytes = try await capturedBytes()
        let text = String(decoding: bytes, as: UTF8.self)
        // 3 wheel lines → 3 capped reports of button 64 (wheel up), SGR form.
        let upReports = text.components(separatedBy: "\u{1b}[<64;").count - 1
        #expect(upReports == 3, "expected 3 SGR wheel-up reports, got: \(text.debugDescription)")
        #expect(text.contains("M"), "SGR press reports end in M")
    }

    @Test func wheelDownSendsButton65() async throws {
        let controller = startCapturingController()
        defer { registry.discard(taskId: taskId) }
        controller.terminalView.feed(text: "\u{1b}[?1000h\u{1b}[?1006h") // plain vt200 tracking

        let consumed = controller.terminalView.sendWheelReportIfTrackingMouse(
            deltaY: -1, at: (col: 0, row: 0))
        #expect(consumed)

        let text = String(decoding: try await capturedBytes(), as: UTF8.self)
        #expect(text.contains("\u{1b}[<65;"), "wheel down must be button 65: \(text.debugDescription)")
    }

    // MARK: Through a constructed NSEvent (the monitor's path)

    @Test func constructedScrollEventFlowsThroughHandleWheel() async throws {
        let controller = startCapturingController()
        defer { registry.discard(taskId: taskId) }
        controller.terminalView.feed(text: "\u{1b}[?1003h\u{1b}[?1006h")

        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
            wheel1: 2, wheel2: 0, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: cgEvent))
        #expect(controller.terminalView.handleWheel(event: event))

        let text = String(decoding: try await capturedBytes(), as: UTF8.self)
        #expect(text.contains("\u{1b}[<64;") || text.contains("\u{1b}[<65;"),
                "constructed event produced no report: \(text.debugDescription)")
    }
}
