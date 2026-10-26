import SwiftUI
import LighthouseAppCore
import LighthouseTaskEngine

/// LIGHTHOUSE_DEBUG_HARBOR=1: the SwiftUI Harbor grid renders in the real app
/// but its layout is not headlessly testable (the documented scar). The view
/// emits `HARBOR-STAGE rendered-cards=<n>` from its own render so the gate can
/// prove the grid rendered the expected card count (mirroring the GEOMETRY
/// gate's debugSize probes); the runtime driver in AppRuntime emits the
/// sort/filter/flip/terminal-alive stages.
enum HarborDebug {
    static let enabled = ProcessInfo.processInfo.environment["LIGHTHOUSE_DEBUG_HARBOR"] == "1"
    static func emit(_ message: String) {
        guard enabled else { return }
        FileHandle.standardOutput.write(Data("HARBOR-STAGE \(message)\n".utf8))
    }
}

extension Theme {
    /// Session-liveness → dot color. Green (`idle` token) when a session is
    /// live for the task, muted (`dim`) when not. Replaces the old
    /// attention-state palette — the only automatic signal now is "is a session
    /// live", which Lighthouse observes directly.
    func liveAccent(_ live: Bool) -> Color { live ? idle : dim }
}

/// A small dot indicating SESSION LIVENESS: the state accent green when a live
/// session exists for the task, muted otherwise. When live it CAN pulse, but
/// only where `pulses` is opted in (harbor rows) — a per-frame animation is
/// kept off the terminal screens (profiled 2026-07-27). The ring is an OVERLAY
/// (never changes the dot's frame), so a pulsing dot never reflows the row.
struct StatusDot: View {
    @Environment(\.theme) private var theme
    @Environment(\.motionEnabled) private var motionEnabled
    let live: Bool
    var size: CGFloat = 9
    var pulses: Bool = false
    @State private var pulsing = false

    var body: some View {
        let accent = theme.liveAccent(live)
        Circle()
            .fill(accent)
            .frame(width: size, height: size)
            .overlay {
                // A live session can pulse, only when motion is on and the caller
                // opted in: the ring view is otherwise absent (not merely paused),
                // so no infinite animation is ever mounted.
                if live && motionEnabled && pulses {
                    Circle()
                        .stroke(accent, lineWidth: 1.5)
                        .scaleEffect(pulsing ? 2.6 : 1)
                        .opacity(pulsing ? 0 : 0.7)
                        .animation(
                            .easeOut(duration: 1.6).repeatForever(autoreverses: false),
                            value: pulsing)
                        .onAppear { pulsing = true }
                }
            }
    }
}

/// A pill showing the user's free-text status. Renders NOTHING when the status
/// is empty (unset) — no fabricated "Idle"/"Working"; the card just omits it.
struct StatusPill: View {
    @Environment(\.theme) private var theme
    let status: String

    var body: some View {
        if !status.isEmpty {
            Text(status)
                .font(LHFont.pill)
                .foregroundStyle(theme.dim)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(theme.panel2,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.pill))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.pill)
                    .strokeBorder(theme.border2, lineWidth: 1))
        }
    }
}

/// A small keycap (⌘K, esc) — mono, `panel3` bg, radius 6 (handoff keycaps).
struct Keycap: View {
    @Environment(\.theme) private var theme
    let text: String
    var body: some View {
        Text(text)
            .font(LHFont.keycap)
            .foregroundStyle(theme.dim)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(theme.panel3, in: RoundedRectangle(cornerRadius: Theme.Radius.keycap))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.keycap)
                .strokeBorder(theme.border2, lineWidth: 1))
    }
}

