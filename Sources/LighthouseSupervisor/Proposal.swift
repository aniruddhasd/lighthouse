import Foundation
import LighthouseTaskEngine

public enum ProposalKind: String, Codable, Sendable, Equatable {
    /// A message to type into the task's agent session (acted on in slice 3, only
    /// after a human confirms).
    case send
    /// The supervisor judges the task blocked or failed: do not advance. A note.
    case hold
    /// A question for the user.
    case askUser = "ask_user"
}

public enum ProposalStatus: String, Codable, Sendable, Equatable {
    case pending
    /// The user dismissed it.
    case dismissed
    /// The app refused it at submission (see `rejectionReason`).
    case rejected
    /// A `send` was confirmed and typed into the session (saved BEFORE typing, so a
    /// crash can never type it twice).
    case sent
    /// Overtaken by events (a newer prompt, the session ended, …) before it was acted on.
    case expired
    /// Confirmed, but delivery did not happen (`resolutionNote` says why).
    case failed
}

/// What the supervisor submits. Untrusted input: it crosses a process boundary and
/// is re-validated by the app before it becomes a `Proposal`.
public struct ProposalDraft: Codable, Equatable, Sendable {
    public var kind: ProposalKind
    /// Task id (UUID) or exact name, as for the read tools.
    public var task: String
    /// `send`: the message to type. `hold`: the note. `ask_user`: the question.
    public var text: String
    /// Why — shown to the user next to the proposal.
    public var reason: String
    /// The `ended_at` of the turn this was judged from. Required for `send`, so a
    /// later slice can refuse a proposal made stale by a newer event.
    public var basedOn: Date?
    /// For a `send`: the task whose finished turn `basedOn` names, when it is not the
    /// task being messaged ("when alpha finishes, tell beta": `task` = beta, `sourceTask`
    /// = alpha). Nil or the same task = the turn is the target's own.
    public var sourceTask: String?

    public init(
        kind: ProposalKind, task: String, text: String, reason: String,
        basedOn: Date? = nil, sourceTask: String? = nil
    ) {
        self.kind = kind
        self.task = task
        self.text = text
        self.reason = reason
        self.basedOn = basedOn
        self.sourceTask = sourceTask
    }
}

/// An entry in the app-owned queue.
public struct Proposal: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// nil when the draft named no resolvable supervised task.
    public let taskId: UUID?
    /// The reference as submitted, bounded — for display of a rejection.
    public let taskRef: String
    public let kind: ProposalKind
    public let text: String
    public let reason: String
    public let basedOn: Date?
    public let createdAt: Date
    public var status: ProposalStatus
    public let rejectionReason: String?
    /// When it left `pending` (sent / dismissed / expired / failed).
    public var resolvedAt: Date? = nil
    /// Why it expired or failed.
    public var resolutionNote: String? = nil
    /// The task whose turn this was judged from, when it differs from `taskId`.
    public var sourceTaskId: UUID? = nil
    /// The source reference as submitted, bounded — for display.
    public var sourceTaskRef: String? = nil
}

public struct ProposalRejection: Error, Equatable, Sendable {
    public let reason: String
}

public struct ValidatedProposal: Equatable, Sendable {
    public let taskId: UUID
    /// nil when the draft named no source, or named the target itself.
    public let sourceTaskId: UUID?
    /// Trimmed copy of the draft with the resolved task.
    public let draft: ProposalDraft
}

/// Authoritative validation, run by the app on every submission (the MCP process
/// mirrors it only for fast feedback). Pure.
public enum ProposalValidator {
    public static let maxTextChars = 2_000
    public static let maxReasonChars = 500

    public static func validate(_ draft: ProposalDraft, tasks: [TaskRecord]) throws -> ValidatedProposal {
        let task = try resolve(draft.task, in: tasks)
        var sourceId: UUID?
        if let ref = draft.sourceTask?.trimmingCharacters(in: .whitespaces), !ref.isEmpty {
            guard draft.kind == .send else {
                throw ProposalRejection(reason: "Only a send names a source task.")
            }
            let source = try resolve(ref, in: tasks)
            sourceId = source.id == task.id ? nil : source.id
        }
        return ValidatedProposal(taskId: task.id, sourceTaskId: sourceId, draft: try validateContent(draft))
    }

    /// A lookup failure becomes a rejection the user can read (not a bare "Invalid proposal").
    private static func resolve(_ ref: String, in tasks: [TaskRecord]) throws -> TaskRecord {
        do { return try TaskLookup.resolve(ref, in: tasks) } catch let e as SupervisorToolError {
            throw ProposalRejection(reason: e.message)
        }
    }

    /// Everything about a draft that does not depend on which task it names. Also run
    /// again at delivery time (`DeliveryGate`), because the queue file is same-user-writable.
    public static func validateContent(_ draft: ProposalDraft) throws -> ProposalDraft {
        // Control characters are checked on the RAW strings, before any trimming. A
        // `send` is eventually typed into a pty, where \n submits, ESC opens escape
        // sequences and ^C/^D interrupt or exit; a trailing newline trimmed away here
        // would be a keystroke that never got seen.
        for (label, value) in [("text", draft.text), ("reason", draft.reason)] {
            if containsControl(value) {
                throw ProposalRejection(reason: "The \(label) contains control characters (newlines, tabs, escapes); use plain single-line text.")
            }
        }
        let text = draft.text.trimmingCharacters(in: .whitespaces)
        let reason = draft.reason.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { throw ProposalRejection(reason: "The text is empty.") }
        guard !reason.isEmpty else { throw ProposalRejection(reason: "A reason is required.") }
        guard text.count <= maxTextChars else {
            throw ProposalRejection(reason: "The text is longer than \(maxTextChars) characters.")
        }
        guard reason.count <= maxReasonChars else {
            throw ProposalRejection(reason: "The reason is longer than \(maxReasonChars) characters.")
        }
        if draft.kind == .send {
            if draft.basedOn == nil {
                throw ProposalRejection(reason: "A send proposal must say which turn it is based on (based_on).")
            }
            // Deny by default: the agent's prompt box treats some leading characters as
            // commands (slash commands, shell mode, …) and the exact list is not
            // something to rely on from memory. Only a letter or digit may start a send.
            if let first = text.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first) {
                throw ProposalRejection(reason: "A send must start with a letter or digit (the agent's prompt treats other leading characters as commands).")
            }
        }
        var clean = draft
        clean.text = text
        clean.reason = reason
        return clean
    }

    /// Control characters (Cc: includes \n \r \t ESC DEL and the C1 range) plus the
    /// Unicode line/paragraph separators (Zl, Zp).
    static func containsControl(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            switch $0.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }
}
