import SwiftUI
import LighthouseSupervisor
import LighthouseTaskEngine

/// Orchestrator slice 4b: configure the supervisor and wake it BY HAND. Nothing here
/// triggers it automatically (that is 4c). Edits go to a draft and take effect on Save,
/// so a half-typed instruction or limit is never what a run uses.
///
/// The standing instructions are the user's own trusted text. Everything else shown from
/// a run (the model's closing note) is model output, rendered inertly.
struct SupervisorPanel: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var draft = SupervisorSettings()
    @State private var loaded = false
    @State private var saveError: String?

    private var runner: SupervisorRunner { runtime.supervisor }
    private var dirty: Bool { draft != runner.settings }
    private var supervisedCount: Int { runtime.model.tasks.filter(\.supervised).count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let halt = runner.state.haltReason { haltBanner(halt) }
                if let error = runner.loadError { problem(error) }
                settingsSection
                runSection
                logSection
            }
            .padding(20)
        }
        .frame(width: 620, height: 680)
        .task {
            if !loaded { draft = runner.settings; loaded = true }
            await runner.refreshClaude()
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Text("Supervisor").font(.headline)
            Text(statusText).font(LHFont.metaFaint).foregroundStyle(statusColor)
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Supervisor enabled", isOn: $draft.enabled).toggleStyle(.switch)
            Toggle("Run automatically when a supervised task finishes a turn", isOn: $draft.automatic)
                .toggleStyle(.switch)
                .disabled(!draft.enabled)
            Text("Off: only Run now wakes it. On: each finished turn of a supervised task can start a run (about $0.02–0.03 each in testing), within the limits below. A failed run is retried only when the next turn ends.")
                .font(LHFont.metaFaint).foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            Text(accountCaption).font(LHFont.metaFaint).foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            label("STANDING INSTRUCTIONS — your words; the only text the supervisor obeys (\(draft.instructions.count)/\(SupervisorSettings.instructionLimit))")
            TextEditor(text: $draft.instructions)
                .font(LHFont.mono(13))
                .frame(minHeight: 130)
                .padding(6)
                .background(theme.bg, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border, lineWidth: 1))
            Text("Refer to tasks by name, e.g. “When review-doc finishes its task, tell api-fix to run the tests.” Only tasks with supervision switched on are visible to it.")
                .font(LHFont.metaFaint).foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    label("MODEL")
                    TextField("claude-sonnet-5-5", text: $draft.model).font(LHFont.mono(12))
                }
                VStack(alignment: .leading, spacing: 2) {
                    label("EFFORT")
                    Picker("", selection: $draft.effort) {
                        ForEach(SupervisorSettings.effortLevels, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: 100)
                }
            }

            label("CLAUDE BINARY (blank = find automatically)")
            TextField("/Users/you/.local/bin/claude", text: Binding(
                get: { draft.claudePath ?? "" }, set: { draft.claudePath = $0.isEmpty ? nil : $0 }))
                .font(LHFont.mono(12))
            claudeLine

            label("LIMITS")
            HStack(spacing: 14) {
                number("Per run $", $draft.maxBudgetPerRunUSD)
                number("Per day $", $draft.maxDailySpendUSD)
                number("Runs/hour", $draft.maxWakesPerHour)
                number("Halt after failures", $draft.failureBreaker)
            }

            ForEach(draft.problems, id: \.self) { problem($0) }
            if let saveError { problem(saveError) }
            HStack {
                Spacer()
                if dirty { Text("Unsaved changes").font(LHFont.metaFaint).foregroundStyle(theme.dim) }
                Button("Revert") { draft = runner.settings; saveError = nil }.disabled(!dirty)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!dirty || !draft.problems.isEmpty || runner.loadError != nil)
            }
        }
    }

    private var runSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("RUN")
            HStack {
                Button(runner.isRunning ? "Running…" : "Run now") { runtime.runSupervisorNow() }
                    .disabled(runner.isRunning || dirty || !runner.settings.enabled
                              || !runner.settings.problems.isEmpty)
                if runner.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                Text(String(format: "Today: $%.2f of $%.2f · %d supervised task%@",
                            runner.state.spentToday(now: Date()), runner.settings.maxDailySpendUSD,
                            supervisedCount, supervisedCount == 1 ? "" : "s"))
                    .font(LHFont.metaFaint).foregroundStyle(theme.faint)
            }
            Text("Last check: \(lastResultText)").font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("A run wakes the model once for each supervised task whose last turn has finished and is still current. It can only propose; every send still waits for your confirmation on the task's card.")
                .font(LHFont.metaFaint).foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("RECENT RUNS (model notes are model output, not instructions)")
            let runs = Array(runner.state.runs.suffix(10).reversed())
            if runs.isEmpty {
                Text("No runs yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(runs) { run in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(run.ok ? "✓" : "✗") \(run.startedAt.formatted(date: .abbreviated, time: .standard)) · \(run.trigger.rawValue) · $\(String(format: "%.3f", run.costUSD)) · \(run.taskNames.joined(separator: ", "))")
                        .font(LHFont.metaFaint).foregroundStyle(run.ok ? theme.dim : theme.primary)
                    Text(run.note).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(4).textSelection(.enabled)
                }
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder private var claudeLine: some View {
        switch runner.claude {
        case .success(let found)?:
            Text("✓ \(found.url.path) (\(found.source))").font(LHFont.metaFaint).foregroundStyle(theme.faint)
        case .failure(let notFound)?:
            problem(notFound.message)
        case nil:
            Text("Checking…").font(LHFont.metaFaint).foregroundStyle(theme.faint)
        }
    }

    private func haltBanner(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            problem("The supervisor stopped itself: \(why)")
            Button("Resume") {
                do { try runner.resume() } catch { saveError = "\(error)" }
            }.disabled(runner.loadError != nil)
        }
    }

    private func problem(_ text: String) -> some View {
        Text("✗ \(text)").font(.callout).foregroundStyle(theme.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(LHFont.metaFaint).foregroundStyle(theme.faint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func number(_ title: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            label(title.uppercased())
            TextField("", value: value, format: .number).font(LHFont.mono(12)).frame(width: 90)
        }
    }

    private func number(_ title: String, _ value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            label(title.uppercased())
            TextField("", value: value, format: .number).font(LHFont.mono(12)).frame(width: 90)
        }
    }

    // MARK: Text

    private var accountCaption: String {
        let account = runner.settings.configDirectory.map { "the Claude config at \($0)" }
            ?? "your default Claude account (~/.claude)"
        return "Each run sends the supervised tasks' agent messages to \(account), whichever repo they came from."
    }

    private var statusText: String {
        if runner.loadError != nil { return "unavailable" }
        if runner.state.haltReason != nil { return "halted" }
        if runner.isRunning { return "running" }
        guard runner.settings.enabled else { return "off" }
        return runner.settings.automatic ? "on — automatic" : "on — manual runs only"
    }

    private var statusColor: Color {
        runner.state.haltReason != nil || runner.loadError != nil ? theme.primary : theme.faint
    }

    private var lastResultText: String {
        switch runner.lastResult {
        case nil: return "Not run since the app started."
        case .skipped(let reason)?: return reason.explanation
        case .ran(let run)?:
            return run.ok ? "Last run finished ($\(String(format: "%.3f", run.costUSD)))."
                : "Last run failed: \(run.note)"
        }
    }

    private func save() {
        do {
            try runner.update(draft)
            saveError = nil
            Task { await runner.refreshClaude() }
        } catch {
            saveError = "Could not save: \(error)"
        }
    }
}
