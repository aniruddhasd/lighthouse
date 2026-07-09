/// Every signal the attention pipeline can deliver. Agent events arrive from
/// the adapter (build step 3); merge events from the merge walk (step 6);
/// workspace events from filesystem observation. Nothing here knows about
/// sockets or hook payloads.
public enum AttentionEvent: String, Sendable, Equatable, CaseIterable {
    case agentWorking
    case agentNeedsInput
    case agentStopped
    case sessionDied
    case workspaceDirtyDetected
    case workspaceCleanDetected
    case mergeStarted
    case mergeConflicted
    case mergeCompleted
}

/// Pure, synchronous, TOTAL transition function: every (state, event) pair is
/// defined by an exhaustive switch with no default — an unknown transition is
/// impossible by construction (spec §7). Callers fold event streams through
/// `nextState`; out-of-order or repeated events land in a defined state.
public enum AttentionStateMachine {

    public static func nextState(
        from state: TaskAttentionState, on event: AttentionEvent
    ) -> TaskAttentionState {
        switch event {
        // The agent's own signals are authoritative about the agent.
        case .agentWorking:
            return .working
        case .agentNeedsInput:
            return .needsInput

        case .agentStopped:
            switch state {
            // The turn ended: from needsInput too — a Stop after a
            // Notification means the prompt was answered and the turn ran out.
            case .working, .needsInput, .done: return .done
            // Uncommitted changes don't vanish because the agent stopped.
            case .dirty: return .dirty
            }

        case .sessionDied:
            switch state {
            // Pty death mid-work orphans in-flight changes: flag, never hide.
            case .working, .needsInput, .dirty: return .dirty
            case .done: return .done
            }

        case .workspaceDirtyDetected:
            switch state {
            // Edits while an agent is active are the expected mechanics.
            case .working: return .working
            case .needsInput: return .needsInput
            // Edits with no active agent are unaccounted-for work.
            case .done, .dirty: return .dirty
            }

        case .workspaceCleanDetected:
            switch state {
            case .working: return .working
            case .needsInput: return .needsInput
            case .done: return .done
            // The unaccounted-for changes are gone (committed or reverted).
            case .dirty: return .done
            }

        // The merge walk is app-driven activity.
        case .mergeStarted:
            return .working
        // Guardrail 5: a conflict pauses visibly, never silently.
        case .mergeConflicted:
            return .needsInput
        case .mergeCompleted:
            return .done
        }
    }

    /// Folds a whole event sequence from an initial state.
    public static func replay(
        _ events: some Sequence<AttentionEvent>, from state: TaskAttentionState
    ) -> TaskAttentionState {
        events.reduce(state) { nextState(from: $0, on: $1) }
    }
}
