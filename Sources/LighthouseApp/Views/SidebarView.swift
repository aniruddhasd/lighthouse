import SwiftUI
import LighthouseAppCore
import LighthouseTaskEngine

struct SidebarView: View {
    @Environment(AppRuntime.self) private var runtime
    @Binding var showCreateTask: Bool
    @Binding var showRegisterRepo: Bool
    @Binding var taskPendingRemoval: TaskRecord?

    var body: some View {
        @Bindable var runtime = runtime
        List(selection: $runtime.selectedTaskId) {
            Section("Tasks") {
                ForEach(runtime.model.tasks) { task in
                    TaskRow(task: task)
                        .tag(task.id)
                        .contextMenu {
                            if runtime.model.canResume(task) {
                                Button("Resume Session") { runtime.resumeSession(for: task) }
                            }
                            Button("Remove Task…", role: .destructive) {
                                taskPendingRemoval = task
                            }
                        }
                }
            }
            Section("Repos") {
                ForEach(runtime.model.repos) { repo in
                    VStack(alignment: .leading) {
                        Text(repo.pathURL.lastPathComponent)
                        Text("\(repo.baseBranch) · \(repo.path)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .contextMenu {
                        Button("Remove Repo", role: .destructive) {
                            do {
                                try runtime.model.removeRepo(id: repo.id)
                            } catch let error as RepoRemovalError {
                                runtime.lastError = describe(error)
                            } catch {
                                runtime.lastError = String(describing: error)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Lighthouse")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New Task…") { showCreateTask = true }
                        .disabled(runtime.model.repos.isEmpty)
                    Button("Register Repo…") { showRegisterRepo = true }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
    }

    private func describe(_ error: RepoRemovalError) -> String {
        switch error {
        case .usedByTasks(_, let names):
            return "This repo is used by: \(names.joined(separator: ", ")). Remove those tasks first."
        case .unknownRepo:
            return "Repo is no longer registered."
        }
    }
}

struct TaskRow: View {
    @Environment(AppRuntime.self) private var runtime
    let task: TaskRecord

    var body: some View {
        HStack {
            AttentionBadge(state: runtime.model.attentionState(of: task.id))
            VStack(alignment: .leading) {
                Text(task.name)
                Text(task.branch)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The ambient signal the whole app exists for (spec §1 problem 2).
struct AttentionBadge: View {
    let state: TaskAttentionState

    var body: some View {
        switch state {
        case .working:
            ProgressView()
                .controlSize(.small)
                .help("Agent is working")
        case .needsInput:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .help("Needs your input")
        case .done:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
                .help("Idle — nothing pending")
        case .dirty:
            Image(systemName: "circle.dotted.circle")
                .foregroundStyle(.yellow)
                .help("Unaccounted-for changes (session died or edits with no agent)")
        }
    }
}
