import SwiftUI
import LighthouseAdapter
import LighthouseAppCore
import LighthouseSupervisor
import LighthouseTaskEngine

/// Orchestrator slice 3a: the user reviews a supervisor-proposed message and confirms it.
/// Confirming TYPES the text into the task's Claude prompt box and takes the user there —
/// it does NOT submit; the user reads it in place and presses Enter (docs §13).
///
/// The gate runs live (every second) and AGAIN on click inside `confirm`, so the sheet's
/// checklist is advisory and never the thing authorising the send. Everything shown from
/// an agent or the supervisor is untrusted text rendered inertly.
struct ReviewSendSheet: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let task: TaskRecord
    let proposalId: UUID

    @State private var verdict: GateResult?
    @State private var outcomeMessage: String?

    private var proposal: Proposal? { runtime.proposals.queue.entries.first { $0.id == proposalId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review message for “\(task.name)”").font(.headline)
            if let proposal {
                content(proposal)
            } else {
                Text("This proposal no longer exists.").foregroundStyle(.secondary)
            }
            if let outcomeMessage {
                Text(outcomeMessage).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(outcomeMessage == nil ? "Cancel" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if outcomeMessage == nil, let proposal {
                    Button("Type into terminal") { send(proposal) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!(verdict?.allowed ?? false))
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .task(id: proposalId) {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder private func content(_ p: Proposal) -> some View {
        Text("This will be typed into the prompt box of the task's terminal. It will not be submitted — you read it there and press Enter.")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        label("MESSAGE (\(p.text.count) characters)")
        Text(p.text)
            .font(LHFont.mono(13)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(theme.bg, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border, lineWidth: 1))

        label("WHY THE SUPERVISOR PROPOSED IT")
        Text(p.reason).font(.callout).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)

        label("THE AGENT'S MESSAGE IT WAS BASED ON — untrusted text, shown as data")
        ScrollView {
            Text(basedOnMessage(p) ?? "The turn this was based on is not in the log.")
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 140)
        .padding(8)
        .background(theme.bg, in: RoundedRectangle(cornerRadius: 6))

        checklist
    }

    @ViewBuilder private var checklist: some View {
        label("CHECKS (re-run when you click)")
        if let verdict {
            if verdict.allowed {
                Text("✓ Ready: the agent has not moved on, the terminal is idle for you, and the rate limit is fine.")
                    .font(.callout)
            }
            ForEach(Array(verdict.refusals.enumerated()), id: \.offset) { _, r in
                Text("✗ \(r.description)").font(.callout).foregroundStyle(theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(verdict.warnings, id: \.self) { w in
                Text("! \(w)").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let why = verdict.expireReason {
                Text("This proposal is out of date and will be retired.\n\(why)")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            Text("Checking…").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(LHFont.metaFaint).foregroundStyle(theme.faint)
    }

    /// The full message of the turn this proposal named, from the live event log.
    private func basedOnMessage(_ p: Proposal) -> String? {
        guard let basedOn = p.basedOn else { return nil }
        let second = Int(basedOn.timeIntervalSince1970)
        return runtime.hookLog.events(for: task.id).last {
            $0.attribution == .primary && $0.event.agentId == nil
                && ($0.event.eventName == "Stop" || $0.event.eventName == "StopFailure")
                && Int($0.event.receivedAt.timeIntervalSince1970) == second
        }?.event.lastAssistantMessage
    }

    private func refresh() {
        guard let proposal else { return }
        verdict = runtime.deliveryVerdict(for: proposal, task: task)
    }

    private func send(_ proposal: Proposal) {
        switch runtime.confirmProposal(proposal, task: task) {
        case .sent:
            dismiss() // the app has navigated to the terminal, where the text awaits Enter
        case .refused(let why):
            outcomeMessage = "Not sent: " + why.map(\.description).joined(separator: " ")
        case .expired(let why):
            outcomeMessage = "Not sent — this proposal is out of date. \(why)"
        case .failed(let why):
            outcomeMessage = "Not delivered: \(why)"
        case .notAvailable(let why):
            outcomeMessage = why
        }
    }
}
