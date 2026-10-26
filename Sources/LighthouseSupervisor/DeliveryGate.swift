import Foundation
import LighthouseAdapter
import LighthouseAppCore

/// Everything the gate looks at, captured at one instant. Plain values, so the gate
/// is a pure function and every refusal path is unit-testable without a terminal.
public struct DeliveryContext: Sendable {
    public let proposal: Proposal
    public let taskSupervised: Bool
    /// This task's logged hook events, in arrival order.
    public let events: [LoggedHookEvent]
    public let now: Date
    public let terminalRunning: Bool
    /// Whether `claude` is what is running in the tab. nil = could not tell.
    public let claudeIsForeground: Bool?
    public let lastUserInput: Date?
    public let sentInLastHour: Int

    public init(
        proposal: Proposal, taskSupervised: Bool, events: [LoggedHookEvent], now: Date,
        terminalRunning: Bool, claudeIsForeground: Bool?, lastUserInput: Date?, sentInLastHour: Int
    ) {
        self.proposal = proposal
        self.taskSupervised = taskSupervised
        self.events = events
        self.now = now
        self.terminalRunning = terminalRunning
        self.claudeIsForeground = claudeIsForeground
        self.lastUserInput = lastUserInput
        self.sentInLastHour = sentInLastHour
    }
}

public enum GateRefusal: Equatable, Sendable, CustomStringConvertible {
    case notPending
    case notASend
    case taskNotSupervised
    /// `based_on` matches no turn the log knows about.
    case unknownTurn
    case staleTurn(String)
    case noTerminal
    case userTyping
    case rateLimited
    case invalidText(String)
    case notClaude

    public var description: String {
        switch self {
        case .notPending: return "This proposal is no longer pending."
        case .notASend: return "Only a send proposal can be delivered."
        case .taskNotSupervised: return "The task is no longer supervised."
        case .unknownTurn: return "The turn this was based on is not in the event log."
        case .staleTurn(let why): return why
        case .noTerminal: return "The task has no running terminal."
        case .userTyping: return "You typed in that terminal a moment ago."
        case .rateLimited: return "Too many messages were sent to this task in the last hour."
        case .invalidText(let why): return "The text no longer validates: \(why)"
        case .notClaude: return "Claude does not appear to be running in that tab."
        }
    }
}

public struct GateResult: Equatable, Sendable {
    public let refusals: [GateRefusal]
    public let warnings: [String]
    /// Set when the proposal has been overtaken by events and should leave `pending`.
    public let expireReason: String?
    public var allowed: Bool { refusals.isEmpty }
}

/// Decides whether a confirmed `send` may be typed into a live session. Fails closed:
/// every unknown or ambiguous state refuses (docs/orchestrator-design.md §13).
public enum DeliveryGate {
    /// No user input to the terminal within this window.
    public static let userIdleWindow: TimeInterval = 10
    public static let maxPerHour = 6

    public static func check(_ c: DeliveryContext, requireClaudeForeground: Bool = false) -> GateResult {
        var refusals: [GateRefusal] = []
        var warnings: [String] = []
        var expire: String?

        if c.proposal.status != .pending { refusals.append(.notPending) }
        if c.proposal.kind != .send { refusals.append(.notASend) }
        if !c.taskSupervised {
            refusals.append(.taskNotSupervised)
            expire = "The task is no longer supervised."
        }

        // Freshness: the world must not have moved since the turn this was judged from.
        switch freshness(c) {
        case .fresh: break
        case .unknownTurn: refusals.append(.unknownTurn)
        case .stale(let why):
            refusals.append(.staleTurn(why))
            expire = expire ?? why
        }

        if !c.terminalRunning { refusals.append(.noTerminal) }

        // A timestamp in the FUTURE is treated as "typing now", never as old.
        if let last = c.lastUserInput, abs(c.now.timeIntervalSince(last)) < userIdleWindow || last > c.now {
            refusals.append(.userTyping)
        }
        if c.sentInLastHour >= maxPerHour { refusals.append(.rateLimited) }

        // The queue file is same-user-writable: validate again rather than trust it.
        do {
            _ = try ProposalValidator.validateContent(ProposalDraft(
                kind: c.proposal.kind, task: c.proposal.taskRef, text: c.proposal.text,
                reason: c.proposal.reason, basedOn: c.proposal.basedOn))
        } catch let rejection as ProposalRejection {
            refusals.append(.invalidText(rejection.reason))
        } catch {
            refusals.append(.invalidText("invalid"))
        }

        // Typing into a shell prompt instead of Claude is only visible junk without an
        // Enter (3a: a warning); with Enter it would run as a command (3b: a refusal,
        // and "unknown" counts as no).
        if c.claudeIsForeground != true {
            if requireClaudeForeground {
                refusals.append(.notClaude)
            } else {
                warnings.append("Claude does not appear to be running in that tab (or it could not be checked); the text may land at a shell prompt.")
            }
        }
        return GateResult(refusals: refusals, warnings: warnings, expireReason: expire)
    }

    // MARK: Freshness

    private enum Freshness { case fresh, unknownTurn, stale(String) }

    /// Order-based, not time-based: find the turn-ending event `basedOn` names, then ask
    /// whether any MATERIAL primary-session event came after it. Material = any event
    /// with no `agent_id` except `Notification`. Subagent events (the next-prompt helper
    /// always trails a Stop), other sessions and notifications never count.
    private static func freshness(_ c: DeliveryContext) -> Freshness {
        guard let basedOn = c.proposal.basedOn else { return .unknownTurn }
        let second = Int(basedOn.timeIntervalSince1970)
        guard let index = c.events.lastIndex(where: { logged in
            logged.attribution == .primary && logged.event.agentId == nil
                && (logged.event.eventName == "Stop" || logged.event.eventName == "StopFailure")
                && Int(logged.event.receivedAt.timeIntervalSince1970) == second
        }) else { return .unknownTurn }

        let newer = c.events[(index + 1)...].first {
            $0.attribution == .primary && $0.event.agentId == nil && $0.event.eventName != "Notification"
        }
        if let newer {
            return .stale("Overtaken by a newer \(newer.event.eventName) event; the agent has moved on since this was proposed.")
        }
        return .fresh
    }
}
