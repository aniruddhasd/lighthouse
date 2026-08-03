import SwiftUI
import LighthouseAppCore
import LighthouseGit

/// The right-hand navigator: a segmented Changes | Files | History control over
/// a shared per-task repo picker (multi-repo tasks). Selecting an item promotes
/// the matching page into the center content viewer (the workbench does the
/// I/O + swap). Narrow and hideable; the live-diff watcher behind Changes runs
/// for the whole time this is on screen, regardless of the active segment.
struct NavigatorView: View {
    @Environment(\.theme) private var theme
    @Environment(AppRuntime.self) private var runtime
    @Bindable var workbench: WorkbenchModel

    var body: some View {
        VStack(spacing: 0) {
            header
            tabs
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = errorText {
                Text(error)
                    .font(LHFont.meta).foregroundStyle(.red).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.chrome)
        .onAppear { workbench.ensureLoaded(for: workbench.navigatorMode) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("REPO")
                .font(LHFont.mono(10.5, .semibold)).tracking(0.6)
                .foregroundStyle(theme.faint)
            Picker("Repo", selection: $workbench.selectedWorkspaceIndex) {
                ForEach(workbench.review.workspaces, id: \.index) { entry in
                    Text(entry.repoName).tag(entry.index)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            // Add another repo / worktree to this task (tracked from now on).
            Button { runtime.taskPendingAddWorkspace = workbench.task } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.dim)
            }
            .buttonStyle(.plain)
            .help("Add a repo or worktree to this task")
            if workbench.navigatorMode == .changes {
                // Uncommitted (working tree vs HEAD) vs the whole branch vs its
                // base branch. The base is NAMED here (read-only); it is chosen
                // in the Summary tab, not the sidebar.
                Picker("Scope", selection: Binding(
                    get: { workbench.review.scope },
                    set: { workbench.review.scope = $0 })) {
                    Text("Uncommitted").tag(DiffScope.uncommitted)
                    Text(vsBaseLabel).tag(DiffScope.vsBase)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Uncommitted changes, or the whole worktree vs its base branch (set the base in the Summary tab)")
                Button { workbench.review.refreshNow() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11)).foregroundStyle(theme.dim)
                }
                .buttonStyle(.plain)
                .help("Refresh diff (⌘R)")
                // Cmd+R while the navigator is on screen.
                Button("", action: { workbench.review.refreshNow() })
                    .keyboardShortcut("r", modifiers: .command)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
            Spacer(minLength: 4)
            // Close × lives in the header row (spec §2), not floating over it.
            Button { workbench.navigatorVisible = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.dim)
            }
            .buttonStyle(.plain)
            .help("Close the navigator (⌘\\)")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.borderSoft).frame(height: 1) }
    }

    /// The "vs base" segment label, naming the active base branch (e.g. "vs main").
    private var vsBaseLabel: String { "vs \(workbench.review.activeBase ?? "base")" }

    /// Changes / Files / History — an equal-width segmented control, active
    /// segment `--elev` bg + `--border` (handoff §2 "Navigator overlay: Tabs").
    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(NavigatorMode.allCases) { mode in
                let active = workbench.navigatorMode == mode
                Button {
                    workbench.navigatorMode = mode
                    workbench.ensureLoaded(for: mode)
                } label: {
                    Text(mode.title)
                        .font(LHFont.button)
                        .foregroundStyle(active ? theme.text : theme.dim)
                        .frame(maxWidth: .infinity).frame(height: 26)
                        .background(active ? theme.elev : Color.clear,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.segment))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.segment)
                            .strokeBorder(active ? theme.border : Color.clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(theme.panel2, in: RoundedRectangle(cornerRadius: Theme.Radius.segment + 3))
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch workbench.navigatorMode {
        case .changes: changesList
        case .files: filesList
        case .history: historyList
        }
    }

    private var errorText: String? {
        switch workbench.navigatorMode {
        case .changes: return workbench.review.renderError
        case .files: return workbench.filesError
        case .history: return workbench.historyError
        }
    }

    // MARK: Changes — the live changed-files tree (drives the diff promotion)

    @ViewBuilder
    private var changesList: some View {
        let tree = workbench.review.tree
        if tree.isEmpty {
            ContentUnavailableView(
                "No changes",
                systemImage: "checkmark.circle",
                description: Text("Nothing differs from base yet."))
        } else {
            List {
                ForEach(tree) { node in
                    NavigatorTreeRow(
                        node: node,
                        isExpanded: { workbench.review.expansion.isExpanded($0) },
                        setExpanded: { workbench.review.expansion.setExpanded($0, for: $1) },
                        onSelect: { path in Task { await workbench.selectChangedFile(path) } })
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: Files — a gitignore-aware repo browser tree

    @ViewBuilder
    private var filesList: some View {
        if workbench.files.isEmpty {
            ContentUnavailableView(
                "No files",
                systemImage: "folder",
                description: Text("This repo has no tracked or untracked files."))
        } else {
            List {
                ForEach(workbench.files) { node in
                    NavigatorTreeRow(
                        node: node,
                        isExpanded: { workbench.isFileExpanded($0) },
                        setExpanded: { workbench.setFileExpanded($0, $1) },
                        onSelect: { path in Task { await workbench.selectFile(path) } })
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: History — recent commits (drives the commit-diff promotion)

    @ViewBuilder
    private var historyList: some View {
        if workbench.commits.isEmpty {
            ContentUnavailableView(
                "No history",
                systemImage: "clock",
                description: Text("No commits to show."))
        } else {
            List(workbench.commits, id: \.hash) { commit in
                Button {
                    Task { await workbench.selectCommit(commit) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(commit.subject).lineLimit(1).truncationMode(.tail)
                        HStack(spacing: 6) {
                            Text(commit.shortHash).font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text(commit.authorName).font(.caption2)
                                .foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text(CommitDateFormatter.relativeString(from: commit.authorDate))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }
}

/// One recursive row shared by the Changes tree (files carry a status glyph)
/// and the Files browser (files carry a doc icon). Directories are
/// DisclosureGroups whose expansion is driven by the caller's session state
/// (expanded by default, collapsed dirs show a file count so a fold never hides
/// files); files are tappable leaves. A dedicated struct because a
/// self-recursive `some View` function cannot infer its own type.
private struct NavigatorTreeRow: View {
    let node: FileTreeNode
    let isExpanded: (String) -> Bool
    let setExpanded: (Bool, String) -> Void
    let onSelect: (String) -> Void

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: Binding(
                get: { isExpanded(node.id) },
                set: { setExpanded($0, node.id) })) {
                ForEach(children) { child in
                    NavigatorTreeRow(
                        node: child, isExpanded: isExpanded,
                        setExpanded: setExpanded, onSelect: onSelect)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.caption)
                    Text(node.name).lineLimit(1).truncationMode(.tail)
                    if !isExpanded(node.id) {
                        Text("(\(node.fileCount))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .help(node.id)
            }
        } else {
            HStack(spacing: 6) {
                if let status = node.status {
                    Text(status)
                        .font(.system(.caption2, design: .monospaced).bold())
                        .foregroundStyle(Self.statusColor(status))
                        .frame(width: 14)
                } else {
                    Image(systemName: "doc")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                Text(node.name).lineLimit(1).truncationMode(.middle)
            }
            .help(node.id)
            .contentShape(Rectangle())
            .onTapGesture { onSelect(node.id) }
        }
    }

    static func statusColor(_ status: String?) -> Color {
        switch status {
        case "A", "?": return .green
        case "D": return .red
        case "M", "T": return .orange
        case "R", "C": return .blue
        default: return .secondary
        }
    }
}
