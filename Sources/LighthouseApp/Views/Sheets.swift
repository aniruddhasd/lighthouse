import SwiftUI
import LighthouseAppCore
import LighthouseGit
import LighthouseTaskEngine

struct CreateTaskSheet: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var branch = ""
    @State private var branchEdited = false
    /// Ordered selection: position = walk order at creation and merge-back.
    @State private var selectedRepoIds: [UUID] = []
    @State private var creating = false
    /// How the session's workspace is made. New worktree (default) branches off
    /// base; current-directory runs in the repo's own checkout (investigation);
    /// from-PR fetches a pull request's branch into a worktree.
    private enum Mode: Hashable { case newWorktree, currentDir, fromPR }
    @State private var mode: Mode = .newWorktree
    /// A PR number or URL (from-PR mode).
    @State private var prReference = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Task").font(.headline)
            TextField(mode == .fromPR ? "Name (blank = PR title)" : "Name (e.g. payments fix)",
                      text: $name)
                .onChange(of: name) {
                    if !branchEdited { branch = AppModel.branchSlug(from: name) }
                }

            Picker("Workspace", selection: $mode) {
                Text("New worktree").tag(Mode.newWorktree)
                Text("Current directory").tag(Mode.currentDir)
                Text("From PR").tag(Mode.fromPR)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .newWorktree:
                TextField("Branch", text: $branch)
                    .onChange(of: branch) { _, new in
                        branchEdited = new != AppModel.branchSlug(from: name)
                    }
                    .font(.system(.body, design: .monospaced))
            case .currentDir:
                Text("Runs the session in each repo's own checkout — no worktree, no branch. For investigating or learning a repo without changing it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .fromPR:
                TextField("PR number or URL", text: $prReference)
                    .font(.system(.body, design: .monospaced))
                Text("Fetches the PR's branch into a worktree (via gh) on `pr-<N>`, tracking the PR so commits push back. Pick ONE repo — the PR's repo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(mode == .fromPR ? "Repo (pick the PR's repo)"
                 : "Repos (selection order = creation order)")
                .font(.caption)
                .foregroundStyle(.secondary)
            List(runtime.model.repos) { repo in
                let position = selectedRepoIds.firstIndex(of: repo.id)
                Button {
                    if let position {
                        selectedRepoIds.remove(at: position)
                    } else {
                        selectedRepoIds.append(repo.id)
                    }
                } label: {
                    HStack {
                        Image(systemName: position != nil
                            ? "\(position! + 1).circle.fill" : "circle")
                        Text(repo.pathURL.lastPathComponent)
                        Spacer()
                        Text(repo.baseBranch).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(height: 160)

            HStack(spacing: 8) {
                // Names exactly what's missing so the disabled button is never a
                // dead end. Hidden once the form is complete (or while creating).
                if !creating, !missingRequirements.isEmpty {
                    Text("Add \(ListFormatter.localizedString(byJoining: missingRequirements)) to continue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(creating ? "Creating…" : "Create & Start Session") {
                    creating = true
                    Task {
                        switch mode {
                        case .newWorktree, .currentDir:
                            await runtime.createTaskAndStartSession(
                                name: name, branch: branch, repoIds: selectedRepoIds,
                                inPlace: mode == .currentDir)
                        case .fromPR:
                            if let repoId = selectedRepoIds.first {
                                await runtime.createTaskFromPRAndStartSession(
                                    reference: prReference, repoId: repoId, name: name)
                            }
                        }
                        creating = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(creating || !missingRequirements.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// What the form still needs before it can be submitted — drives both the
    /// hint text and the button's disabled state, so they can never disagree.
    private var missingRequirements: [String] {
        var missing: [String] = []
        switch mode {
        case .newWorktree:
            if name.isEmpty { missing.append("a task name") }
            if branch.isEmpty { missing.append("a branch name") }
        case .currentDir:
            if name.isEmpty { missing.append("a task name") }
        case .fromPR:
            // Name is optional (defaults to the PR title).
            if prReference.isEmpty { missing.append("a PR number or URL") }
        }
        if selectedRepoIds.isEmpty { missing.append("a repo") }
        return missing
    }
}

/// Guardrail 1 UI: destroying work-losing hazards (unmerged commits AND/OR
/// dirty worktrees) lists each hazard distinctly and requires typing the task
/// name — the typed confirmation VALUE (RemovalConfirmation) is only
/// constructed after that.
struct RemoveTaskSheet: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    let task: TaskRecord

    @State private var hazards: [RemovalHazard]?
    @State private var typedName = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove \(task.name)").font(.headline)
            if let hazards {
                if hazards.isEmpty {
                    if task.isInPlace {
                        Text("This task ran in each repo's own checkout. Removing it leaves your repositories and branches untouched — only the task and its attention hooks are removed.")
                    } else {
                        Text("All workspaces are merged into their base branches with no uncommitted changes. Worktrees and branches will be removed.")
                    }
                    removalButtons(mode: .refuseIfHazards, label: "Remove Task")
                } else {
                    Label("This will PERMANENTLY DESTROY work:", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    ForEach(hazards, id: \.self) { hazard in
                        // Untrusted content: repo path / branch render as Text.
                        Text("• \(hazardDescription(hazard))")
                            .font(.system(.caption, design: .monospaced))
                    }
                    TextField("Type the task name to confirm", text: $typedName)
                    removalButtons(
                        mode: .destroy(RemovalConfirmation(destroying: hazards)),
                        label: "Remove and Discard Local Work",
                        enabled: typedName == task.name)
                }
            } else {
                ProgressView("Checking for unmerged or uncommitted work…")
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            do {
                hazards = try await runtime.model.removalHazards(for: task)
            } catch {
                runtime.lastError = String(describing: error)
                dismiss()
            }
        }
    }

    /// Each hazard named specifically and distinctly so the user knows exactly
    /// what is being discarded.
    private func hazardDescription(_ hazard: RemovalHazard) -> String {
        switch hazard {
        case .unmergedCommits(_, let repoPath, let branch):
            return "\(repoPath): branch '\(branch)' is not merged into its base branch"
        case .dirtyWorktree(_, let repoPath, let branch):
            return "\(repoPath): worktree for '\(branch)' has uncommitted local changes that will be permanently lost"
        }
    }

    @ViewBuilder
    private func removalButtons(mode: TaskRemovalMode, label: String, enabled: Bool = true) -> some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
            Button(working ? "Removing…" : label, role: .destructive) {
                working = true
                Task {
                    _ = await runtime.removeTask(task, mode: mode)
                    working = false
                    dismiss()
                }
            }
            .disabled(!enabled || working)
        }
    }
}

/// UI for removing ONE repo from a task (the inverse of AddToTaskSheet), with
/// two outcomes the user chooses between:
///   • Detach — stop tracking it here; the worktree and branch are left on disk
///     (never destructive, no confirmation).
///   • Discard — delete the worktree and branch (guardrail-1: unmerged/dirty
///     work requires typing the repo name).
/// An in-place or adopted repo (Lighthouse never owned its worktree) can only be
/// detached, so the choice collapses to that one action.
struct RemoveWorkspaceSheet: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    let request: WorkspaceRemovalRequest

    private enum Action: Hashable { case detach, discard }
    @State private var action: Action = .detach
    @State private var hazards: [RemovalHazard]?
    @State private var typedName = ""
    @State private var working = false

    /// Is the targeted workspace the repo's own checkout / an adopted worktree
    /// (never deleted), vs a Lighthouse-owned worktree?
    private var isInPlace: Bool {
        request.task.workspaces.first { $0.repoId == request.repoId }?.isInPlace ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove \(request.repoName) from “\(request.task.name)”").font(.headline)

            if isInPlace {
                // Nothing of ours on disk — detach is the only sensible action.
                Text("This repo was tracked in place. Removing it leaves your repository and branch untouched — Lighthouse just stops tracking it for this task.")
                actionButtons(primary: "Detach") { _ = runtime.detachWorkspace(
                    fromTask: request.task.id, repoId: request.repoId) }
            } else {
                Picker("What to do", selection: $action) {
                    Text("Detach (keep files)").tag(Action.detach)
                    Text("Discard (delete)").tag(Action.discard)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch action {
                case .detach:
                    Text("Stops tracking this repo for the task. Its worktree and branch stay on disk exactly as they are — nothing is deleted.")
                    actionButtons(primary: "Detach") { _ = runtime.detachWorkspace(
                        fromTask: request.task.id, repoId: request.repoId) }
                case .discard:
                    discardBody
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            // Only the discard path needs the hazard set, but it's cheap and the
            // result is reused if the user toggles back and forth.
            do {
                hazards = try await runtime.model.workspaceRemovalHazards(
                    for: request.task, repoId: request.repoId)
            } catch {
                runtime.lastError = String(describing: error)
                dismiss()
            }
        }
    }

    @ViewBuilder private var discardBody: some View {
        if let hazards {
            if hazards.isEmpty {
                Text("This repo's worktree is merged into its base branch with no uncommitted changes. Its worktree and branch will be deleted; the rest of the task is untouched.")
                destroyButtons(
                    mode: .refuseIfHazards, label: "Delete Worktree & Branch")
            } else {
                Label("This will PERMANENTLY DESTROY work:", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                ForEach(hazards, id: \.self) { hazard in
                    // Untrusted content: repo path / branch render as Text.
                    Text("• \(hazardDescription(hazard))")
                        .font(.system(.caption, design: .monospaced))
                }
                TextField("Type the repo name to confirm", text: $typedName)
                destroyButtons(
                    mode: .destroy(RemovalConfirmation(destroying: hazards)),
                    label: "Delete and Discard Local Work",
                    enabled: typedName == request.repoName)
            }
        } else {
            ProgressView("Checking for unmerged or uncommitted work…")
        }
    }

    private func hazardDescription(_ hazard: RemovalHazard) -> String {
        switch hazard {
        case .unmergedCommits(_, let repoPath, let branch):
            return "\(repoPath): branch '\(branch)' is not merged into its base branch"
        case .dirtyWorktree(_, let repoPath, let branch):
            return "\(repoPath): worktree for '\(branch)' has uncommitted local changes that will be permanently lost"
        }
    }

    /// Cancel + a single non-destructive primary (detach).
    @ViewBuilder
    private func actionButtons(primary: String, run: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
            Button(working ? "Removing…" : primary) {
                working = true
                run()
                working = false
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(working)
        }
    }

    /// Cancel + the destructive delete (discard), gated on the hazard mode.
    @ViewBuilder
    private func destroyButtons(mode: TaskRemovalMode, label: String, enabled: Bool = true) -> some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
            Button(working ? "Removing…" : label, role: .destructive) {
                working = true
                Task {
                    _ = await runtime.removeWorkspace(
                        fromTask: request.task.id, repoId: request.repoId, mode: mode)
                    working = false
                    dismiss()
                }
            }
            .disabled(!enabled || working)
        }
    }
}

struct RegisterRepoSheet: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss

    /// Register an existing local checkout, or clone a remote for keeps into a
    /// directory the user chooses (spec option D). Clone mode is a convenience
    /// over the same registration — Lighthouse never owns the clone.
    private enum Mode: Hashable { case localClone, cloneFromURL }
    @State private var mode: Mode = .localClone

    @State private var path = ""
    @State private var baseBranch = "main"
    @State private var setupScript = ""
    @State private var envCopyList = ""
    @State private var working = false

    // Clone-from-URL mode.
    @State private var remoteURL = ""
    @State private var destinationParent: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Register Repo").font(.headline)

            Picker("Source", selection: $mode) {
                Text("Local clone").tag(Mode.localClone)
                Text("Clone from URL").tag(Mode.cloneFromURL)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .localClone: localCloneFields
            case .cloneFromURL: cloneFromURLFields
            }

            DisclosureGroup("Advanced (optional)") {
                TextField("Setup script (relative to repo)", text: $setupScript)
                TextField("Env files to copy (comma-separated)", text: $envCopyList)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                switch mode {
                case .localClone: registerButton
                case .cloneFromURL: cloneButton
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder private var localCloneFields: some View {
        HStack {
            TextField("Path to local clone", text: $path)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url {
                    path = url.path
                    // Auto-detect the base branch from the clone's HEAD.
                    Task { baseBranch = await runtime.model.suggestBaseBranch(at: url) }
                }
            }
        }
        TextField("Base branch (auto-detected)", text: $baseBranch)
    }

    @ViewBuilder private var cloneFromURLFields: some View {
        TextField("Remote URL (git@… or https://…)", text: $remoteURL)
            .font(.system(.body, design: .monospaced))
        HStack {
            TextField("Destination folder", text: .constant(destinationParent?.path ?? ""))
                .disabled(true)
            Button("Choose parent…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK { destinationParent = panel.url }
            }
        }
        // The exact directory the clone will land in — no surprises.
        if let resolved = resolvedDestination {
            Text("Clones into \(resolved)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } else {
            Text("The base branch is auto-detected from the clone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var registerButton: some View {
        Button(working ? "Checking…" : "Register") {
            working = true
            Task {
                do {
                    _ = try await runtime.model.registerRepo(
                        path: URL(fileURLWithPath: path, isDirectory: true),
                        baseBranch: baseBranch,
                        setupScript: setupScript.isEmpty ? nil : setupScript,
                        envCopyList: envEntries)
                    dismiss()
                } catch {
                    runtime.lastError = describeRegistration(error)
                }
                working = false
            }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(working || path.isEmpty || baseBranch.isEmpty)
    }

    @ViewBuilder private var cloneButton: some View {
        Button(working ? "Cloning…" : "Clone & Register") {
            guard let parent = destinationParent else { return }
            working = true
            Task {
                do {
                    _ = try await runtime.model.cloneAndRegister(
                        remoteURL: remoteURL,
                        destinationParent: parent,
                        setupScript: setupScript.isEmpty ? nil : setupScript,
                        envCopyList: envEntries)
                    dismiss()
                } catch {
                    runtime.lastError = describeRegistration(error)
                }
                working = false
            }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(working || remoteURL.isEmpty || destinationParent == nil)
    }

    /// The full path the clone will occupy, once a URL and parent are both
    /// known — mirrors `AppModel.cloneAndRegister`'s naming so the preview never
    /// disagrees with where the clone actually lands.
    private var resolvedDestination: String? {
        guard let parent = destinationParent,
              let name = AppModel.repoName(fromURL: remoteURL) else { return nil }
        return parent.appendingPathComponent(name, isDirectory: true).path
    }

    private var envEntries: [String]? {
        let entries = envCopyList.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return entries.isEmpty ? nil : entries
    }

    private func describeRegistration(_ error: any Error) -> String {
        if let clone = error as? RepoCloneError {
            switch clone {
            case .launchFailed(let reason):
                return "Could not launch git to clone: \(reason)"
            case .cloneFailed(let stderr):
                // git's own words — likely auth (try SSH or cache a credential)
                // or a bad URL. Reported verbatim rather than paraphrased.
                return "Clone failed:\n\(stderr)"
            }
        }
        guard let error = error as? RepoRegistrationError else {
            return String(describing: error)
        }
        switch error {
        case .pathDoesNotExist(let path):
            return "\(path) does not exist."
        case .notAGitRepository(let path):
            return "\(path) is not inside a git repository."
        case .notTheRepositoryRoot(let path, let actualRoot):
            return "\(path) is inside a repo whose root is \(actualRoot) — register the root."
        case .alreadyRegistered(let path):
            return "\(path) is already registered."
        case .invalidBaseBranchName(let baseBranch):
            return "'\(baseBranch)' is not a valid git branch name."
        case .baseBranchMissing(let path, let baseBranch):
            return "Branch '\(baseBranch)' does not exist in \(path)."
        case .invalidRemoteURL(let url):
            return "'\(url)' is not a usable git remote URL."
        case .destinationExists(let path):
            return "\(path) already exists — choose a different folder or remove it first."
        }
    }
}

/// Adds a repo/worktree to an ALREADY-running task so Lighthouse tracks it from
/// now on — three modes matching the engine: a fresh worktree, a registered
/// repo's current checkout (tracked in-place), or an existing worktree the agent
/// created (adopted). The task's running session is untouched; this only extends
/// what the review pane, merge, and removal cover.
struct AddToTaskSheet: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    let task: TaskRecord

    private enum Mode: Hashable { case newWorktree, trackInPlace, adopt }
    @State private var mode: Mode = .newWorktree
    @State private var selectedRepoId: UUID?
    @State private var branch = ""
    @State private var adoptDir: URL?
    @State private var working = false

    /// Re-fetched live so the addable list reflects a workspace added moments
    /// ago (the passed-in `task` is a snapshot from when the sheet opened).
    private var liveTask: TaskRecord {
        runtime.model.tasks.first(where: { $0.id == task.id }) ?? task
    }
    private var addableRepos: [RepoConfig] { runtime.model.reposAddableTo(liveTask) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to “\(task.name)”").font(.headline)

            Picker("Mode", selection: $mode) {
                Text("New worktree").tag(Mode.newWorktree)
                Text("Track current dir").tag(Mode.trackInPlace)
                Text("Adopt a worktree").tag(Mode.adopt)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .newWorktree, .trackInPlace: repoFields
            case .adopt: adoptFields
            }

            Text(modeHelp)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if !working, !missingRequirements.isEmpty {
                    Text("Add \(ListFormatter.localizedString(byJoining: missingRequirements)) to continue.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(working ? "Adding…" : "Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || !missingRequirements.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { if branch.isEmpty { branch = task.branch } }
    }

    @ViewBuilder private var repoFields: some View {
        if addableRepos.isEmpty {
            Text("Every registered repo is already tracked by this task.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Picker("Repo", selection: $selectedRepoId) {
                Text("Choose a repo…").tag(UUID?.none)
                ForEach(addableRepos) { repo in
                    Text(repo.pathURL.lastPathComponent).tag(UUID?.some(repo.id))
                }
            }
            .labelsHidden()
        }
        if mode == .newWorktree {
            TextField("Branch", text: $branch)
                .font(.system(.body, design: .monospaced))
        }
    }

    @ViewBuilder private var adoptFields: some View {
        HStack {
            TextField("Worktree directory", text: .constant(adoptDir?.path ?? ""))
                .disabled(true)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK { adoptDir = panel.url }
            }
        }
    }

    private var modeHelp: String {
        switch mode {
        case .newWorktree:
            return "Creates a fresh worktree on this branch, cut from the repo's base — for also working on another repo in this task. Merges back like the rest."
        case .trackInPlace:
            return "Tracks the repo's current checkout as-is — whatever the agent already changed there. Reviewed, but never merged back or deleted on removal."
        case .adopt:
            return "Adopts an existing worktree the agent created. Matched to a registered repo and tracked — never merged back or deleted."
        }
    }

    private var missingRequirements: [String] {
        switch mode {
        case .newWorktree:
            var missing: [String] = []
            if selectedRepoId == nil { missing.append("a repo") }
            if branch.isEmpty { missing.append("a branch name") }
            return missing
        case .trackInPlace:
            return selectedRepoId == nil ? ["a repo"] : []
        case .adopt:
            return adoptDir == nil ? ["a directory"] : []
        }
    }

    private func add() {
        working = true
        Task {
            do {
                let workspace: Workspace
                switch mode {
                case .newWorktree:
                    workspace = try await runtime.model.addWorktree(
                        toTask: task.id, repoId: selectedRepoId!, branch: branch)
                case .trackInPlace:
                    workspace = try await runtime.model.trackInPlace(
                        toTask: task.id, repoId: selectedRepoId!)
                case .adopt:
                    workspace = try await runtime.model.adoptWorktree(
                        toTask: task.id, directory: adoptDir!)
                }
                await runtime.superviseNewWorkspace(workspace, taskId: task.id)
                dismiss()
            } catch let error as TaskEngineError {
                runtime.lastError = FailureDescriber.describe(error)
            } catch {
                runtime.lastError = String(describing: error)
            }
            working = false
        }
    }
}
