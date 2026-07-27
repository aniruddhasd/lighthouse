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
    /// Status → accent color: the clean mapping (spec §2) with no new state
    /// machine — working, needsInput→needs(amber), done→idle(green),
    /// dirty→stale(muted yellow).
    func accent(for state: TaskAttentionState) -> Color {
        switch state {
        case .working: return working
        case .needsInput: return needs
        case .done: return idle
        case .dirty: return stale
        }
    }
}

/// Human-facing status label (the redesign's vocabulary: idle/unaccounted).
func harborStatusLabel(_ state: TaskAttentionState) -> String {
    switch state {
    case .working: return "Working"
    case .needsInput: return "Needs you"
    case .done: return "Idle"
    case .dirty: return "Unaccounted"
    }
}

/// A 9px status dot in the state accent. `.working` CAN get a pulsing expanding
/// ring (~1.6s infinite, handoff), but only where `pulses` is opted in — see
/// that property. Reduce-motion gated, so it is a steady dot when motion is off.
/// The ring is an OVERLAY (never changes the dot's frame), so a pulsing dot
/// never reflows the row. `glow` adds the needs-you amber halo.
struct StatusDot: View {
    @Environment(\.theme) private var theme
    @Environment(\.motionEnabled) private var motionEnabled
    let state: TaskAttentionState
    var size: CGFloat = 9
    var glow: Bool = false
    /// Opt-in continuous pulse, default OFF so the dot is STATIC everywhere a
    /// terminal is on screen (the focus rail/header, the switcher). An infinite
    /// animation there forces an NSHostingView layout pass every display cycle,
    /// stealing the main thread from SwiftTerm's drawing and lagging typing
    /// (profiled 2026-07-27). Only the harbor rows — never on screen while a
    /// terminal is — turn it on.
    var pulses: Bool = false
    @State private var pulsing = false

