import SwiftUI
import SwiftTerm
import LighthouseAppCore
import LighthouseTaskEngine

/// The center of the detail area: the terminal by default, swapping to the
/// content viewer when a navigator item is selected, and back on ⌘J / the
/// "Show Terminal" control.
///
/// The swap is opacity, never teardown: BOTH stages stay mounted in a ZStack so
/// the terminal's registry-owned NSView is never detached or recreated across a
/// swap (the same retained-view pattern the terminal tabs already use, and that
/// the GEOMETRY gate proves). The terminal stage keeps the exact structure the
/// sizing scar was fixed against (tab bar + divider + fill-everything body), so
/// the geometry contract still holds; the viewer stage carries its own header,
/// which never affects the measured terminal.
struct CenterStageView: View {
    @Environment(AppRuntime.self) private var runtime
    @Bindable var workbench: WorkbenchModel
    let task: TaskRecord

    var body: some View {
        ZStack {
            terminalStage
                .opacity(workbench.centerMode == .terminal ? 1 : 0)
                .allowsHitTesting(workbench.centerMode == .terminal)
            viewerStage
                .opacity(workbench.centerMode == .viewer ? 1 : 0)
                .allowsHitTesting(workbench.centerMode == .viewer)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: workbench.centerMode)
    }

    // MARK: Viewer stage

    @ViewBuilder
    private var viewerStage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    workbench.showTerminal()
                } label: {
                    Label("Show Terminal", systemImage: "terminal")
                }
                .help("Back to the running terminal (⌘J)")
                Spacer()
                if let error = workbench.viewer.renderError {
                    Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            ZStack {
                DiffWebViewHost(webView: workbench.viewer.webView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !workbench.viewer.hasContent {
                    ContentUnavailableView(
                        "Nothing selected",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Pick a change, file, or commit in the navigator."))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Terminal stage (structure unchanged from the pre-Phase-B layout)

    @ViewBuilder
    private var terminalStage: some View {
        let tabs = runtime.tabs[task.id] ?? []
        VStack(spacing: 0) {
            if !tabs.isEmpty {
                TerminalTabBar(task: task)
                Divider()
            }
            terminalBody(tabs: tabs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func terminalBody(tabs: [TerminalTab]) -> some View {
        let focused = runtime.focusedTab[task.id]
        if let focused,
           let controller = runtime.registry.controller(taskId: task.id, tabId: focused),
           controller.isRunning {
            // Keep every tab's NSView mounted (retained instances), showing
            // only the focused one — a hidden tab keeps running unfocused.
            ZStack {
                ForEach(tabs) { tab in
                    if let c = runtime.registry.controller(taskId: task.id, tabId: tab.id) {
                        TerminalHostView(terminalView: c.terminalView)
                            .opacity(tab.id == focused ? 1 : 0)
                            .allowsHitTesting(tab.id == focused)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            noSessionView
        }
    }

    @ViewBuilder
    private var noSessionView: some View {
        VStack(spacing: 12) {
            if runtime.model.attentionState(of: task.id) == .dirty {
                Label("Session ended — workspace may hold unfinished work",
                      systemImage: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
            }
            if runtime.model.canResume(task) {
                Button { runtime.resumeSession(for: task) } label: {
                    Label("Resume session", systemImage: "play.circle")
                }
                .controlSize(.large)
                Text("Continues the stored conversation (claude --resume) in a shell tab. If its history is gone, the terminal shows the error and your shell stays.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No session for this task.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Simple tab bar above the terminal pane. Cmd+T opens a shell tab (Ctrl+T is
/// a control byte TUIs intercept — hence Cmd+T); Cmd+W closes the focused
/// shell tab. The agent tab is badged and not closable from here.
struct TerminalTabBar: View {
    @Environment(AppRuntime.self) private var runtime
    let task: TaskRecord

    var body: some View {
        let tabs = runtime.tabs[task.id] ?? []
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let focused = runtime.focusedTab[task.id] == tab.id
                HStack(spacing: 4) {
                    if tab.isAgent {
                        AttentionBadge(state: runtime.model.attentionState(of: task.id))
                    }
                    Text(tab.title).font(.caption)
                    if !tab.isAgent {
                        Button {
                            runtime.closeTab(taskId: task.id, tabId: tab.id)
                        } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(focused ? Color.accentColor.opacity(0.25) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onTapGesture { runtime.focusedTab[task.id] = tab.id }
            }
            Button { runtime.openShellTab(for: task) } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .help("New shell tab (⌘T)")
            Spacer()
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
    }
}
