import SwiftUI
import WebKit
import LighthouseAppCore
import LighthouseGit
import LighthouseTaskEngine

/// Replaces the review pane while a merge walk is paused on a conflict
/// (spec §2.5). Walk progress + per-file resolution controls are native
/// SwiftUI; the three-way conflict CONTENT is rendered through the locked
/// WKWebView (ConflictPageBuilder — base64/CSP, same discipline as the diff
/// pane). Actions are native (no in-page JS) — strictly less attack surface,
/// and structured-transform-only per guardrail 2.
struct ConflictPaneView: View {
    @Environment(AppRuntime.self) private var runtime
    @Bindable var controller: MergeWalkController
    @State private var selectedPath: String?
    @State private var webView = WKWebView()
    @State private var renderDirectory: URL?
    @State private var navigationGate: LocalOnlyNavigationDelegate?

    var body: some View {
        VStack(spacing: 0) {
            walkHeader
            Divider()
            if controller.isPausedConflicted {
                HSplitView {
                    fileList.frame(minWidth: 180, maxWidth: 320, maxHeight: .infinity)
                    VStack(spacing: 0) {
                        if let path = selectedPath,
                           let conflict = controller.conflicts.first(where: { $0.path == path }) {
                            DiffWebViewHost(webView: webView)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            Divider()
                            resolutionControls(for: conflict)
                        } else {
                            ContentUnavailableView("Select a conflicted file",
                                                   systemImage: "arrow.triangle.merge")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                pausedNonConflict
            }
            if let error = controller.lastError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).padding(4)
            }
        }
        .onAppear(perform: setUpWebView)
        .onChange(of: selectedPath) { _, _ in loadSelected() }
        .onChange(of: controller.conflicts) { _, _ in loadSelected() }
    }

    // MARK: Walk chrome

    private var walkHeader: some View {
        HStack {
            let merged = controller.progress.filter { $0.state == .merged }.count
            let total = controller.progress.count
            Text("Merge to base · \(merged)/\(total) repos")
                .font(.headline)
            Spacer()
            if controller.busy { ProgressView().controlSize(.small) }
            if controller.isPausedConflicted {
                Button("Ask Claude") { Task { await controller.askClaudeToResolve() } }
                Button("Abort repo", role: .destructive) {
                    Task { await controller.abortCurrentRepo(); syncTask() }
                }
                Button("Complete repo") {
                    Task { await controller.completeCurrentRepo(); syncTask() }
                }
                .disabled(!controller.allFilesResolved)
                .keyboardShortcut(.defaultAction)
            }
            Button("Close") { runtime.endMergeWalk() }
        }
        .padding(8)
    }

    @ViewBuilder
    private var pausedNonConflict: some View {
        if case .paused(_, let reason) = controller.state {
            ContentUnavailableView {
                Label("Merge paused", systemImage: "pause.circle")
            } description: {
                Text(describe(reason))
            } actions: {
                Button("Retry") { Task { await controller.start() } }
            }
        } else if case .completed = controller.state {
            ContentUnavailableView("Merge complete", systemImage: "checkmark.circle")
        } else {
            ProgressView()
        }
    }

    private var fileList: some View {
        List(controller.conflicts, selection: $selectedPath) { conflict in
            HStack {
                Image(systemName: icon(for: conflict.kind))
                Text(conflict.path).lineLimit(1).truncationMode(.middle)
            }.tag(conflict.path)
        }
        .listStyle(.sidebar)
    }

    // MARK: Resolution controls (structured, per kind)

    @ViewBuilder
    private func resolutionControls(for conflict: ClassifiedConflict) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch conflict.kind {
            case .text(let blocks):
                Text("\(blocks.count) block(s) — choose a side per block, then Apply.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(blocks) { block in
                    HStack {
                        Text("Block \(block.id + 1)").font(.caption.monospaced())
                        Picker("", selection: choiceBinding(path: conflict.path, block: block.id)) {
                            Text("Current").tag(BlockResolution.current)
                            Text("Incoming").tag(BlockResolution.incoming)
                            Text("Both").tag(BlockResolution.both)
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                }
                HStack {
                    Button("Apply choices") { Task { await controller.resolveText(path: conflict.path) } }
                    Button("Whole file: Current") {
                        Task { await controller.resolveWholeFileText(path: conflict.path, side: .current) }
                    }
                    Button("Whole file: Incoming") {
                        Task { await controller.resolveWholeFileText(path: conflict.path, side: .incoming) }
                    }
                    Button("Restart markers") { Task { await controller.rematerialize(path: conflict.path) } }
                    Button("Open in $EDITOR") { Task { await controller.openInEditor(path: conflict.path) } }
                }
            case .binary:
                Text("Binary conflict — choose a whole-file side.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Keep Ours") { Task { await controller.resolveBinary(path: conflict.path, side: .ours) } }
                    Button("Keep Theirs") { Task { await controller.resolveBinary(path: conflict.path, side: .theirs) } }
                }
            case .deleteModify(let modifiedSide):
                Text("Delete/modify conflict.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Keep Modified") {
                        Task { await controller.resolveDeleteModify(
                            path: conflict.path, keepModified: true, modifiedSide: modifiedSide) }
                    }
                    Button("Keep Deleted", role: .destructive) {
                        Task { await controller.resolveDeleteModify(
                            path: conflict.path, keepModified: false, modifiedSide: modifiedSide) }
                    }
                }
            }
        }
        .padding(8)
    }

    // MARK: Helpers

    private func choiceBinding(path: String, block: Int) -> Binding<BlockResolution> {
        Binding(
            get: { controller.textChoices[path]?[block] ?? .current },
            set: { controller.setChoice(path: path, block: block, choice: $0) })
    }

    private func icon(for kind: ClassifiedConflict.Kind) -> String {
        switch kind {
        case .text: return "doc.text"
        case .binary: return "doc.zipper"
        case .deleteModify: return "trash"
        }
    }

    private func describe(_ reason: MergeWalkPauseReason) -> String {
        switch reason {
        case .cloneDirty(let p): return "The clone at \(p) has uncommitted changes. Commit or stash, then Retry."
        case .cloneNotOnBase(let p, let base, let actual):
            return "The clone at \(p) is on '\(actual)', not '\(base)'. Check out '\(base)', then Retry."
        case .cloneDetached(let p, let base): return "The clone at \(p) is detached; check out '\(base)', then Retry."
        case .cloneMidMerge(let p): return "A merge is already in progress in \(p). Resolve or abort it, then Retry."
        case .baseMissing(let p, let base): return "Base branch '\(base)' does not exist in \(p)."
        case .conflicted: return "Conflicts to resolve."
        case .abortedByUser(let p): return "You aborted the merge in \(p). Retry to try again."
        }
    }

    private func syncTask() {
        if case .completed = controller.state {
            runtime.model.markMerged(taskId: controller.task.id)
            runtime.endMergeWalk()
        }
    }

    private func setUpWebView() {
        guard let dir = try? DiffWebViewFactory.makeRenderDirectory() else { return }
        renderDirectory = dir
        let gate = LocalOnlyNavigationDelegate(allowedRoot: dir)
        navigationGate = gate
        webView = DiffWebViewFactory.makeWebView(renderDirectory: dir, navigationGate: gate)
        if selectedPath == nil { selectedPath = controller.conflicts.first?.path }
        loadSelected()
    }

    private func loadSelected() {
        guard let dir = renderDirectory else { return }
        guard let path = selectedPath,
              let conflict = controller.conflicts.first(where: { $0.path == path }) else { return }
        let blocks: [ConflictBlockView]
        if case .text(let b) = conflict.kind { blocks = b } else { blocks = [] }
        let page = ConflictPageBuilder.page(path: path, blocks: blocks)
        try? DiffWebViewFactory.load(page: page, into: webView, renderDirectory: dir)
    }
}
