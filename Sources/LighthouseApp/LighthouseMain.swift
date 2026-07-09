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
            }
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
