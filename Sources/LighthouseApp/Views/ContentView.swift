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
        // Reading `.resolved` here registers observation on the ThemeController,
        // so a flip re-runs this body and re-injects the new tokens app-wide.
        let theme = runtime.themeController.resolved
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.bg)
            }
        }
        // The custom titlebar installs itself on the host window from here; a
        // zero-size background view, so no layout is affected.
        .background(TitlebarConfigurator(controller: runtime.themeController, theme: theme))
        .environment(\.theme, theme)
        // THE COHERENCE FIX (2026-07-15): pin the window's appearance to the
        // theme's — Beacon dark, Native light — so Native's NSColor SEMANTIC
        // tokens (bg/panel/text/…) resolve LIGHT even under a Dark system,
        // matching its literal-light-hex tokens instead of splitting half-light.
        // This must go through SwiftUI (`.preferredColorScheme`), not a manual
        // `window.appearance` set, which SwiftUI clobbers on its next pass. It
        // cascades to the SwiftUI `Color(nsColor:)` tokens, the native controls
        // (segmented switcher, List selection), and the titlebar accessories.
        // Terminal/viewer keep their own dark colors (unaffected).
        .preferredColorScheme(theme.colorScheme)
        .sheet(isPresented: $showCreateTask) { CreateTaskSheet() }
        .sheet(isPresented: $showRegisterRepo) { RegisterRepoSheet() }
        .sheet(item: $taskPendingRemoval) { task in RemoveTaskSheet(task: task) }
        .sheet(isPresented: Binding(
            get: { runtime.setupPresented },
            set: { runtime.setupPresented = $0 })) { SetupView() }
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

/// Detail layout: CENTER STAGE (terminal ⇄ content viewer) on the left, the
/// hideable NAVIGATOR on the right; the conflict pane takes over the whole
/// detail area during a paused merge walk (spec §2.5). A single per-task
/// `WorkbenchModel` owns the live-diff watcher, the center viewer, and the
/// two view-modes; its lifecycle IS the watcher lifecycle (see the contract
/// on ReviewPaneModel) — created on appear, stopped on background, restarted
/// on foreground, torn down on task switch (identity is `.id(task.id)`).
struct TaskDetailView: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.theme) private var theme
    let task: TaskRecord
    @State private var workbench: WorkbenchModel?

    var body: some View {
        // ZStack, NOT Group: Group is transparent, so modifiers attach to each
        // branch — a branch switch (progress → workbench, or merge-walk on/off)
        // would re-fire onAppear and recreate the model (the loop the REVIEWPANE
        // gate caught, 2026-07-13). A real container fires appear once; the
        // nil-guard is belt-and-braces.
        ZStack {
            if let walk = runtime.mergeWalk, walk.task.id == task.id {
                ConflictPaneView(controller: walk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let workbench {
                workbenchLayout(workbench)
            } else {
                ProgressView()
            }
        }
        // The detail column collapses to its children's IDEAL height unless the
        // split and both children are forced to expand (the 2026-07-12 sizing
        // scar); the representable's sizeThatFits then carries the full area
        // down to the terminal.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Chrome behind the detail area flips with the theme; the terminal and
        // the WKWebView viewer paint their own dark surfaces over this and are
        // deliberately NOT themed (handoff: they stay dark in both themes).
        .background(theme.bg)
        .debugSize("detail")
        .navigationTitle(task.name)
        .navigationSubtitle(task.branch)
        .toolbar { toolbarContent }
        .onAppear {
            guard workbench == nil else { return }
            ReviewDebug.stage("appear task=\(task.name)")
            let model = WorkbenchModel(
                task: task, repos: runtime.model.repos, git: runtime.git)
            workbench = model
            model.start()
        }
        .onDisappear {
            workbench?.stop()
            workbench = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { workbench?.start() } else { workbench?.stop() }
        }
    }

    @ViewBuilder
    private func workbenchLayout(_ workbench: WorkbenchModel) -> some View {
        @Bindable var workbench = workbench
        HSplitView {
            CenterStageView(workbench: workbench, task: task)
                // Never ideal-size: expand so the split adopts the full detail
                // area (sizing scar). Min > 420 keeps the geometry contract.
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                .debugSize("centerStage")
            if workbench.navigatorVisible {
                NavigatorView(workbench: workbench)
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 460, maxHeight: .infinity)
                    .debugSize("navigator")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .debugSize("hsplit")
        .background {
            // Keystrokes, each mirrored by a visible toolbar control:
            //   ⌘J        swap the center stage (terminal ⇄ viewer)
            //   ⌥⌘S       hide/show the navigator (⌃⌘S is the left sidebar)
            Button("", action: { workbench.toggleCenter() })
                .keyboardShortcut("j", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            Button("", action: { workbench.navigatorVisible.toggle() })
                .keyboardShortcut("s", modifiers: [.command, .option])
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let workbench {
            ToolbarItem {
                Button { workbench.toggleCenter() } label: {
                    Label(
                        workbench.centerMode == .terminal ? "Show Viewer" : "Show Terminal",
                        systemImage: workbench.centerMode == .terminal ? "doc.text" : "terminal")
                }
                .help("Swap the center between the terminal and the content viewer (⌘J)")
            }
            ToolbarItem {
                Button { workbench.navigatorVisible.toggle() } label: {
                    Label("Toggle Navigator", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the navigator (⌥⌘S)")
            }
        }
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
