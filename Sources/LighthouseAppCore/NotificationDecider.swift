import Foundation
import LighthouseTaskEngine

/// The kind of native notification to post for an attention change.
public enum NotificationKind: String, Sendable, Equatable {
    case needsInput      // the money notification: an agent is blocked on you
    case done            // the agent finished its turn
    case sessionDied     // the session ended / pty died with work possibly unfinished
}

/// One attention transition, as produced by folding an event through the
/// state machine.
public struct AttentionTransition: Sendable, Equatable {
    public let taskId: UUID
    public let event: AttentionEvent
    public let oldState: TaskAttentionState
    public let newState: TaskAttentionState

    public init(taskId: UUID, event: AttentionEvent, oldState: TaskAttentionState, newState: TaskAttentionState) {
        self.taskId = taskId
        self.event = event
        self.oldState = oldState
        self.newState = newState
    }
}

/// PURE decision: given an attention transition and whether the user is
/// currently looking at that task, should we post a notification, and which?
///
/// Rule (spec §6 step 7): notify on needs-input / done / sessionDied, but
/// ONLY when the signal would otherwise be missed — never for the task the
/// user is actively viewing (app active AND that task selected). All the
/// logic lives here so the full matrix is unit-tested; UN* delivery is a thin
/// adapter over `decide`.
public enum NotificationDecider {

    /// - Parameter isCurrentlyViewed: app is active AND this task is selected.
    public static func decide(
        _ transition: AttentionTransition, isCurrentlyViewed: Bool
    ) -> NotificationKind? {
        // Never interrupt the user about the very task on their screen.
        guard !isCurrentlyViewed else { return nil }

        // Only fire on an actual ENTRY into the state (not a repeat), keyed by
        // the event so a dirty from workspace edits (not a dead session)
        // doesn't masquerade as a session death.
        switch transition.event {
        case .agentNeedsInput, .mergeConflicted:
            return transition.newState == .needsInput && transition.oldState != .needsInput
                ? .needsInput : nil
        case .agentStopped, .mergeCompleted:
            return transition.newState == .done && transition.oldState != .done
                ? .done : nil
        case .sessionDied:
            return transition.newState == .dirty ? .sessionDied : nil
        case .agentWorking, .mergeStarted, .workspaceDirtyDetected, .workspaceCleanDetected:
            return nil
        }
    }
}
