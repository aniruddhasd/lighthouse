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
    @Environment(\.motionEnabled) private var motionEnabled
    @Bindable var workbench: WorkbenchModel
    let task: TaskRecord

    /// Viewer header row height. Shared so the navigator overlay can start
    /// BELOW it (FocusView), keeping the header's Edit/Terminal controls
    /// visible instead of tucked behind the slid-in navigator.
    static let viewerHeaderHeight: CGFloat = 40

    var body: some View {
        let body = workbench.effectiveBody
        ZStack {
            // The terminal pane keeps its fill-everything structure untouched —
            // no scale/transform on it — so the retained-terminal invariant and
            // the geometry contract are unaffected by the motion pass.
            terminalPane
                .opacity(body == .terminal ? 1 : 0)
                .allowsHitTesting(body == .terminal)
            summaryPane
                .opacity(body == .summary ? 1 : 0)
                .allowsHitTesting(body == .summary)
            // pop (~.18s scale+opacity) on the file viewer's appearance
            // (handoff). Reduce-motion gated: the scale rests at 1 (no pop) and
            // the transition is instant.
            viewerPane
                .opacity(body == .viewer ? 1 : 0)
                .scaleEffect((motionEnabled && body != .viewer) ? 0.98 : 1)
                .allowsHitTesting(body == .viewer)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
        .animation(motionEnabled ? .easeInOut(duration: 0.18) : nil, value: body)
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

    // MARK: Summary pane (Phase-4 lean Summary — spec §5.3 minus the rich parts)

    @ViewBuilder
    private var summaryPane: some View {
        SummaryPaneView(workbench: workbench, task: task)
    }

    // MARK: Viewer pane (restyled header — handoff §2: path · read-only · ⌘J)

    @ViewBuilder
    private var viewerPane: some View {
        VStack(spacing: 0) {
            viewerHeader
            ZStack {
                // The viewer WKWebView is always present in the real app; it is
                // nil only under the unit-test harness (ContentViewerModel skips
                // WebKit there), which never renders this view.
                if let webView = workbench.viewer.webView {
                    DiffWebViewHost(webView: webView)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if !workbench.viewer.hasContent {
                    ContentUnavailableView(
                        "Nothing selected",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Pick a change, file, or commit in the navigator."))
                }
                // Edit mode: a native monospace editor over the read-only page.
                if workbench.isEditing {
                    fileEditor
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var fileEditor: some View {
        VStack(spacing: 0) {
            if workbench.editConflict {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(hex: 0xf0b45e))
                    Text("This file changed on disk since you started editing.")
                        .font(.caption)
                    Spacer()
                    Button("Overwrite") { Task { await workbench.overwriteEdits() } }
                    Button("Reload") { Task { await workbench.reloadForEditing() } }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(hex: 0x3a2f14))
            }
            TextEditor(text: $workbench.editText)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled(true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .background(Color(hex: 0x1e1e1e))
                .foregroundStyle(Color(hex: 0xd4d4d4))
        }
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
            if workbench.isEditing {
                Text("editing")
                    .font(LHFont.mono(11)).foregroundStyle(Color(hex: 0xf0b45e))
            } else if !workbench.canEditCurrentFile {
                Text("read-only")
                    .font(LHFont.mono(11)).foregroundStyle(Color(hex: 0x6f7890))
            }
            Spacer(minLength: 12)
            if let editError = workbench.editError {
                Text(editError).font(.caption2).foregroundStyle(.red).lineLimit(1)
            } else if let error = workbench.viewer.renderError {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1)
            }
            if workbench.isEditing {
                Button("Save") { Task { await workbench.saveEdits() } }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Cancel") { workbench.exitEditing() }
            } else if workbench.canEditCurrentFile {
                Button { Task { await workbench.beginEditing() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil")
                        Text("Edit").font(LHFont.button)
                    }
                    .foregroundStyle(Color(hex: 0xc8cfdd))
                }
                .buttonStyle(.plain)
                .help("Edit this file")
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
        .frame(height: Self.viewerHeaderHeight)
        .background(Color.black.opacity(0.28))
    }
}

/// The lean Summary (spec §5.3 minus the rich transcript-derived parts, which
/// are deferred to Phase 4b): a status line + "baked for {baked}", the untrusted
/// action line, and two stat cards (Changes / Context). Pure presentation over
/// the `TaskDigest` + live attention state. Centered, max-width 720, `--bg`,
/// fully token-driven. Every field degrades to a graceful blank — a task with no
/// transcript/recap yields the deterministic stat cards + (if present) the
/// action line, never fabricated numbers.
struct SummaryPaneView: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.theme) private var theme
    @Bindable var workbench: WorkbenchModel
    let task: TaskRecord

    private var live: Bool { runtime.model.isSessionLive(task.id) }
    private var digest: TaskDigest { runtime.digests.digest(for: task.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusLine
                actionLine
                if !task.workspaces.isEmpty { diffBaseSection }
                statCards
                // Phase 4b will add the rich transcript-derived Summary here:
                // "What the agent did" (✓ per steps[]) and the amber "Next step"
                // callout (next). Until then the deterministic cards + action
                // line above are the whole Summary; it degrades gracefully.
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
        .task(id: workbench.selectedWorkspaceIndex) { await workbench.loadBranchInfo() }
    }

    // MARK: Diff base — the branch the "vs base" diff compares against. This is
    // the ONLY place the base is chosen (the sidebar just names it). "The folder
    // (worktree, on whatever branch) vs a base branch you pick."
    private var diffBaseSection: some View {
        card(title: "Diff base") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Worktree on").font(LHFont.meta).foregroundStyle(theme.dim)
                    Text(workbench.worktreeBranch ?? "—")
                        .font(LHFont.mono(12)).foregroundStyle(theme.text)
                }
                HStack(spacing: 8) {
                    Text("Compare vs").font(LHFont.meta).foregroundStyle(theme.dim)
                    baseMenu
                }
                Text("“vs base” in the sidebar shows this branch. Uncommitted shows the working tree vs its own HEAD.")
                    .font(LHFont.metaFaint).foregroundStyle(theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var baseMenu: some View {
        Menu {
            ForEach(workbench.availableBranches, id: \.self) { branch in
                Button {
                    chooseBase(branch)
                } label: {
                    if branch == workbench.review.activeBase {
                        Label(branch, systemImage: "checkmark")
                    } else {
                        Text(branch)
                    }
                }
            }
            if let def = workbench.review.repoDefaultBase {
                Divider()
                Button(workbench.review.isBaseOverridden
                       ? "Use repo default (\(def))" : "Repo default (\(def))") {
                    chooseBase(nil)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 11))
                Text(workbench.review.activeBase ?? "base").font(LHFont.mono(12))
                if workbench.review.isBaseOverridden {
                    Circle().fill(theme.primary).frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(theme.text)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose the base branch this task's diff compares against")
    }

    private func chooseBase(_ base: String?) {
        workbench.setBase(base) { repoId, newBase in
            runtime.model.setWorkspaceBaseOverride(
                taskId: task.id, repoId: repoId, base: newBase)
        }
    }

    // Live dot + an editable free-text status. "Live" means a session is
    // running (the one honest signal); the status text is whatever the user
    // typed. Submitting the field persists it via AppModel.setStatus.
    private var statusLine: some View {
        HStack(spacing: 10) {
            StatusDot(live: live)
            Text(live ? "Session live" : "No session")
                .font(LHFont.ui(13, .medium))
                .foregroundStyle(live ? theme.text : theme.dim)
            Divider().frame(height: 16)
            StatusEditor(task: task)
        }
    }

    // The agent's last message — UNTRUSTED. Rendered as plain SwiftUI `Text`
    // (no markup interpretation) with a line limit. Omitted when absent.
    @ViewBuilder
    private var actionLine: some View {
        if let action = digest.action {
            Text(action)
                .font(LHFont.body)
                .foregroundStyle(theme.dim)
                .lineLimit(8)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statCards: some View {
        HStack(alignment: .top, spacing: 16) {
            changesCard
            contextCard
        }
    }

    // Changes card: +add/−del + files. Known-zero renders real `0`s; unknown
    // (nil diffStat) renders a dim "not computed" note, never fake zeros.
    private var changesCard: some View {
        card(title: "Changes") {
            if let stat = digest.diffStat {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text("+\(stat.added)")
                            .font(LHFont.ui(20, .semibold)).foregroundStyle(theme.addedTextChrome)
                        Text("\u{2212}\(stat.deleted)")
                            .font(LHFont.ui(20, .semibold)).foregroundStyle(theme.removedTextChrome)
                    }
                    Text("\(stat.filesChanged) file\(stat.filesChanged == 1 ? "" : "s") changed")
                        .font(LHFont.meta).foregroundStyle(theme.faint)
                }
            } else {
                Text("Not computed yet").font(LHFont.meta).foregroundStyle(theme.faint)
            }
        }
    }

    // Context card: ctx% + "model · window" when honest; else just the model;
    // else a dim placeholder. ctx% is an estimate (prefixed "~").
    private var contextCard: some View {
        card(title: "Context") {
            if let context = digest.context {
                VStack(alignment: .leading, spacing: 6) {
                    Text("~\(context.percent)%")
                        .font(LHFont.ui(20, .semibold)).foregroundStyle(theme.text)
                    Text(digest.model.map { "\($0) · \(Self.windowText(context.windowTokens))" }
                        ?? Self.windowText(context.windowTokens))
                        .font(LHFont.meta).foregroundStyle(theme.faint)
                }
            } else if let model = digest.model {
                ModelChip(model: model, font: LHFont.ui(14, .medium))
            } else {
                Text("No model recorded").font(LHFont.meta).foregroundStyle(theme.faint)
            }
        }
    }

    private func card<Content: View>(
        title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(LHFont.metaFaint).foregroundStyle(theme.faint)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .background(theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(theme.border, lineWidth: 1))
    }

    /// 1_000_000 → "1M", 200_000 → "200K", else the raw count.
    static func windowText(_ tokens: Int) -> String {
        if tokens % 1_000_000 == 0 { return "\(tokens / 1_000_000)M" }
        if tokens % 1_000 == 0 { return "\(tokens / 1_000)K" }
        return "\(tokens)"
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
                        AttentionBadge(live: runtime.model.isSessionLive(task.id))
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

/// Badges the agent tab with SESSION LIVENESS — a STATIC filled dot, green when
/// a session is live, muted otherwise. Never an animated/indeterminate badge:
/// it sits on the terminal tab bar the whole session, and a per-frame animation
/// forces an NSHostingView layout pass every display cycle, stealing the main
/// thread from SwiftTerm's (main-thread) drawing and lagging typing (profiled
/// 2026-07-27). The honest signal only — no agent-status inference.
struct AttentionBadge: View {
    let live: Bool

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(live ? .green : .secondary)
            .help(live ? "Session live" : "No live session")
    }
}

/// Inline editor for a task's free-text status. Seeds from the task, commits on
/// submit or focus-loss via AppModel.setStatus — the only way status changes now.
struct StatusEditor: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.theme) private var theme
    let task: TaskRecord
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Set a status…", text: $draft)
            .textFieldStyle(.plain)
            .font(LHFont.ui(13, .regular))
            .foregroundStyle(theme.text)
            .focused($focused)
            .onAppear { draft = task.status }
            .onChange(of: task.id) { draft = task.status }
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() { runtime.model.setStatus(draft, for: task.id) }
}
