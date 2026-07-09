import SwiftUI
import SwiftTerm
import LighthouseAppCore
import LighthouseTaskEngine

struct ContentView: View {
    @Environment(AppRuntime.self) private var runtime
    @State private var showCreateTask = false
    @State private var showRegisterRepo = false
    @State private var taskPendingRemoval: TaskRecord?

    var body: some View {
        @Bindable var runtime = runtime
        NavigationSplitView {
            SidebarView(
                showCreateTask: $showCreateTask,
                showRegisterRepo: $showRegisterRepo,
                taskPendingRemoval: $taskPendingRemoval)
        } detail: {
            if let taskId = runtime.selectedTaskId,
               let task = runtime.model.tasks.first(where: { $0.id == taskId }) {
                TaskDetailView(task: task)
                    .id(task.id)
            } else {
                ContentUnavailableView(
                    "No task selected",
                    systemImage: "rectangle.on.rectangle",
                    description: Text("Create a task or pick one from the sidebar (⌘K)."))
            }
        }
        .sheet(isPresented: $showCreateTask) { CreateTaskSheet() }
        .sheet(isPresented: $showRegisterRepo) { RegisterRepoSheet() }
        .sheet(item: $taskPendingRemoval) { task in RemoveTaskSheet(task: task) }
        .overlay {
            if runtime.switcherPresented {
                SwitcherOverlay()
            }
        }
        .alert(
            "Error", isPresented: .init(
                get: { runtime.lastError != nil },
                set: { if !$0 { runtime.lastError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(runtime.lastError ?? "")
        }
        .safeAreaInset(edge: .bottom) {
            if let degraded = runtime.attentionDegraded {
                Text(degraded)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity)
                    .padding(4)
                    .background(.quaternary)
            }
        }
    }
}

/// Terminal on the left; the review pane (build step 5) is a placeholder.
struct TaskDetailView: View {
    @Environment(AppRuntime.self) private var runtime
    let task: TaskRecord

    var body: some View {
        HSplitView {
            terminalPane
                .frame(minWidth: 420)
            ContentUnavailableView(
                "Review pane",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Live diff-vs-base lands in a later step."))
            .frame(minWidth: 220)
        }
        .navigationTitle(task.name)
        .navigationSubtitle(task.branch)
    }

    @ViewBuilder
    private var terminalPane: some View {
        if let controller = runtime.registry.controller(for: task.id), controller.isRunning {
            TerminalHostView(terminalView: controller.terminalView)
        } else {
            VStack(spacing: 12) {
                let state = runtime.model.attentionState(of: task.id)
                if state == .dirty {
                    Label("Session ended — workspace may hold unfinished work",
                          systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                }
                if runtime.model.canResume(task) {
                    Button {
                        runtime.resumeSession(for: task)
                    } label: {
                        Label("Resume session", systemImage: "play.circle")
                    }
                    .controlSize(.large)
                    Text("Continues the stored conversation (claude --resume). If its history is gone, the terminal shows the error.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No session for this task.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Hosts the registry-owned NSView. makeNSView returns the RETAINED view —
/// SwiftUI reparents it; it never recreates the terminal or its pty.
struct TerminalHostView: NSViewRepresentable {
    let terminalView: LocalProcessTerminalView

    func makeNSView(context: Context) -> LocalProcessTerminalView { terminalView }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
