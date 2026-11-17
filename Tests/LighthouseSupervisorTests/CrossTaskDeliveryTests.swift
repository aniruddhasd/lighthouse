import Foundation
import LighthouseAdapter
import LighthouseAppCore
import LighthouseTaskEngine
import Testing
@testable import LighthouseSupervisor

/// "When alpha finishes, tell beta": the proposal TARGETS beta but is based on ALPHA's turn.
/// Freshness is then about alpha's turn, and beta must be idle. Failure modes first.
@Suite("Cross-task delivery")
struct CrossTaskDeliveryTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let alpha = UUID(), beta = UUID()

    private func ev(_ task: UUID, _ name: String, at offset: TimeInterval, agent: String? = nil,
                    attribution: HookAttribution = .primary) -> LoggedHookEvent {
        LoggedHookEvent(taskId: task, attribution: attribution, event: HookEvent(
            receivedAt: t0.addingTimeInterval(offset), eventName: name, sessionId: "s", agentId: agent))
    }
    private func proposal(source: UUID? = nil, basedOn: TimeInterval = 0) -> Proposal {
        var p = Proposal(id: UUID(), taskId: beta, taskRef: "beta", kind: .send, text: "please start the review",
                         reason: "alpha finished", basedOn: t0.addingTimeInterval(basedOn), createdAt: t0,
                         status: .pending, rejectionReason: nil)
        p.sourceTaskId = source ?? alpha
        p.sourceTaskRef = "alpha"
        return p
    }
    private func check(
        _ p: Proposal, source: [LoggedHookEvent]?, target: [LoggedHookEvent], sourceSupervised: Bool = true
    ) -> GateResult {
        DeliveryGate.check(DeliveryContext(
            proposal: p, taskSupervised: true, events: target, sourceEvents: source, sourceSupervised: sourceSupervised,
            now: t0.addingTimeInterval(60), terminalRunning: true, claudeIsForeground: true, lastUserInput: nil,
            sentInLastHour: 0))
    }
    private var alphaDone: [LoggedHookEvent] { [ev(alpha, "UserPromptSubmit", at: -60), ev(alpha, "Stop", at: 0)] }
    private var betaIdle: [LoggedHookEvent] { [ev(beta, "UserPromptSubmit", at: -500), ev(beta, "Stop", at: -450)] }
    private func isTargetBusy(_ r: GateResult) -> Bool {
        r.refusals.contains { if case .targetBusy = $0 { return true } else { return false } }
    }

    // MARK: Source side

    @Test func aSendBasedOnAnotherTasksTurnPassesWhenThatTurnIsFreshAndTheTargetIsIdle() {
        #expect(check(proposal(), source: alphaDone, target: betaIdle).allowed)
    }

    @Test func theSourceMovingOnExpiresTheProposal() {
        let r = check(proposal(), source: alphaDone + [ev(alpha, "UserPromptSubmit", at: 5)], target: betaIdle)
        #expect(!r.allowed && r.expireReason != nil)
    }

    @Test func theSourceSessionEndingExpiresIt() {
        let r = check(proposal(), source: alphaDone + [ev(alpha, "SessionEnd", at: 5)], target: betaIdle)
        #expect(!r.allowed && r.expireReason != nil)
    }

    @Test func aTurnThatIsOnlyInTheTargetsLogIsNotTheSourcesTurn() {
        // beta has a Stop at second 0, alpha's log does not: based_on names no alpha turn.
        let target = betaIdle + [ev(beta, "Stop", at: 0)]
        let r = check(proposal(), source: [ev(alpha, "UserPromptSubmit", at: -60)], target: target)
        #expect(r.refusals.contains(.unknownTurn) && r.expireReason == nil, "unknown is refused, never expired")
    }

    @Test func missingSourceEventsFailClosed() {
        // The target's own log even holds a Stop at the named second: falling back to it
        // would wrongly pass, so this only refuses if source events are truly required.
        let r = check(proposal(), source: nil, target: betaIdle + [ev(beta, "Stop", at: 0)])
        #expect(r.refusals.contains(.unknownTurn) && !r.allowed)
    }

    @Test func aSourceThatIsNoLongerSupervisedExpiresIt() {
        let r = check(proposal(), source: alphaDone, target: betaIdle, sourceSupervised: false)
        #expect(r.refusals.contains(.sourceNotSupervised) && r.expireReason != nil)
    }

    @Test func theSourcesNextPromptHelperAndNotificationsDoNotMakeItStale() {
        let source = alphaDone + [ev(alpha, "SubagentStop", at: 2, agent: "h"), ev(alpha, "Notification", at: 3)]
        #expect(check(proposal(), source: source, target: betaIdle).allowed)
    }

    // MARK: Target side — refused, never expired

    @Test func aTargetThatIsMidTurnIsRefusedAndTheProposalStaysPending() {
        let r = check(proposal(), source: alphaDone, target: betaIdle + [ev(beta, "UserPromptSubmit", at: 10)])
        #expect(isTargetBusy(r) && r.expireReason == nil)
    }

    @Test func aTargetWaitingOnAQuestionnaireOrInterruptedIsRefused() {
        let r = check(proposal(), source: alphaDone, target: betaIdle + [ev(beta, "PermissionRequest", at: 10)])
        #expect(isTargetBusy(r) && r.expireReason == nil)
        let r2 = check(proposal(), source: alphaDone, target: betaIdle + [ev(beta, "PostToolUse", at: 10)])
        #expect(isTargetBusy(r2), "a tool just finished: the turn is still running")
    }

    @Test func aTargetWhoseSessionEndedOrWasNeverSeenIsRefused() {
        #expect(isTargetBusy(check(proposal(), source: alphaDone, target: betaIdle + [ev(beta, "SessionEnd", at: 10)])))
        #expect(isTargetBusy(check(proposal(), source: alphaDone, target: [])), "no events at all is unknown, so refused")
    }

    @Test func aTargetThatJustStartedItsSessionIsIdle() {
        #expect(check(proposal(), source: alphaDone, target: betaIdle + [ev(beta, "SessionStart", at: 10)]).allowed)
    }

    @Test func aTargetFailureIsIdleToo() {
        #expect(check(proposal(), source: alphaDone, target: [ev(beta, "UserPromptSubmit", at: -9), ev(beta, "StopFailure", at: -5)]).allowed)
    }

    @Test func theTargetsHelperSubagentAndNotificationsDoNotMakeItBusy() {
        let target = betaIdle + [ev(beta, "SubagentStop", at: -448, agent: "h"), ev(beta, "Notification", at: -440)]
        #expect(check(proposal(), source: alphaDone, target: target).allowed)
    }

    @Test func eventsOfAnotherSessionInTheTargetDoNotMakeItBusy() {
        let target = betaIdle + [ev(beta, "UserPromptSubmit", at: 10, attribution: .otherSessionInTask)]
        #expect(check(proposal(), source: alphaDone, target: target).allowed)
    }

    // MARK: Same-task behaviour is unchanged

    @Test func withoutASourceTheTargetsOwnTurnIsTheOneJudged() {
        var p = proposal()
        p.sourceTaskId = nil; p.sourceTaskRef = nil
        let own = [ev(beta, "UserPromptSubmit", at: -60), ev(beta, "Stop", at: 0)]
        #expect(check(p, source: nil, target: own).allowed)
        #expect(check(p, source: nil, target: own + [ev(beta, "UserPromptSubmit", at: 5)]).expireReason != nil)
    }
}
