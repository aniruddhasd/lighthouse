import SwiftUI
import LighthouseAppCore
import LighthouseGit

/// The right-hand navigator: a segmented Changes | Files | History control over
/// a shared per-task repo picker (multi-repo tasks). Selecting an item promotes
/// the matching page into the center content viewer (the workbench does the
/// I/O + swap). Narrow and hideable; the live-diff watcher behind Changes runs
/// for the whole time this is on screen, regardless of the active segment.
struct NavigatorView: View {
    @Bindable var workbench: WorkbenchModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("Navigator", selection: $workbench.navigatorMode) {
                ForEach(NavigatorMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(6)
            .onChange(of: workbench.navigatorMode) { _, mode in
                workbench.ensureLoaded(for: mode)
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = errorText {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).padding(4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { workbench.ensureLoaded(for: workbench.navigatorMode) }
    }

    private var header: some View {
        HStack {
            Picker("Repo", selection: $workbench.selectedWorkspaceIndex) {
                ForEach(workbench.review.workspaces, id: \.index) { entry in
                    Text(entry.repoName).tag(entry.index)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Spacer()
            if workbench.navigatorMode == .changes {
                Text("diff vs base · live")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button { workbench.review.refreshNow() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh diff (⌘R)")
                // Cmd+R while the navigator is on screen.
                Button("", action: { workbench.review.refreshNow() })
                    .keyboardShortcut("r", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .padding(6)
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
