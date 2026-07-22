import AppKit
import Foundation
import LighthouseAdapter
import SwiftTerm

/// A terminal's identity: which task, and which tab within it. The agent tab
/// uses the well-known `TabID.agent`; extra shell tabs get fresh UUIDs.
struct TabKey: Hashable {
    let taskId: UUID
    let tabId: UUID
}

enum TabID {
    /// Stable id for a task's single agent tab (spec: one agent session per
    /// task — the multi-session non-goal stands; extra tabs are plain shells).
    static let agent = UUID(uuidString: "A6E17000-0000-4000-8000-000000000001")!
}

/// A terminal tab under a task (UI model; not persisted). The first tab is
/// the agent session; the rest are plain shells opened with Cmd+T.
struct TerminalTab: Identifiable, Equatable {
    let id: UUID
    var title: String
    let isAgent: Bool
}

/// Owns one terminal view + persistent shell pty per (task, tab). Lives
/// OUTSIDE the SwiftUI view tree: switching tasks/tabs swaps which NSView is
/// displayed, but controllers (and their shells) are retained here so
/// terminals keep running unfocused and survive tab switches (spec §3).
@MainActor
final class SessionRegistry {
    private(set) var controllers: [TabKey: TerminalController] = [:]

    /// Current terminal font size, applied to new terminals at creation and to
    /// every live terminal via `applyFontSize`. Seeded from the persisted
    /// preference (`AppModel.terminalFontSize`) at launch.
    private(set) var fontSize: CGFloat = TerminalFont.defaultSize

    /// Sets the font size for future terminals AND re-fonts every live one, so
    /// a Preferences change takes effect immediately without restarting a
    /// session. SwiftTerm re-lays out on a font change.
    func applyFontSize(_ size: CGFloat) {
        fontSize = size
        let font = TerminalFont.base(size: size)
        for controller in controllers.values {
            controller.terminalView.font = font
        }
    }

    /// Time to let the interactive shell initialise (rc files, ZLE) before
    /// typing the launch command — writing into the master before the line
    /// editor is up can drop or mangle the input. Real payloads confirm the
    /// command lands; the pty stays alive regardless.
    static let commandTypingDelay: Duration = .milliseconds(500)

    /// Opens (or returns) a terminal for a tab. The agent tab passes the
    /// adapter's LaunchPlan (shell + typedCommand); shell tabs pass a plain
    /// shell plan (typedCommand nil).
    @discardableResult
    func open(
        taskId: UUID, tabId: UUID, plan: LaunchPlan,
        onExit: @escaping @MainActor (TabKey, Int32?) -> Void
    ) -> TerminalController {
        let key = TabKey(taskId: taskId, tabId: tabId)
        let controller = controllers[key] ?? TerminalController(key: key, fontSize: fontSize)
        controller.onExit = onExit
        controllers[key] = controller
        controller.start(plan: plan, typingDelay: Self.commandTypingDelay)
        return controller
    }

    func controller(taskId: UUID, tabId: UUID) -> TerminalController? {
        controllers[TabKey(taskId: taskId, tabId: tabId)]
    }

    func agentController(taskId: UUID) -> TerminalController? {
        controller(taskId: taskId, tabId: TabID.agent)
    }

    /// How many of a task's terminals (agent + shells) are currently RUNNING —
    /// the honest "N agents" the Focus footer shows (spec §5.2). A real count of
    /// live ptys, never a fabricated number.
    func runningCount(taskId: UUID) -> Int {
        controllers.values.filter { $0.key.taskId == taskId && $0.isRunning }.count
    }

    /// Closes one tab's terminal.
    func closeTab(taskId: UUID, tabId: UUID) {
        let key = TabKey(taskId: taskId, tabId: tabId)
        controllers[key]?.terminateIfRunning()
        controllers.removeValue(forKey: key)
    }

    /// Closes every tab of a task (task removal / app teardown).
    func discardTask(taskId: UUID) {
        for key in controllers.keys where key.taskId == taskId {
            controllers[key]?.terminateIfRunning()
            controllers.removeValue(forKey: key)
        }
    }

