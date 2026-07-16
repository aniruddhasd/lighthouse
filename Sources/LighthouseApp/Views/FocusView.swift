import AppKit
import SwiftUI
import LighthouseAppCore
import LighthouseTaskEngine

// MARK: - FOCUS debug (the runtime gate hooks)

/// LIGHTHOUSE_DEBUG_FOCUS=1: the reshaped Focus (beacon rail, task header,
/// footer, navigator overlay, three-pane body) renders in the real app but its
/// layout + the retained-terminal invariant are not headlessly testable (the
/// scar). Views emit render facts (rail dot count, header/footer present,
/// navigator mount) and their laid-out sizes; the runtime driver in AppRuntime
/// drives the interactions (open, mode swaps, nav toggle) and asserts the §3.4
/// rules + terminal survival on the LIVE mounted workbench.
enum FocusDebug {
    static let enabled = ProcessInfo.processInfo.environment["LIGHTHOUSE_DEBUG_FOCUS"] == "1"

    /// Whether the navigator overlay is currently MOUNTED — set by its
    /// onAppear/onDisappear so the driver can prove the toggle mounts/unmounts a
    /// real overlay (not an always-present, always-hidden view). Main-thread.
    nonisolated(unsafe) static var navigatorMounted = false

    /// The workbench of the currently-mounted Focus task, so the driver can
    /// drive mode swaps / nav toggles on the SAME model the view renders (the
    /// only way to prove the terminal survives a real view-level swap). Written
    /// + read on the main actor only.
    nonisolated(unsafe) static weak var currentWorkbench: WorkbenchModel?

    static func emit(_ message: String) {
        guard enabled else { return }
        FileHandle.standardOutput.write(Data("FOCUS-STAGE \(message)\n".utf8))
    }
}

/// SwiftUI size probe for the FOCUS gate: logs the laid-out size of the view it
/// is attached to, labeled, on every change. Debug mode only; otherwise inert.
private struct FocusSizeModifier: ViewModifier {
    let label: String
    func body(content: Content) -> some View {
        if FocusDebug.enabled {
            content.background(GeometryReader { geo in
                Color.clear
                    .onAppear { report(geo.size) }
                    .onChange(of: geo.size) { _, new in report(new) }
            })
        } else {
            content
        }
    }
    private func report(_ size: CGSize) {
        FocusDebug.emit(String(format: "%@-size=%.0fx%.0f", label, size.width, size.height))
    }
}

extension View {
    func focusDebugSize(_ label: String) -> some View { modifier(FocusSizeModifier(label: label)) }
}

// MARK: - Focus (the reshaped single-task command deck, spec §5.2)

/// Focus: horizontal — **beacon rail (60px)** · **center column (flex)** — with
/// the navigator as a 340px slide-in OVERLAY on the center column's right edge
/// (spec §A). The old NavigationSplitView shell + its detail toolbar are retired
/// (which also removes the toolbar-KVO-under-sheet fragility from Phase 2). The
/// per-task teardown identity (`.id(task.id)`) and the WorkbenchModel lifecycle
/// live on `FocusCenter`; the rail belongs to the shell (it shows every task).
struct FocusView: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.theme) private var theme
    @Binding var showCreateTask: Bool

    var body: some View {
        HStack(spacing: 0) {
            BeaconRail(showCreateTask: $showCreateTask)
                .focusDebugSize("beaconRail")
                .debugSize("beaconRail")
            Group {
                if let taskId = runtime.selectedTaskId,
                   let task = runtime.model.tasks.first(where: { $0.id == taskId }) {
                    FocusCenter(task: task)
                        .id(task.id)
                } else {
                    ContentUnavailableView(
                        "No task selected",
                        systemImage: "rectangle.on.rectangle",
                        description: Text("Pick a task from the rail, or press ⌘K."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.bg)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
    }
}

// MARK: - Beacon rail (60px, spec §B)

/// The 60px ambient rail: Harbor button → `backToHarbor`; a scroll of task dots
/// (one per `model.tasks`, tap → `open(id)`); New-task (+) at the bottom.
/// Replaces the retired sidebar's task list. Token-driven throughout.
struct BeaconRail: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.theme) private var theme
    @Binding var showCreateTask: Bool

    var body: some View {
        VStack(spacing: 10) {
            harborButton
            Rectangle()
                .fill(theme.border)
                .frame(width: 24, height: 1)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(runtime.model.tasks) { task in
                        railDot(task)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            newTaskButton
        }
        .padding(.vertical, 12)
        .frame(width: Theme.Metric.rail)
        .frame(maxHeight: .infinity)
        .background(theme.chrome)
        .overlay(alignment: .trailing) {
            Rectangle().fill(theme.borderSoft).frame(width: 1)
        }
        .onAppear { FocusDebug.emit("rendered-dots=\(runtime.model.tasks.count)") }
    }

    private var harborButton: some View {
        Button { runtime.backToHarbor() } label: {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.dim)
                .frame(width: 40, height: 40)
                .background(theme.panel3, in: RoundedRectangle(cornerRadius: Theme.Radius.rail))
        }
        .buttonStyle(.plain)
        .help("Back to Harbor")
    }

    private func railDot(_ task: TaskRecord) -> some View {
        let selected = runtime.selectedTaskId == task.id
        return Button { runtime.open(task.id) } label: {
            StatusDot(
                state: runtime.model.attentionState(of: task.id),
                size: 11,
                glow: runtime.model.attentionState(of: task.id) == .needsInput)
                .frame(width: 40, height: 40)
                .background(
                    selected ? theme.panel3 : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.rail))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.rail)
                        .strokeBorder(selected ? theme.border2 : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(task.name)
        .taskContextMenu(for: task)
    }

    private var newTaskButton: some View {
        Button { showCreateTask = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.dim)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.rail)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(theme.border))
        }
        .buttonStyle(.plain)
        .disabled(runtime.model.repos.isEmpty)
        .opacity(runtime.model.repos.isEmpty ? 0.4 : 1)
        .help(runtime.model.repos.isEmpty ? "Register a repo first" : "New task")
    }
}

