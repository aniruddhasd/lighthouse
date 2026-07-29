import SwiftUI
import LighthouseAppCore

/// First-run setup (spec §6 step 7): prerequisite checks, notification
/// permission in context, the hook self-test, and first-repo guidance.
/// Auto-opens when no repos exist; re-runnable from Help → Run Setup Checks.
struct SetupView: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    @State private var setup: SetupModel?
    @State private var showRegisterRepo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lighthouse setup").font(.title2.bold())
            Text("A one-time check that everything Lighthouse needs is in place. Re-run any time from Help → Run Setup Checks.")
                .font(.callout).foregroundStyle(.secondary)

            checksSection
            repoSection

            Spacer(minLength: 0)
            HStack {
                Button("Re-run checks") { Task { await setup?.runChecks() } }
                    .disabled(setup?.running ?? false)
                Spacer()
                Button("Done") { runtime.finishSetup(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 620)
        .task {
            let model = runtime.makeSetupModel()
            setup = model
            await model.runChecks()
        }
        .sheet(isPresented: $showRegisterRepo) { RegisterRepoSheet() }
    }

    @ViewBuilder
    private var checksSection: some View {
        GroupBox("Prerequisites") {
            if let setup, !setup.checks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(setup.checks) { check in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: icon(check.status))
                                .foregroundStyle(color(check.status))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(check.title).font(.callout.weight(.medium))
                                Text(check.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            } else {
                ProgressView("Running checks…").padding(4)
            }
        }
    }

    @ViewBuilder
    private var repoSection: some View {
        GroupBox("Your first repo") {
            HStack {
                if runtime.model.repos.isEmpty {
                    Text("Register a local clone to begin — Lighthouse auto-detects its base branch.")
                        .font(.callout)
                    Spacer()
                    Button("Register Repo…") { showRegisterRepo = true }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(runtime.model.repos.count) repo(s) registered.").font(.callout)
                        Text("Now use the + menu → New Task to create your first task.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Register another…") { showRegisterRepo = true }
                }
            }
            .padding(4)
        }
    }

    private func icon(_ s: CheckResult.Status) -> String {
        switch s {
        case .pass: return "checkmark.circle.fill"
        case .fail: return "xmark.octagon.fill"
        case .warn: return "exclamationmark.triangle.fill"
        }
    }
    private func color(_ s: CheckResult.Status) -> Color {
        switch s {
        case .pass: return .green
        case .fail: return .red
        case .warn: return .orange
        }
    }
}
