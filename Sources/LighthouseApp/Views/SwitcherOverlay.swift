import SwiftUI
import LighthouseAppCore

/// Cmd+K: fuzzy task switcher that doubles as the attention inbox —
/// needs-input tasks always sort first (AppModel.switcherEntries).
struct SwitcherOverlay: View {
    @Environment(AppRuntime.self) private var runtime
    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let entries = runtime.model.switcherEntries(query: query)
        VStack(spacing: 0) {
            TextField("Jump to task…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($fieldFocused)
                .onSubmit {
                    if let first = entries.first { select(first.id) }
                }
                .onExitCommand { dismiss() }
            if runtime.notificationsHintVisible {
                HStack(spacing: 6) {
                    Image(systemName: "bell.slash")
                    Text("Notifications are off — badges still work. Enable them in setup.")
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") { runtime.dismissNotificationsHint() }
                        .buttonStyle(.plain).font(.caption)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.quaternary)
            }
            Divider()
            if entries.isEmpty {
                Text("No matching tasks")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { task in
                            Button {
                                select(task.id)
                            } label: {
                                HStack {
                                    AttentionBadge(state: runtime.model.attentionState(of: task.id))
                                    Text(task.name)
                                    Spacer()
                                    Text(task.branch)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 24)
        .padding(.top, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            Color.black.opacity(0.2)
                .onTapGesture { dismiss() })
        .onAppear { fieldFocused = true }
    }

    private func select(_ taskId: UUID) {
        runtime.selectedTaskId = taskId
        dismiss()
    }

    private func dismiss() {
        runtime.switcherPresented = false
    }
}