    /// Types `text` into a live terminal WITHOUT a trailing newline (leaves it
    /// for the user to review/submit — the "Ask Claude to resolve" hatch).
    @discardableResult
    func typeIntoSession(taskId: UUID, text: String) -> Bool {
        guard let controller = agentController(taskId: taskId), controller.isRunning else {
            return false
        }
        controller.type(text: text)
        return true
    }

    /// Runs a command line in a live terminal (adds the newline). Used by the
    /// resume affordance to `claude --resume …` inside an existing agent
    /// shell rather than spawning a fresh pty.
    @discardableResult
    func runCommand(taskId: UUID, tabId: UUID, command: String) -> Bool {
        guard let controller = controller(taskId: taskId, tabId: tabId), controller.isRunning else {
            return false
        }
        controller.type(text: command + "\n")
        return true
    }
}

/// One terminal: a SwiftTerm view backed by a persistent interactive login
/// shell. The NSView is created once and reparented as the UI switches
/// tasks/tabs — never recreated per render.
@MainActor
final class TerminalController: NSObject {
    let key: TabKey
    let terminalView: LighthouseTerminalView
    private(set) var isRunning = false
    /// Fires when the SHELL exits (the user typed `exit` — the tab is gone).
    /// This is NOT the agent-end signal any more; the SessionEnd hook is
    /// (the shell outlives Claude).
    var onExit: (@MainActor (TabKey, Int32?) -> Void)?
    private var pendingCommand: String?

    init(key: TabKey, fontSize: CGFloat = TerminalFont.defaultSize) {
        self.key = key
        self.terminalView = LighthouseTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        super.init()
        // JetBrains Mono (bundled) instead of SwiftTerm's default SF Mono;
        // SwiftTerm derives bold/italic from this base. Set before the view is
        // shown so the cell metrics are right from the first layout.
        terminalView.font = TerminalFont.base(size: fontSize)
        // Near-white default text on the dark-gray terminal background
        // (SwiftTerm's default foreground is a dim grey; the gray bg keeps
        // contrast comfortable, see TerminalFont); ANSI output overrides both.
        terminalView.nativeForegroundColor = TerminalFont.foreground
        terminalView.nativeBackgroundColor = TerminalFont.background
        terminalView.processDelegate = self
    }

    /// Builds the environment for a spawned session shell: Lighthouse's own
    /// environment, plus per-plan overrides, plus terminal defaults — with the
    /// child-session marker stripped. Pure so the transcript rule is unit-tested.
    ///
    /// Lighthouse is a session ORCHESTRATOR: the `claude` each terminal runs is
    /// a genuine top-level session that must save its own transcript. But if
    /// Lighthouse was itself launched from within a Claude Code session, its
    /// environment carries `CLAUDE_CODE_CHILD_SESSION=1`, and a nested `claude`
    /// reads that as "I'm a child" and silently turns transcript saving OFF.
    /// Since we copy the whole parent environment into every spawned shell, that
    /// marker would leak into all sessions — so drop it here. Spawned sessions
    /// are never sub-sessions of whatever launched the app.
    static func sessionEnvironment(
        base: [String: String], overrides: [String: String]
    ) -> [String: String] {
        var environment = base
        for (key, value) in overrides { environment[key] = value }
        environment["CLAUDE_CODE_CHILD_SESSION"] = nil
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        return environment
    }

    func start(plan: LaunchPlan, typingDelay: Duration) {
        guard !isRunning else { return }
        let environment = Self.sessionEnvironment(
            base: ProcessInfo.processInfo.environment, overrides: plan.environment)

        isRunning = true
        terminalView.startProcess(
            executable: plan.executable,
            args: plan.arguments,
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: nil,
            currentDirectory: plan.workingDirectory.path)

        if let command = plan.typedCommand {
            pendingCommand = command
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: typingDelay)
                guard let self, self.isRunning, let command = self.pendingCommand else { return }
                self.pendingCommand = nil
                self.terminalView.send(txt: command + "\n")
            }
        }
    }

    /// Sends text verbatim to the pty (caller controls any newline).
    func type(text: String) {
        guard isRunning else { return }
        terminalView.send(txt: text)
    }

    func terminateIfRunning() {
        guard isRunning else { return }
        isRunning = false
        terminalView.process.terminate()
    }
}

extension TerminalController: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            guard self.isRunning else { return }
            self.isRunning = false
            self.onExit?(self.key, exitCode)
        }
    }
}
