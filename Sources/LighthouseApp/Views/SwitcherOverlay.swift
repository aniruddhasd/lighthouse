import SwiftUI
import LighthouseAppCore
import LighthouseTaskEngine

/// Cmd+K command palette (handoff §3): fuzzy task switcher that doubles as the
/// attention inbox — needs-input tasks always sort first (AppModel.switcherEntries,
/// which uses InboxOrder; it ignores the Harbor filter chip, always the full
/// list). Restyled to the palette panel with theme tokens; the logic is
/// unchanged. Selecting a row opens that task in Focus (`runtime.open`).
struct SwitcherOverlay: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.theme) private var theme
    @Environment(\.motionEnabled) private var motionEnabled
    @State private var query = ""
    @State private var popped = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let entries = runtime.model.switcherEntries(query: query)
        // Scrim (rgba(6,8,13,.5)-equivalent) + blur, panel pinned ~11vh down.
        ZStack(alignment: .top) {
            Color(hex: 0x06080d, opacity: 0.5)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }
            panel(entries: entries)
                .frame(width: 620)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.palette))
                .background(theme.panel.opacity(0.92),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.palette))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.palette)
                    .strokeBorder(theme.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 40, y: 24)
                // pop (~.16s scale+opacity) on appear, reduce-motion gated:
                // instant final state when motion is off. Only the panel pops;
                // the scrim is immediate.
                .scaleEffect(motionEnabled ? (popped ? 1 : 0.96) : 1)
                .opacity(motionEnabled ? (popped ? 1 : 0) : 1)
                .padding(.top, 90)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            fieldFocused = true
            if motionEnabled {
                withAnimation(.easeOut(duration: 0.16)) { popped = true }
            } else {
                popped = true
            }
        }
    }

    @ViewBuilder
    private func panel(entries: [TaskRecord]) -> some View {
        VStack(spacing: 0) {
            searchField
            if runtime.notificationsHintVisible { notificationsHint }
            Divider().overlay(theme.borderSoft)
            if entries.isEmpty {
                Text("No matching tasks")
                    .font(LHFont.body)
                    .foregroundStyle(theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                results(entries)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.dim)
            TextField("Jump to task…", text: $query)
                .textFieldStyle(.plain)
                .font(LHFont.ui(15))
                .foregroundStyle(theme.text)
                .focused($fieldFocused)
                .onSubmit { if let first = runtime.model.switcherEntries(query: query).first { select(first.id) } }
                .onExitCommand { dismiss() }
            Keycap(text: "esc")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var notificationsHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "bell.slash").foregroundStyle(theme.dim)
            Text("Notifications are off — badges still work. Enable them in setup.")
                .font(LHFont.metaFaint)
                .foregroundStyle(theme.dim)
            Spacer()
            Button("Dismiss") { runtime.dismissNotificationsHint() }
                .buttonStyle(.plain)
                .font(LHFont.metaFaint)
                .foregroundStyle(theme.primary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(theme.panel2)
    }

    private func results(_ entries: [TaskRecord]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                Text("NEEDS YOU FIRST")
                    .font(LHFont.mono(10.5, .semibold))
                    .tracking(0.6)
                    .foregroundStyle(theme.faint)
                    .padding(.horizontal, 16)
                    .padding(.top, 10).padding(.bottom, 4)
                ForEach(entries) { task in
                    row(task)
                }
            }
            .padding(.bottom, 8)
        }
        .frame(maxHeight: 360)
    }

    private func row(_ task: TaskRecord) -> some View {
        let state = runtime.model.attentionState(of: task.id)
        return Button { select(task.id) } label: {
            HStack(spacing: 10) {
                StatusDot(state: state, glow: state == .needsInput)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name)
                        .font(LHFont.ui(13.5, .medium))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Text(task.branch)
                        .font(LHFont.meta)
                        .foregroundStyle(theme.faint)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                StatusPill(state: state)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    /// Selecting a result opens that task in Focus (spec §3.4 / handoff §3):
    /// `runtime.open` sets the selection, closes the palette, and flips the
    /// view. Works identically from Harbor or Focus.
    private func select(_ taskId: UUID) {
        runtime.open(taskId)
    }

    private func dismiss() {
        runtime.switcherPresented = false
    }
}