// MARK: - Center column (owns the per-task workbench, spec §C)

/// The Focus center column: task header (52) · shell-tabs bar · body · footer
/// (30), with the navigator as a trailing slide-in overlay. Owns the single
/// per-task `WorkbenchModel` — its lifecycle IS the live-diff watcher lifecycle
/// (created on appear, stopped on background, restarted on foreground, torn down
/// on task switch via the enclosing `.id(task.id)`). The conflict pane takes
/// over the whole column during a paused merge walk.
struct FocusCenter: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.theme) private var theme
    @Environment(\.motionEnabled) private var motionEnabled
    let task: TaskRecord
    @State private var workbench: WorkbenchModel?

    var body: some View {
        // ZStack, NOT Group: a Group would re-fire onAppear on a branch switch
        // (merge-walk on/off) and recreate the model — the REVIEWPANE loop scar.
        ZStack {
            if let walk = runtime.mergeWalk, walk.task.id == task.id {
                ConflictPaneView(controller: walk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let workbench {
                column(workbench)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
        .onAppear {
            guard workbench == nil else { return }
            ReviewDebug.stage("appear task=\(task.name)")
            let model = WorkbenchModel(
                task: task, repos: runtime.model.repos, git: runtime.git)
            workbench = model
            FocusDebug.currentWorkbench = model
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
    private func column(_ workbench: WorkbenchModel) -> some View {
        @Bindable var workbench = workbench
        VStack(spacing: 0) {
            FocusTaskHeader(workbench: workbench, task: task)
            if !(runtime.tabs[task.id] ?? []).isEmpty {
                TerminalTabBar(task: task)
                    .background(theme.chrome)
                Rectangle().fill(theme.borderSoft).frame(height: 1)
            }
            FocusBodyView(workbench: workbench, task: task)
                // Never ideal-size: fill so the terminal host fills the body
                // (the sizing-collapse scar). The GEOMETRY/FOCUS gates prove it.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusDebugSize("focusBody")
                .debugSize("focusBody")
            FocusFooter(task: task)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusDebugSize("centerColumn")
        .debugSize("centerColumn")
        // The navigator is an OVERLAY (spec §E), never a split column: it floats
        // over the right edge; the terminal stays full-width beneath.
        .overlay(alignment: .trailing) {
            if workbench.navigatorVisible {
                NavigatorOverlay(workbench: workbench)
                    .transition(.move(edge: .trailing))
            }
        }
        // slidein (~.2s, keep Phase 3's); reduce-motion makes it instant (nil
        // animation → the move transition applies with no interpolation).
        .animation(motionEnabled ? .easeInOut(duration: 0.2) : nil, value: workbench.navigatorVisible)
        // Keystrokes, each mirrored by a visible control (spec §F):
        //   ⌘J  close the file viewer (Focus only) → return to the mode
        //   ⌘\  toggle the navigator overlay (replaces the old ⌥⌘S)
        .background {
            Button("", action: { workbench.showTerminal() })
                .keyboardShortcut("j", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            Button("", action: { workbench.navigatorVisible.toggle() })
                .keyboardShortcut("\\", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }
}

// MARK: - Task header (52px, spec §C.1)

/// Replaces the retired detail toolbar: status · title/meta · Terminal/Summary
/// segmented · context meter (honest only) · navigator toggle (◨) · Merge to
/// base. The Merge button is promoted (filled green/idle) ONLY when the task is
/// done; the context meter renders ONLY when an honest estimate exists (Phase 4
/// — omitted, not faked, otherwise the header stays as Phase 3).
struct FocusTaskHeader: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.theme) private var theme
    @Bindable var workbench: WorkbenchModel
    let task: TaskRecord

    private var state: TaskAttentionState { runtime.model.attentionState(of: task.id) }
    private var digest: TaskDigest { runtime.digests.digest(for: task.id) }

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(state: state, glow: state == .needsInput)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.name)
                    .font(LHFont.taskHeader)
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text(metaLine)
                    .font(LHFont.mono(10.5))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            modeToggle
            if let context = digest.context {
                ContextMeter(context: context)
            }
            navigatorToggle
            mergeButton
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.Metric.headerRow)
        .background(theme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.borderSoft).frame(height: 1)
        }
        .onAppear { FocusDebug.emit("header-present=true") }
    }

    private var modeToggle: some View {
        Picker("Body", selection: Binding(
            get: { workbench.bodyState.mode },
            set: { workbench.setBodyMode($0) })) {
            Text("Terminal").tag(BodyMode.terminal)
            Text("Summary").tag(BodyMode.summary)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Switch the center body between the terminal and the task summary")
    }

    private var navigatorToggle: some View {
        Button { workbench.navigatorVisible.toggle() } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(workbench.navigatorVisible ? theme.primary : theme.dim)
                .frame(width: 34, height: 30)
                .background(
                    workbench.navigatorVisible ? theme.border2 : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.tab))
        }
        .buttonStyle(.plain)
        .help("Show or hide the navigator (⌘\\)")
    }

    private var mergeButton: some View {
        // Promoted (filled idle/green) only when the task is done; otherwise a
        // neutral secondary button. Wiring is unchanged from the retired toolbar.
        let promoted = state == .done
        return Button {
            Task {
                await runtime.startMergeWalk(
                    for: task, orderedRepoIds: task.workspaces.map(\.repoId))
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.merge")
                Text("Merge to base").font(LHFont.button)
            }
            .foregroundStyle(promoted ? theme.primaryText : theme.text)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                promoted ? theme.idle : theme.panel3,
                in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
        }
        .buttonStyle(.plain)
        .disabled(runtime.mergeWalk != nil)
        .opacity(runtime.mergeWalk != nil ? 0.5 : 1)
        .help("Merge this task's worktree back to base")
    }

    private var metaLine: String {
        let repoNames = task.workspaces.compactMap { ws in
            runtime.model.repos.first { $0.id == ws.repoId }?.pathURL.lastPathComponent
        }
        let branchShort = task.branch.split(separator: "/").last.map(String.init) ?? task.branch
        let repoPart = repoNames.isEmpty ? "" : repoNames.joined(separator: ", ") + " · "
        return repoPart + branchShort
    }
}

// MARK: - Footer status line (30px, spec §C.4 — honest fields ONLY)

/// The Focus footer: account · repo(s) · model · ctx% (honest only) · "N agents"
/// (a REAL count of this task's running controllers). Model + ctx% render only
/// when honestly derived (Phase 4); accept-edits is still OMITTED (no honest
/// source). A sparse honest footer is correct; nothing invented.
struct FocusFooter: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.theme) private var theme
    let task: TaskRecord

    private var digest: TaskDigest { runtime.digests.digest(for: task.id) }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Circle().fill(Theme.beaconAmber).frame(width: 6, height: 6)
                Text(TitlebarAccount.label)
            }
            if !repoNames.isEmpty {
                Text("⌥ \(repoNames)")
            }
            if let model = digest.model {
                ModelChip(model: model)
            }
            if let context = digest.context {
                ContextMeter(context: context)
            }
            Spacer(minLength: 12)
            Text("\(agentCount) agent\(agentCount == 1 ? "" : "s")")
        }
        .font(LHFont.mono(11))
        .foregroundStyle(theme.faint)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: Theme.Metric.footer)
        .background(theme.chrome)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.borderSoft).frame(height: 1)
        }
        .onAppear { FocusDebug.emit("footer-present=true") }
    }

    private var agentCount: Int { runtime.registry.runningCount(taskId: task.id) }

    private var repoNames: String {
        task.workspaces.compactMap { ws in
            runtime.model.repos.first { $0.id == ws.repoId }?.pathURL.lastPathComponent
        }.joined(separator: ", ")
    }
}

