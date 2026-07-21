import AppKit
import SwiftUI
import LighthouseAppCore

@main
struct LighthouseMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var runtime: AppRuntime

    init() {
        let runtime = AppRuntime()
        _runtime = State(initialValue: runtime)
        AppDelegate.runtime = runtime
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(runtime)
        }
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Switch Task…") {
                    runtime.switcherPresented.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)
                // ⌘P quick-open (Command, not Ctrl+P: Ctrl-P is a readline key
                // the terminal owns). Only meaningful in Focus, where a task's
                // file list exists.
                Button("Find File…") {
                    if runtime.nav.view == .focus { runtime.fileFinderPresented = true }
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(runtime.nav.view != .focus)
            }
            // Cmd+T / Cmd+W for terminal tabs. Ctrl+T is deliberately NOT
            // used — it is a control byte that TUIs (Claude Code) intercept.
            CommandGroup(after: .newItem) {
                Button("Register Repo…") { runtime.registerRepoPresented = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("New Terminal Tab") {
                    if let id = runtime.selectedTaskId,
                       let task = runtime.model.tasks.first(where: { $0.id == id }) {
                        runtime.openShellTab(for: task)
                    }
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(runtime.selectedTaskId == nil)

                Button("Close Terminal Tab") {
                    if let id = runtime.selectedTaskId { runtime.closeFocusedTab(for: id) }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(runtime.selectedTaskId == nil)
            }
            CommandGroup(replacing: .help) {
                Button("Run Setup Checks") { runtime.openSetup() }
            }
        }

        // The standard macOS Preferences window (⌘,). A `Settings` scene is a
        // separate window that does NOT inherit the WindowGroup's environment,
        // so the runtime is injected explicitly; PreferencesView themes itself
        // from the same `themeController`.
        Settings {
            PreferencesView()
                .environment(runtime)
        }
    }
}

/// Guardrail UI (spec §3): quitting while agents are working kills their
/// in-flight work — requires a confirmation listing exactly those tasks.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var runtime: AppRuntime?
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Route SIGTERM (logout, kill, smoke harness) through the normal
        // termination path so the quit guardrail and socket cleanup run —
        // the default handler would just kill the process mid-flight.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            NSApplication.shared.terminate(nil)
        }
        source.resume()
        sigtermSource = source
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime = MainActor.assumeIsolated({ AppDelegate.runtime }) else {
            return .terminateNow
        }
        let blocking = MainActor.assumeIsolated { runtime.model.tasksBlockingQuit() }
        guard !blocking.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Agents are still working"
        alert.informativeText =
            "Quitting kills in-flight agent work in:\n\n"
            + blocking.map { "•  \($0.name)" }.joined(separator: "\n")
            + "\n\nConversation context survives — these sessions can be resumed next launch."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppDelegate.runtime }?.shutdown()
    }
}
