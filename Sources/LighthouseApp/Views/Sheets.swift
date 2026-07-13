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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Task").font(.headline)
            TextField("Name (e.g. payments fix)", text: $name)
                .onChange(of: name) {
                    if !branchEdited { branch = AppModel.branchSlug(from: name) }
                }
            TextField("Branch", text: $branch)
                .onChange(of: branch) { _, new in
                    branchEdited = new != AppModel.branchSlug(from: name)
                }
                .font(.system(.body, design: .monospaced))

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

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(creating ? "Creating…" : "Create & Start Session") {
                    creating = true
                    Task {
                        await runtime.createTaskAndStartSession(
                            name: name, branch: branch, repoIds: selectedRepoIds)
                        creating = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(creating || name.isEmpty || branch.isEmpty || selectedRepoIds.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Guardrail 1 UI: destroying unmerged work lists the exact (repo, branch)
/// pairs and requires typing the task name — the typed confirmation VALUE
/// (UnmergedDestructionConfirmation) is only constructed after that.
struct RemoveTaskSheet: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    let task: TaskRecord

    @State private var unmerged: [UnmergedWorkItem]?
    @State private var typedName = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove \(task.name)").font(.headline)
            if let unmerged {
                if unmerged.isEmpty {
                    Text("All workspaces are merged into their base branches. Worktrees and branches will be removed.")
                    removalButtons(mode: .refuseIfUnmerged, label: "Remove Task")
                } else {
                    Label("This will DESTROY unmerged work:", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    ForEach(unmerged, id: \.self) { item in
                        Text("• \(item.repoPath) — branch '\(item.branch)'")
                            .font(.system(.caption, design: .monospaced))
                    }
                    TextField("Type the task name to confirm", text: $typedName)
                    removalButtons(
                        mode: .destroyUnmergedWork(
                            UnmergedDestructionConfirmation(destroying: unmerged)),
                        label: "Destroy Unmerged Work",
                        enabled: typedName == task.name)
                }
            } else {
                ProgressView("Checking for unmerged work…")
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            do {
                unmerged = try await runtime.model.unmergedWork(for: task)
            } catch {
                runtime.lastError = String(describing: error)
                dismiss()
            }
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
                    }
                }
            }
            TextField("Base branch", text: $baseBranch)
            TextField("Setup script (optional, relative to repo)", text: $setupScript)
            TextField("Env files to copy (optional, comma-separated)", text: $envCopyList)
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
