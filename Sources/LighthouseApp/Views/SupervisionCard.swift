import SwiftUI
import LighthouseAdapter
import LighthouseAppCore
import LighthouseTaskEngine

/// Orchestrator phase 1a (docs/orchestrator-design.md): the per-task opt-in and
/// a live view of the hook events the agent reported. OBSERVATION ONLY — nothing
/// here acts on an event. The point of the list is to compare it, event by
/// event, with what the terminal actually did, so each row keeps its attribution
/// (primary session / another session in this tile / unattributed) visible.
///
/// Every string in an event is untrusted agent text: rendered as plain `Text`
/// with line limits, never interpreted.
struct SupervisionCard: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.theme) private var theme
    let task: TaskRecord

    /// Rows whose full message is open. A long `Stop` can hold its question deep
    /// in the text (a 2,486-char one was seen), so the preview can't be the only view.
    @State private var expanded: Set<UUID> = []
    /// Roughly three lines of the card's width; longer messages get a toggle.
    private let previewChars = 200

    /// Events shown (newest first). The full bounded history stays in the log and
    /// in the JSONL file; the card only needs the recent window to compare.
    private let shown = 30

    private var current: TaskRecord { runtime.model.tasks.first { $0.id == task.id } ?? task }
    private var events: [LoggedHookEvent] {
        Array(runtime.hookLog.events(for: task.id).suffix(shown).reversed())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SUPERVISION").font(LHFont.metaFaint).foregroundStyle(theme.faint)
                Spacer()
                Toggle("Observe hook events", isOn: Binding(
                    get: { current.supervised },
                    set: { on in Task { await runtime.setSupervised(on, for: current) } }))
                    .toggleStyle(.switch).controlSize(.small)
            }
            Text("Observation only — nothing acts on these events. In testing, a session that was already running began reporting once this was switched on (it just misses its own SessionStart).")
                .font(LHFont.metaFaint).foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            if current.supervised {
                if let error = runtime.hookLog.persistenceError {
                    Text("Event file not writable: \(error)")
                        .font(LHFont.metaFaint).foregroundStyle(theme.dim)
                }
                if runtime.hookLog.droppedCount > 0 {
                    Text("\(runtime.hookLog.droppedCount) delivery(s) dropped by the socket"
                         + (runtime.hookLog.lastDropReason.map { " — last: \($0)" } ?? ""))
                        .font(LHFont.metaFaint).foregroundStyle(theme.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if events.isEmpty {
                    Text("No events yet.").font(LHFont.meta).foregroundStyle(theme.dim)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(events) { row($0) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .background(theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(theme.border, lineWidth: 1))
    }

    private func row(_ logged: LoggedHookEvent) -> some View {
        let e = logged.event
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(e.receivedAt, format: .dateTime.hour().minute().second())
                    .font(LHFont.meta).foregroundStyle(theme.faint)
                Text(label(e)).font(LHFont.mono(12, .medium)).foregroundStyle(theme.text)
                Text(attributionText(logged, e))
                    .font(LHFont.pill)
                    .foregroundStyle(logged.attribution == .primary ? theme.dim : theme.primary)
            }
            if let message = e.lastAssistantMessage {
                let open = expanded.contains(logged.id)
                Text(message)
                    .font(LHFont.secondary).foregroundStyle(theme.dim)
                    .lineLimit(open ? nil : 3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if message.count > previewChars {
                    Button(open ? "Show less" : "Show all \(message.count) characters") {
                        if open { expanded.remove(logged.id) } else { expanded.insert(logged.id) }
                    }
                    .buttonStyle(.plain).font(LHFont.metaFaint).foregroundStyle(theme.primary)
                }
            }
        }
    }

    /// A readable state per event: failures, "waiting on you" and "unblocked"
    /// read as states; everything else shows its event name plus any qualifier.
    private func label(_ e: HookEvent) -> String {
        switch e.eventName {
        case "StopFailure":
            return "StopFailure · failed" + (e.error.map { " (\($0))" } ?? "")
        case "PermissionRequest":
            return "PermissionRequest · waiting on you" + (e.toolName.map { " (\($0))" } ?? "")
        case "PostToolUse":
            return "PostToolUse · unblocked" + (e.toolName.map { " (\($0))" } ?? "")
        default:
            return [e.eventName, e.source, e.notificationType, e.endReason]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// `primary` is the quiet case; everything else is flagged because mismatched
    /// attribution is exactly what phase 1a exists to catch.
    private func attributionText(_ logged: LoggedHookEvent, _ e: HookEvent) -> String {
        var text: String
        switch logged.attribution {
        case .primary: text = "primary"
        case .otherSessionInTask: text = "OTHER SESSION \(e.sessionId.prefix(8))"
        case .unattributed: text = "UNATTRIBUTED"
        }
        // Anything with an agent_id is a subagent's stop, NOT the agent's turn
        // ending — observed live as unprompted helper output (suggestions,
        // recaps). Flagged so it is never mistaken for a turn boundary.
        if let agent = e.agentId {
            let kind = (e.agentType?.isEmpty == false) ? " \(e.agentType!)" : ""
            text += " · subagent\(kind) \(agent.prefix(8)) · not a turn"
        }
        return text
    }
}
