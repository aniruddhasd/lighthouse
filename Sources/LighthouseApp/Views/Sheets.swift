import SwiftUI
import LighthouseAppCore
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
    /// Where the session runs. Worktree (default) branches off base into an
    /// isolated worktree; in-place runs in the repo's own checkout for
    /// investigation — no worktree, no branch, nothing to merge back.
    @State private var inPlace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Task").font(.headline)
            TextField("Name (e.g. payments fix)", text: $name)
                .onChange(of: name) {
                    if !branchEdited { branch = AppModel.branchSlug(from: name) }
                }

            Picker("Workspace", selection: $inPlace) {
                Text("New worktree").tag(false)
                Text("Current directory").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if inPlace {
                Text("Runs the session in each repo's own checkout — no worktree, no branch. For investigating or learning a repo without changing it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                TextField("Branch", text: $branch)
                    .onChange(of: branch) { _, new in
                        branchEdited = new != AppModel.branchSlug(from: name)
                    }
                    .font(.system(.body, design: .monospaced))
            }

            Text("Repos (selection order = creation order)")
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
                    Text("Add \(Self.humanList(missingRequirements)) to continue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(creating ? "Creating…" : "Create & Start Session") {
                    creating = true
                    Task {
                        await runtime.createTaskAndStartSession(
                            name: name, branch: branch, repoIds: selectedRepoIds,
                            inPlace: inPlace)
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
        if name.isEmpty { missing.append("a task name") }
        if !inPlace && branch.isEmpty { missing.append("a branch name") }
        if selectedRepoIds.isEmpty { missing.append("a repo") }
        return missing
    }

    /// Joins fragments into natural English: "a", "a and b", "a, b, and c".
    private static func humanList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
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

struct RegisterRepoSheet: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var baseBranch = "main"
    @State private var setupScript = ""
    @State private var envCopyList = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Register Repo").font(.headline)
            HStack {
                TextField("Path to local clone", text: $path)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url {
                        path = url.path
                        // Auto-detect the base branch from the clone's HEAD.
                        Task {
                            baseBranch = await runtime.model.suggestBaseBranch(at: url)
                        }
                    }
                }
            }
            TextField("Base branch (auto-detected)", text: $baseBranch)
            DisclosureGroup("Advanced (optional)") {
                TextField("Setup script (relative to repo)", text: $setupScript)
                TextField("Env files to copy (comma-separated)", text: $envCopyList)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
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
        }
        .padding(20)
        .frame(width: 460)
    }

    private var envEntries: [String]? {
        let entries = envCopyList.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return entries.isEmpty ? nil : entries
    }

    private func describeRegistration(_ error: any Error) -> String {
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
        }
    }
}