    var body: some View {
        let accent = theme.accent(for: state)
        Circle()
            .fill(accent)
            .frame(width: size, height: size)
            .overlay {
                // Only the working state pulses, only when motion is on, and only
                // where the caller opted in: the ring view is otherwise absent
                // (not merely paused), so no infinite animation is ever mounted.
                if state == .working && motionEnabled && pulses {
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
            .shadow(color: glow ? accent.opacity(0.65) : .clear, radius: glow ? 5 : 0)
    }
}

/// Status pill: `{accent}22` bg, `{accent}55` border, `{accent}` text, radius
/// 20 (handoff §1 card head row).
struct StatusPill: View {
    @Environment(\.theme) private var theme
    let state: TaskAttentionState

    var body: some View {
        let accent = theme.accent(for: state)
        Text(harborStatusLabel(state))
            .font(LHFont.pill)
            .foregroundStyle(accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(accent.opacity(0.13),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.pill))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.pill)
                .strokeBorder(accent.opacity(0.33), lineWidth: 1))
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

    private var orderedFilteredTasks: [TaskRecord] {
        runtime.model.harborOrder().filter {
            runtime.nav.filter.matches(runtime.model.attentionState(of: $0.id))
        }
    }

    var body: some View {
        let cards = orderedFilteredTasks
        VStack(spacing: 0) {
            header
            filterChips
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
        .onAppear { HarborDebug.emit("rendered-cards=\(cards.count)") }
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
            searchButton
            newTaskButton
        }
        .padding(.leading, Theme.Metric.gutter)
        .padding(.trailing, Theme.Metric.gutter)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private var subtitle: String {
        let n = runtime.model.tasks.count
        let m = runtime.model.repos.count
        let k = runtime.model.needsInputCount
        return "\(n) task\(n == 1 ? "" : "s") across \(m) repo\(m == 1 ? "" : "s") · \(k) need you"
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
        .disabled(runtime.model.repos.isEmpty)
        .opacity(runtime.model.repos.isEmpty ? 0.5 : 1)
        .help(runtime.model.repos.isEmpty ? "Register a repo first" : "Create a new task")
    }

    // MARK: Filter chips

    private var filterChips: some View {
        FlowLayout(spacing: 9) {
            ForEach(HarborFilter.allCases) { filter in
                FilterChip(
                    filter: filter,
                    count: chipCount(filter),
                    active: runtime.nav.filter == filter,
                    action: { runtime.nav.setFilter(filter) })
            }
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }

    /// Chip counts come from the full task list mapped by state (spec §3).
    private func chipCount(_ filter: HarborFilter) -> Int {
        runtime.model.tasks.filter {
            filter.matches(runtime.model.attentionState(of: $0.id))
        }.count
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
                .taskContextMenu(for: task)
            }
        }
    }

    // MARK: Repos

    @ViewBuilder
    private var reposSection: some View {
        if !runtime.model.repos.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("REPOS")
                        .font(LHFont.mono(13, .semibold))
                        .tracking(0.6)
                        .foregroundStyle(theme.dim)
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
                    .help("Register another local repo")
                }
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

    private var state: TaskAttentionState { runtime.model.attentionState(of: task.id) }
    private var digest: TaskDigest { runtime.digests.digest(for: task.id) }

    var body: some View {
        let accent = theme.accent(for: state)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                // Harbor rows are the ONLY place the working pulse animates: this
                // screen is never on screen while a terminal is, so the per-frame
                // layout cost can't steal SwiftTerm's main thread.
                StatusDot(state: state, glow: state == .needsInput, pulses: true)
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
                StatusPill(state: state)
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
                if let since = runtime.model.attentionSince(of: task.id) {
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
        // Needs-you card glow shadow (handoff §1: `0 0 26px -8px {accent}`) —
        // a STATIC ambient signal, not motion-gated. The 3px accent border
        // above stays.
        .shadow(color: state == .needsInput ? accent.opacity(0.5) : .clear,
                radius: state == .needsInput ? 13 : 0)
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

/// One Harbor filter chip: status dot (except All) + label + count. Active =
/// status-tint bg + border + colored text; inactive = panel2/border2/dim.
struct FilterChip: View {
    @Environment(\.theme) private var theme
    let filter: HarborFilter
    let count: Int
    let active: Bool
    let action: () -> Void

    private var label: String {
        switch filter {
        case .all: return "All"
        case .needs: return "Needs you"
        case .working: return "Working"
        case .idle: return "Idle"
        case .stale: return "Unaccounted"
        }
    }

    var body: some View {
        // The tint color for a chip: its mapped status accent, or primary for All.
        let tint: Color = filter.attentionState.map { theme.accent(for: $0) } ?? theme.primary
        Button(action: action) {
            HStack(spacing: 6) {
                if let state = filter.attentionState {
                    Circle().fill(theme.accent(for: state)).frame(width: 7, height: 7)
                }
                Text(label).font(LHFont.button)
                Text("\(count)").font(LHFont.metaFaint)
                    .foregroundStyle(active ? tint.opacity(0.9) : theme.faint)
            }
            .foregroundStyle(active ? tint : theme.dim)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(active ? tint.opacity(0.14) : theme.panel2,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip)
                .strokeBorder(active ? tint.opacity(0.45) : theme.border2, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// A minimal wrapping HStack for the filter chip row (the chips wrap; SwiftUI
/// has no stock flow container pre-macOS 15, so a tiny Layout keeps the deploy
/// target at macOS 14).
struct FlowLayout: Layout {
    var spacing: CGFloat = 9

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var x: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([]); x = 0
            }
            rows[rows.count - 1].append(size)
            x += size.width + spacing
        }
        let height = rows.reduce(CGFloat(0)) { acc, row in
            acc + (row.map(\.height).max() ?? 0) + spacing
        } - (rows.isEmpty ? 0 : spacing)
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: max(0, height))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
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
            if runtime.model.canResume(task) {
                Button("Resume Session") { runtime.resumeSession(for: task) }
            }
            Button("Remove Task…", role: .destructive) {
                runtime.taskPendingRemoval = task
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
