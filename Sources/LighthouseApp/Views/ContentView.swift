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

/// Terminal on the left; the live review pane on the right.
struct TaskDetailView: View {
    @Environment(AppRuntime.self) private var runtime
    let task: TaskRecord

    var body: some View {
        HSplitView {
            terminalPane
                .frame(minWidth: 420)
                .debugSize("terminalPane")
            rightPane
                // Expand, never ideal-size: this child's ideal height is what
                // collapsed the whole split before (see comment below).
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                .debugSize("reviewPane")
        }
        // Root cause of the sizing bug (pinned by the geometry probes,
        // 2026-07-12): HSplitView sizes itself to its children's IDEAL
        // heights — the review placeholder's ~181pt — and the detail column
        // then centers the whole 181pt strip. Forcing the split (and both
        // children) to expand makes it adopt the full detail area, and the
        // representable's sizeThatFits carries that down to the terminal.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .debugSize("hsplit")
        .navigationTitle(task.name)
        .navigationSubtitle(task.branch)
        .toolbar {
            ToolbarItem {
                Button {
                    Task {
                        await runtime.startMergeWalk(
                            for: task, orderedRepoIds: task.workspaces.map(\.repoId))
                    }
                } label: {
                    Label("Merge to base", systemImage: "arrow.triangle.merge")
                }
                .disabled(runtime.mergeWalk != nil)
            }
        }
    }

    /// The conflict pane takes over the right side during a paused merge walk
    /// for this task; otherwise the live review pane (spec §2.5).
    @ViewBuilder
    private var rightPane: some View {
        if let walk = runtime.mergeWalk, walk.task.id == task.id {
            ConflictPaneView(controller: walk)
        } else {
            ReviewPaneView(task: task)
        }
    }

    @ViewBuilder
    private var terminalPane: some View {
        if let controller = runtime.registry.controller(for: task.id), controller.isRunning {
            TerminalHostView(terminalView: controller.terminalView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// Hosts the registry-owned terminal NSView. The terminal is created once
/// and RETAINED in the registry; this wrapper only reparents it.
///
/// Sizing scar (2026-07-12, took two attempts): SwiftUI sizes an
/// NSViewRepresentable by `sizeThatFits`, whose DEFAULT answer derives from
/// the platform view's own fitting size — measured live at a constant 181pt
/// tall at every window size — and the enclosing flexible frame then CENTERS
/// that fixed box on both axes (the user-visible bug). The first fix
/// (container + autoresizing pin) only guaranteed terminal == container; the
/// container itself was still sized 181pt by the default negotiation, which
/// unit tests could not see because only a running app performs SwiftUI
/// layout. Fix: `sizeThatFits` adopts the proposal outright — a terminal is
/// a fill-everything view. Proof lives in the scripted geometry check
/// (Scripts/smoke-run.sh, LIGHTHOUSE_DEBUG_GEOMETRY=1).
struct TerminalHostView: NSViewRepresentable {
    let terminalView: LocalProcessTerminalView

    /// Pins `terminal` to fill `container`, tracking all future resizes.
    /// Static so the geometry contract is unit-testable without SwiftUI.
    @MainActor
    static func embed(_ terminal: LocalProcessTerminalView, in container: NSView) {
        terminal.removeFromSuperview()
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        // Adopt exactly what the pane proposes; unspecified dimensions keep
        // the current size rather than inventing an "ideal" one.
        let fallback = nsView.frame.size
        return CGSize(
            width: proposal.width ?? fallback.width,
            height: proposal.height ?? fallback.height)
    }

    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainerView()
        Self.embed(terminalView, in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Selecting another task and coming back builds a fresh container;
        // re-adopt the retained terminal if it isn't ours right now.
        if terminalView.superview !== container {
            Self.embed(terminalView, in: container)
        }
    }
}
