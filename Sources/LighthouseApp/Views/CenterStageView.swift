import SwiftUI
import SwiftTerm
import LighthouseAppCore
import LighthouseTaskEngine

/// The Focus center BODY (spec §5.2 item 3): exactly one of Terminal / Summary /
/// File-viewer, per the §3.4 precedence. All THREE panes stay MOUNTED in a
/// ZStack and are opacity/hit-test toggled — never torn down — so the terminal's
/// registry-owned NSView survives every mode swap AND the viewer overlay AND the
/// navigator toggle (the retained-terminal scar; the FOCUS gate asserts it).
///
/// ZStack, NOT Group: a Group is transparent, so a branch switch would re-fire
/// onAppear and recreate the models (the REVIEWPANE loop scar). The terminal
/// pane keeps the fill-everything host structure the sizing scar was fixed
/// against, so the geometry contract still holds; the summary/viewer panes carry
/// their own chrome, which never affects the measured terminal.
struct FocusBodyView: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.theme) private var theme
    @Bindable var workbench: WorkbenchModel
    let task: TaskRecord

    var body: some View {
        let body = workbench.effectiveBody
        ZStack {
            terminalPane
                .opacity(body == .terminal ? 1 : 0)
                .allowsHitTesting(body == .terminal)
            summaryPane
                .opacity(body == .summary ? 1 : 0)
                .allowsHitTesting(body == .summary)
            viewerPane
                .opacity(body == .viewer ? 1 : 0)
                .allowsHitTesting(body == .viewer)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
        .animation(.easeInOut(duration: 0.18), value: body)
    }

    // MARK: Terminal pane (the fill-everything host — the sizing-scar structure)

    @ViewBuilder
    private var terminalPane: some View {
        let tabs = runtime.tabs[task.id] ?? []
        terminalBody(tabs: tabs)
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

    // MARK: Summary pane (Phase-4 feature — HONEST placeholder here, no data)

    @ViewBuilder
    private var summaryPane: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(theme.faint)
            Text("The task summary will appear here.")
                .font(LHFont.summaryHead)
                .foregroundStyle(theme.dim)
            Text("A digest of what the agent did lands in a later phase.")
                .font(LHFont.body)
                .foregroundStyle(theme.faint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
    }

    // MARK: Viewer pane (restyled header — handoff §2: path · read-only · ⌘J)

    @ViewBuilder
    private var viewerPane: some View {
        VStack(spacing: 0) {
            viewerHeader
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

    private var viewerHeader: some View {
        // Dark header over the dark viewer body (handoff: viewer stays dark in
        // both themes). +add/−del diffstat is a Phase-4 field → omitted (no
        // fabricated numbers). The A/M/D badge is only known for the Changes
        // tab, not for Files/History, so it is omitted rather than faked.
        HStack(spacing: 10) {
            if let title = workbench.viewer.hasContent ? workbench.viewerTitle : nil {
                Text(title)
                    .font(LHFont.mono(12))
                    .foregroundStyle(Color(hex: 0xc8cfdd))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("read-only")
                .font(LHFont.mono(11))
                .foregroundStyle(Color(hex: 0x6f7890))
            Spacer(minLength: 12)
            if let error = workbench.viewer.renderError {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1)
            }
            Button { workbench.showTerminal() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                    Text("Terminal").font(LHFont.button)
                    Keycap(text: "⌘J")
                }
                .foregroundStyle(Color(hex: 0xc8cfdd))
            }
            .buttonStyle(.plain)
            .help("Back to the running terminal (⌘J)")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color.black.opacity(0.28))
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