/// Harbor — the fleet overview / default landing view (handoff §1). Full-window
/// content, NOT inside a NavigationSplitView. Token-driven throughout.
struct HarborView: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.theme) private var theme
    @Binding var showCreateTask: Bool

    /// Keyboard-focus targets Tab cycles through on Harbor. We hold key focus on
    /// the whole grid (a focusable container) and track the target ourselves,
    /// rather than wiring @FocusState into every button — SwiftUI's per-control
    /// Tab traversal is unreliable for a mixed grid + chrome layout.
    enum Field: Hashable { case tasks, reposHeader, addRepo, newTask, scratch, search }
    @State private var field: Field = .tasks
    @FocusState private var hasKeyFocus: Bool

    /// The targets present right now, in Tab order: the task grid, then the repos
    /// chevron + Add-repo, then New-task / Scratch / Search.
    private var tabOrder: [Field] {
        var order: [Field] = []
        if !runtime.model.tasks.isEmpty { order.append(.tasks) }
        if !runtime.model.repos.isEmpty { order += [.reposHeader, .addRepo] }
        order += [.newTask, .scratch, .search]
        return order
    }

    var body: some View {
        @Bindable var runtime = runtime
        let cards = runtime.visibleHarborTasks
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if runtime.model.tasks.isEmpty {
                        emptyState
                    } else {
                        taskGrid(cards)
                        reposSection
                    }
                }
                .padding(.horizontal, Theme.Metric.gutter)
                .padding(.bottom, 34)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The base bg + the ambient beam (when the pref AND motion allow it).
        // A background layer: never affects the grid layout, never intercepts
        // clicks (the beam is allowsHitTesting(false)).
        .background(HarborBackground())
        // Hold key focus on the whole Harbor so Tab / arrows / Return reach the
        // handler below; draw our own per-field ring, not the container's.
        .focusable()
        .focused($hasKeyFocus)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { handleKey($0) }
        .onAppear {
            hasKeyFocus = true
            if !tabOrder.contains(field) { field = tabOrder.first ?? .newTask }
            HarborDebug.emit("rendered-cards=\(cards.count)")
        }
    }

    // MARK: Keyboard focus traversal

    /// Tab / Shift-Tab cycle fields; arrows browse the grid when it's focused,
    /// else step fields; Return activates the focused field.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .tab:
            cycleField(press.modifiers.contains(.shift) ? -1 : 1); return .handled
        case .return:
            activateField(); return .handled
        case .leftArrow, .upArrow:
            if field == .tasks { runtime.moveHarborHighlight(-1) } else { cycleField(-1) }
            return .handled
        case .rightArrow, .downArrow:
            if field == .tasks { runtime.moveHarborHighlight(1) } else { cycleField(1) }
            return .handled
        default:
            return .ignored
        }
    }

    private func cycleField(_ delta: Int) {
        let order = tabOrder
        guard !order.isEmpty else { return }
        let i = order.firstIndex(of: field) ?? (delta > 0 ? -1 : 0)
        field = order[((i + delta) % order.count + order.count) % order.count]
        // Entering the grid seeds the card highlight; leaving it clears it.
        if field == .tasks {
            if runtime.harborHighlightedTaskId == nil { runtime.moveHarborHighlight(1) }
        } else {
            runtime.harborHighlightedTaskId = nil
        }
    }

    private func activateField() {
        switch field {
        case .tasks: runtime.openHarborHighlight()
        case .reposHeader: runtime.model.setReposCollapsed(!runtime.model.reposCollapsed)
        case .addRepo: runtime.registerRepoPresented = true
        case .newTask: showCreateTask = true
        case .scratch: runtime.promptAndOpenScratchTerminal()
        case .search: runtime.switcherPresented = true
        }
    }

    /// A ring on whichever chrome control is the current Tab target. `radius`
    /// matches the control's own corner radius so the ring hugs it.
    @ViewBuilder private func focusRing(_ target: Field, radius: CGFloat = Theme.Radius.search) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .strokeBorder(theme.primary, lineWidth: field == target ? 2 : 0)
            .allowsHitTesting(false)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Harbor")
                    .font(LHFont.harborTitle)
                    .foregroundStyle(theme.text)
                Text(subtitle)
                    .font(LHFont.body)
                    .foregroundStyle(theme.dim)
            }
            Spacer()
            if runtime.hiddenTaskCount > 0 { hiddenToggle }
            supervisorButton
            searchButton
            scratchTerminalButton
            newTaskButton
        }
        .padding(.leading, Theme.Metric.gutter)
        .padding(.trailing, Theme.Metric.gutter)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    /// Reveal / re-hide the hidden tasks. Only shown when some exist.
    private var hiddenToggle: some View {
        Button { runtime.showHiddenTasks.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: runtime.showHiddenTasks ? "eye" : "eye.slash")
                Text("Hidden \(runtime.hiddenTaskCount)").font(LHFont.button)
            }
            .foregroundStyle(runtime.showHiddenTasks ? theme.primary : theme.dim)
            .padding(.horizontal, 12).frame(minHeight: 38)
            .background(theme.panel2, in: RoundedRectangle(cornerRadius: Theme.Radius.search))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.search)
                .strokeBorder(theme.border2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(runtime.showHiddenTasks ? "Re-hide hidden tasks" : "Show hidden tasks")
    }

    /// Opens the Supervisor panel; its label says whether the supervisor is on or halted.
    private var supervisorButton: some View {
        let runner = runtime.supervisor
        let state = runner.state.haltReason != nil ? "halted"
            : (runner.settings.enabled ? (runner.settings.automatic ? "auto" : "on") : "off")
        return Button { runtime.supervisorPanelPresented = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "binoculars")
                Text("Supervisor \(state)").font(LHFont.button)
            }
            .foregroundStyle(state == "off" ? theme.dim : (state == "halted" ? theme.primary : theme.text))
            .padding(.horizontal, 12).frame(minHeight: 38)
            .background(theme.panel2, in: RoundedRectangle(cornerRadius: Theme.Radius.search))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.search)
                .strokeBorder(theme.border2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Configure the supervisor and run it by hand")
    }

    private var subtitle: String {
        let n = runtime.model.tasks.count
        let m = runtime.model.repos.count
        let live = runtime.model.tasks.filter { runtime.model.isSessionLive($0.id) }.count
        return "\(n) task\(n == 1 ? "" : "s") across \(m) repo\(m == 1 ? "" : "s") · \(live) live"
    }

    private var searchButton: some View {
        Button { runtime.switcherPresented = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.dim)
                Text("Search tasks & repos…")
                    .font(LHFont.body)
                    .foregroundStyle(theme.dim)
                Spacer(minLength: 12)
                Keycap(text: "⌘K")
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 280, minHeight: 38)
            .background(theme.panel2, in: RoundedRectangle(cornerRadius: Theme.Radius.search))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.search)
                .strokeBorder(theme.border2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .overlay { focusRing(.search) }
    }

    /// A plain terminal in a chosen directory, with no repo — see
    /// `AppRuntime.promptAndOpenScratchTerminal`. Always enabled (needs no
    /// registered repo), which is the whole point.
    private var scratchTerminalButton: some View {
        Button { runtime.promptAndOpenScratchTerminal() } label: {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                Text("Scratch terminal").font(LHFont.button)
            }
            .foregroundStyle(theme.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
            .background(theme.panel2, in: RoundedRectangle(cornerRadius: Theme.Radius.search))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.search)
                .strokeBorder(theme.border2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .overlay { focusRing(.scratch) }
        .help("Open a plain terminal in a chosen directory — no repo needed")
    }

    private var newTaskButton: some View {
        Button { showCreateTask = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                Text("New task").font(LHFont.button)
            }
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
            .background(theme.primary, in: RoundedRectangle(cornerRadius: Theme.Radius.search))
        }
        .buttonStyle(.plain)
        .overlay { focusRing(.newTask) }
        .disabled(runtime.model.repos.isEmpty)
        .opacity(runtime.model.repos.isEmpty ? 0.5 : 1)
        .help(runtime.model.repos.isEmpty ? "Register a repo first" : "Create a new task")
    }

    // MARK: Task grid

    private func taskGrid(_ cards: [TaskRecord]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 330), spacing: 16, alignment: .top)],
            spacing: 16
        ) {
            ForEach(cards) { task in
                Button { runtime.open(task.id) } label: {
                    TaskCardView(task: task)
                }
                .buttonStyle(.plain)
                // A hidden task only appears here when "Hidden" is toggled on;
                // dim it so it reads as hidden-but-revealed.
                .opacity(task.hidden ? 0.5 : 1)
                // Arrow-key browse highlight (Return opens it).
                .overlay {
                    if runtime.harborHighlightedTaskId == task.id {
                        RoundedRectangle(cornerRadius: Theme.Radius.card)
                            .strokeBorder(theme.primary, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
                .taskContextMenu(for: task)
            }
        }
    }

    // MARK: Repos

    @ViewBuilder
    private var reposSection: some View {
        if !runtime.model.repos.isEmpty {
            let collapsed = runtime.model.reposCollapsed
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    // The whole "REPOS" label toggles the section — it carries
                    // little action, so it opens collapsed and tucks away.
                    Button { runtime.model.setReposCollapsed(!collapsed) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                            Text("REPOS").font(LHFont.mono(13, .semibold)).tracking(0.6)
                            if collapsed {
                                Text("\(runtime.model.repos.count)")
                                    .font(LHFont.metaFaint).foregroundStyle(theme.faint)
                            }
                        }
                        .foregroundStyle(theme.dim)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay { focusRing(.reposHeader, radius: Theme.Radius.chip).padding(-4) }
                    .help(collapsed ? "Show repos" : "Hide repos")
                    Spacer()
                    Button { runtime.registerRepoPresented = true } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                            Text("Add repo").font(LHFont.button)
                        }
                        .foregroundStyle(theme.dim)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(theme.panel2, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .strokeBorder(theme.border2, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .overlay { focusRing(.addRepo, radius: Theme.Radius.chip) }
                    .help("Register another local repo")
                }
                if !collapsed {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)],
                        spacing: 16
                    ) {
                        ForEach(runtime.model.repos) { repo in
                            RepoCardView(repo: repo, taskCount: taskCount(for: repo))
                        }
                    }
                }
            }
        }
    }

    private func taskCount(for repo: RepoConfig) -> Int {
        runtime.model.tasks.filter { $0.workspaces.contains { $0.repoId == repo.id } }.count
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sailboat")
                .font(.system(size: 40))
                .foregroundStyle(theme.faint)
            Text("No tasks yet")
                .font(LHFont.summaryHead)
                .foregroundStyle(theme.text)
            Text(runtime.model.repos.isEmpty
                 ? "Register a repo, then create your first task."
                 : "Create a task to put an agent to work.")
                .font(LHFont.body)
                .foregroundStyle(theme.dim)
            // With no repos, the first step is registering one — offer THAT
            // (enabled) rather than a dead disabled "New task" button.
            let needsRepo = runtime.model.repos.isEmpty
            Button {
                if needsRepo { runtime.registerRepoPresented = true } else { showCreateTask = true }
            } label: {
                Text(needsRepo ? "Register a repo" : "New task")
                    .font(LHFont.button).foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 16).frame(minHeight: 38)
                    .background(theme.primary, in: RoundedRectangle(cornerRadius: Theme.Radius.search))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

/// A Harbor task card (handoff §1). `fadeup` entrance (~.4s, reduce-motion
/// gated); needs-you cards carry a static amber glow shadow (the ambient
/// "look at me" — NOT motion-gated, per the handoff). Honest metadata only:
/// relative time + repo names; the Phase-4 fields (model/ctx%/+add/−del/files)
/// are graceful blanks, never fabricated numbers.
struct TaskCardView: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.theme) private var theme
    @Environment(\.motionEnabled) private var motionEnabled
    let task: TaskRecord
    @State private var appeared = false

    private var live: Bool { runtime.model.isSessionLive(task.id) }
    private var digest: TaskDigest { runtime.digests.digest(for: task.id) }

    var body: some View {
        let accent = theme.liveAccent(live)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                // Harbor rows are the ONLY place the live pulse animates: this
                // screen is never on screen while a terminal is, so the per-frame
                // layout cost can't steal SwiftTerm's main thread.
                StatusDot(live: live, pulses: true)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.name)
                        .font(LHFont.cardTitle)
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Text(metaLine)
                        .font(LHFont.meta)
                        .foregroundStyle(theme.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                StatusPill(status: task.status)
            }
            // Footer (handoff §1): model chip · +add/−del · files · time. Every
            // slot is honest — a nil digest field renders NOTHING (never a fake
            // 0/placeholder). A real no-change diff shows `0` (known zero).
            Divider().overlay(theme.borderSoft).padding(.top, 13)
            HStack(spacing: 12) {
                if let model = digest.model {
                    ModelChip(model: model)
                }
                if let stat = digest.diffStat {
                    DiffMetrics(stat: stat)
                }
                Spacer(minLength: 8)
                if let since = runtime.model.lastActivity(of: task.id) {
                    Text(relativeTime(since))
                        .font(LHFont.metaFaint)
                        .foregroundStyle(theme.faint)
                }
            }
            .padding(.top, 8)
            .frame(minHeight: 16)
        }
        .padding(EdgeInsets(top: 16, leading: 17, bottom: 14, trailing: 17))
        .background(theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(theme.border, lineWidth: 1))
        // 3px left border in the status accent (handoff §1).
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(
                topLeadingRadius: Theme.Radius.card, bottomLeadingRadius: Theme.Radius.card)
                .fill(accent)
                .frame(width: 3)
        }
        // Live-session glow shadow — a STATIC ambient "this one is running"
        // signal, not motion-gated. The 3px accent border above stays.
        .shadow(color: live ? accent.opacity(0.5) : .clear,
                radius: live ? 13 : 0)
        // fadeup entrance (~.4s subtle offset+opacity), reduce-motion gated:
        // when motion is off the card is shown in its final frame with no
        // animation.
        .opacity(motionEnabled ? (appeared ? 1 : 0) : 1)
        .offset(y: motionEnabled ? (appeared ? 0 : 8) : 0)
        .onAppear {
            if motionEnabled {
                withAnimation(.easeOut(duration: 0.4)) { appeared = true }
            } else {
                appeared = true
            }
        }
        .contentShape(Rectangle())
    }

    private var metaLine: String {
        let repoNames = task.workspaces.compactMap { ws in
            runtime.model.repos.first { $0.id == ws.repoId }?.pathURL.lastPathComponent
        }
        let repoPart = repoNames.isEmpty ? "" : repoNames.joined(separator: ", ") + " · "
        return repoPart + task.branch
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// A Harbor repo row (handoff §1): avatar initial, name + path, base branch +
/// task count.
struct RepoCardView: View {
    @Environment(\.theme) private var theme
    let repo: RepoConfig
    let taskCount: Int

    var body: some View {
        HStack(spacing: 14) {
            Text(String(repo.pathURL.lastPathComponent.prefix(1)).uppercased())
                .font(LHFont.mono(15))
                .foregroundStyle(theme.primary)
                .frame(width: 38, height: 38)
                .background(theme.panel3, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.border, lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(repo.pathURL.lastPathComponent)
                    .font(LHFont.ui(14, .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text(repo.path)
                    .font(LHFont.meta)
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(repo.baseBranch)
                    .font(LHFont.meta)
                    .foregroundStyle(theme.dim)
                Text("\(taskCount) task\(taskCount == 1 ? "" : "s")")
                    .font(LHFont.metaFaint)
                    .foregroundStyle(theme.faint)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .background(theme.panel2, in: RoundedRectangle(cornerRadius: Theme.Radius.row))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row)
            .strokeBorder(theme.borderSoft, lineWidth: 1))
    }
}

/// Right-click actions shared by every task surface (Harbor card, beacon-rail
/// dot): resume a resumable session, and remove the task (opens the
/// confirmation sheet via `runtime.taskPendingRemoval`). Restores the affordance
/// the retired sidebar carried — reachable now from wherever a task appears.
private struct TaskContextMenu: ViewModifier {
    @Environment(AppRuntime.self) private var runtime
    let task: TaskRecord

    func body(content: Content) -> some View {
        content.contextMenu {
            // A scratch terminal owns nothing on disk, so it skips the
            // removal-hazard sheet and just closes.
            if task.workspaces.isEmpty {
                Button("Close Terminal", role: .destructive) {
                    runtime.closeScratchTask(task)
                }
            } else {
                if runtime.model.canResume(task) {
                    Button("Resume Session") { runtime.resumeSession(for: task) }
                }
                Button(task.hidden ? "Unhide" : "Hide") {
                    runtime.toggleTaskHidden(task)
                }
                Button("Remove Task…", role: .destructive) {
                    runtime.taskPendingRemoval = task
                }
            }
        }
    }
}

extension View {
    /// Attaches the resume / remove context menu to a task surface.
    func taskContextMenu(for task: TaskRecord) -> some View {
        modifier(TaskContextMenu(task: task))
    }
}