// MARK: - Navigator overlay (340px slide-in, spec §E)

/// The navigator converted from an HSplit pane to a 340px slide-in OVERLAY
/// (spec §E). Reuses ALL of `NavigatorView`'s internals (repo picker, segmented
/// Changes/Files/History, trees, ⌘R refresh, selection → `workbench.select*`);
/// only the container/chrome changes. A close × mirrors the ◨ toggle / ⌘\.
struct NavigatorOverlay: View {
    @Environment(\.theme) private var theme
    @Bindable var workbench: WorkbenchModel

    var body: some View {
        NavigatorView(workbench: workbench)
            .frame(width: Theme.Metric.navigator)
            .frame(maxHeight: .infinity)
            .background(theme.chrome)
            .overlay(alignment: .leading) {
                Rectangle().fill(theme.borderSoft).frame(width: 1)
            }
            .overlay(alignment: .topTrailing) {
                Button { workbench.navigatorVisible = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.dim)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .help("Close the navigator (⌘\\)")
            }
            .focusDebugSize("navigatorOverlay")
            .onAppear {
                FocusDebug.navigatorMounted = true
                FocusDebug.emit("navigator-appeared=true")
            }
            .onDisappear {
                FocusDebug.navigatorMounted = false
                FocusDebug.emit("navigator-disappeared=true")
            }
    }
}
