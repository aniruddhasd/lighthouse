import AppKit
import Foundation
import LighthouseAdapter
import SwiftTerm

/// Owns one terminal view + pty per task. Lives OUTSIDE the SwiftUI view
/// tree on purpose: switching tasks swaps which NSView is displayed, but the
/// controller (and its child process) is retained here, keyed by task id —
/// sessions keep running while unfocused (spec §3).
@MainActor
final class SessionRegistry {
    private(set) var controllers: [UUID: SessionController] = [:]

    /// Starts (or restarts, for resume) the session for a task.
    func start(
        taskId: UUID, plan: LaunchPlan,
        onExit: @escaping @MainActor (UUID, Int32?) -> Void
    ) -> SessionController {
        let controller = controllers[taskId] ?? SessionController(taskId: taskId)
        controller.onExit = onExit
        controllers[taskId] = controller
        controller.start(plan: plan)
        return controller
    }

    func controller(for taskId: UUID) -> SessionController? {
        controllers[taskId]
    }

    func discard(taskId: UUID) {
        controllers[taskId]?.terminateIfRunning()
        controllers.removeValue(forKey: taskId)
    }

    /// Types `text` into the task's pty WITHOUT submitting it (no trailing
    /// newline) — the "Ask Claude to resolve" hatch leaves the composed
    /// prompt for the user to review and press Enter (spec §2.5: the app
    /// hands work to the agent, it does not act on the user's behalf).
    /// Returns false if the task has no live session.
    @discardableResult
    func typeIntoSession(taskId: UUID, text: String) -> Bool {
        guard let controller = controllers[taskId], controller.isRunning else { return false }
        controller.terminalView.send(txt: text)
        return true
    }
}

/// One task's terminal: the SwiftTerm view, the pty process state, and the
/// exit callback. The NSView is created once and reparented as the UI
/// switches tasks — never recreated per render.
@MainActor
final class SessionController: NSObject {
    let taskId: UUID
    let terminalView: LighthouseTerminalView
    private(set) var isRunning = false
    var onExit: (@MainActor (UUID, Int32?) -> Void)?

    init(taskId: UUID) {
        self.taskId = taskId
        self.terminalView = LighthouseTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        super.init()
        terminalView.processDelegate = self
    }

    func start(plan: LaunchPlan) {
        guard !isRunning else { return }
        // Full user environment + the plan's extras + sane terminal vars.
        // The login shell rebuilds most of this, but TERM must be right for
        // SwiftTerm's emulation from the first byte.
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in plan.environment {
            environment[key] = value
        }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }

        isRunning = true
        terminalView.startProcess(
            executable: plan.executable,
            args: plan.arguments,
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: nil,
            currentDirectory: plan.workingDirectory.path)
    }

    func terminateIfRunning() {
        guard isRunning else { return }
        isRunning = false
        terminalView.process.terminate()
    }
}

/// SwiftTerm invokes these on the main queue by default (LocalProcess's
/// dispatchQueue), but the protocol is not actor-isolated — hop explicitly
/// so an off-main call can never corrupt state.
extension SessionController: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            guard self.isRunning else { return }
            self.isRunning = false
            self.onExit?(self.taskId, exitCode)
        }
    }
}
