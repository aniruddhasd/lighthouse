import Foundation
import LighthouseAdapter
import LighthouseAppCore
import Testing
import LighthouseTaskEngine
@testable import LighthouseSupervisor

/// The delivery gate decides whether a confirmed `send` may be typed into a live
/// session. It must fail closed: every unknown or ambiguous state refuses. The
/// event sequences below are the ones actually observed live (docs/hook-observations.md).
@Suite("DeliveryGate")
struct DeliveryGateTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let taskId = UUID()

    private func ev(_ name: String, at offset: TimeInterval, agent: String? = nil,
                    attribution: HookAttribution = .primary) -> LoggedHookEvent {
        LoggedHookEvent(taskId: taskId, attribution: attribution, event: HookEvent(
            receivedAt: t0.addingTimeInterval(offset), eventName: name, sessionId: "s", agentId: agent))
    }

    private func proposal(
        basedOn: TimeInterval? = 0, text: String = "please open the PR", status: ProposalStatus = .pending,
        kind: ProposalKind = .send
    ) -> Proposal {
        Proposal(id: UUID(), taskId: taskId, taskRef: "a", kind: kind, text: text, reason: "turn finished",
                 basedOn: basedOn.map { t0.addingTimeInterval($0) }, createdAt: t0, status: status,
                 rejectionReason: nil)
    }

    private func check(
        _ p: Proposal, _ events: [LoggedHookEvent], supervised: Bool = true, running: Bool = true,
        claude: Bool? = true, lastInput: TimeInterval? = nil, sent: Int = 0, now: TimeInterval = 60,
        requireClaude: Bool = false
    ) -> GateResult {
        DeliveryGate.check(
            DeliveryContext(
                proposal: p, taskSupervised: supervised, events: events, now: t0.addingTimeInterval(now),
                terminalRunning: running, claudeIsForeground: claude,
                lastUserInput: lastInput.map { t0.addingTimeInterval($0) }, sentInLastHour: sent),
            requireClaudeForeground: requireClaude)
    }

    private let calm = { (self_: DeliveryGateTests) in [self_.ev("UserPromptSubmit", at: -60), self_.ev("Stop", at: 0)] }

    // MARK: Staleness — the sequences seen live

    @Test func aFreshProposalAfterAStopPasses() {
        #expect(check(proposal(), calm(self)).allowed)
    }

    @Test func nextPromptHelperAfterTheStopDoesNotMakeItStale() {
        let events = calm(self) + [ev("SubagentStop", at: 2, agent: "helper1")]
        #expect(check(proposal(), events).allowed, "the ~2 s next-prompt suggestion always trails a Stop")
    }

    @Test func aNewerPromptExpiresIt() {
        let r = check(proposal(), calm(self) + [ev("UserPromptSubmit", at: 5)])
        #expect(!r.allowed && r.expireReason != nil)
    }

    /// Run 3: an Esc'd questionnaire leaves a PermissionRequest and no Stop at all.
    @Test func aDanglingPermissionRequestAfterTheTurnExpiresIt() {
        let r = check(proposal(), calm(self) + [ev("UserPromptSubmit", at: 5), ev("PermissionRequest", at: 12)])
        #expect(!r.allowed && r.expireReason != nil)
    }

    @Test func aSessionEndOrRestartAfterTheTurnExpiresIt() {
        #expect(check(proposal(), calm(self) + [ev("SessionEnd", at: 5)]).expireReason != nil)
        #expect(check(proposal(), calm(self) + [ev("SessionStart", at: 9)]).expireReason != nil)
    }

    @Test func aLaterStopMeansANewerTurnAndExpiresTheOldProposal() {
        let events = calm(self) + [ev("UserPromptSubmit", at: 5), ev("Stop", at: 30)]
        #expect(check(proposal(), events).expireReason != nil)
    }

    @Test func notificationsAndOtherSessionsAndSubagentsDoNotCount() {
        let events = calm(self) + [
            ev("Notification", at: 3),
            ev("UserPromptSubmit", at: 4, attribution: .otherSessionInTask),
            ev("PermissionRequest", at: 5, agent: "sub"),
        ]
        #expect(check(proposal(), events).allowed)
    }

    /// The proposal's basedOn has whole-second precision; the live event has a
    /// fraction. They must still match, and a newer event in the SAME second after the
    /// Stop must still count (order-based, not time-based).
    @Test func basedOnMatchesByWholeSecondAndOrderNotByInstant() {
        let stop = LoggedHookEvent(taskId: taskId, attribution: .primary, event: HookEvent(
            receivedAt: t0.addingTimeInterval(0.7), eventName: "Stop", sessionId: "s"))
        let sameSecondPrompt = LoggedHookEvent(taskId: taskId, attribution: .primary, event: HookEvent(
            receivedAt: t0.addingTimeInterval(0.9), eventName: "UserPromptSubmit", sessionId: "s"))
        #expect(check(proposal(basedOn: 0), [stop]).allowed)
        #expect(check(proposal(basedOn: 0), [stop, sameSecondPrompt]).expireReason != nil)
    }

    @Test func aTurnTheLogHasNeverHeardOfIsRefusedNotExpired() {
        let r = check(proposal(basedOn: 999), calm(self))
        #expect(!r.allowed && r.expireReason == nil && r.refusals.contains(.unknownTurn))
    }

    // MARK: Other conditions

    @Test func notPendingOrNotASendOrUnsupervisedIsRefused() {
        #expect(check(proposal(status: .sent), calm(self)).refusals.contains(.notPending))
        #expect(check(proposal(status: .dismissed), calm(self)).refusals.contains(.notPending))
        #expect(check(proposal(kind: .hold), calm(self)).refusals.contains(.notASend))
        let off = check(proposal(), calm(self), supervised: false)
        #expect(!off.allowed && off.refusals.contains(.taskNotSupervised) && off.expireReason != nil)
    }

    @Test func aSendWithNoBasedOnIsRefused() {
        #expect(!check(proposal(basedOn: nil), calm(self)).allowed)
    }

    @Test func noTerminalIsRefusedButNotExpired() {
        let r = check(proposal(), calm(self), running: false)
        #expect(!r.allowed && r.refusals.contains(.noTerminal) && r.expireReason == nil)
    }

    @Test func userTypingRecentlyIsRefusedAndOldInputIsNot() {
        #expect(check(proposal(), calm(self), lastInput: 55, now: 60).refusals.contains(.userTyping))
        #expect(check(proposal(), calm(self), lastInput: 40, now: 60).allowed, "20 s ago is outside the 10 s window")
        #expect(check(proposal(), calm(self), lastInput: 50.5, now: 60).refusals.contains(.userTyping))
        #expect(check(proposal(), calm(self), lastInput: nil).allowed)
    }

    @Test func aFutureTimestampCountsAsTypingNotAsOld() {
        #expect(check(proposal(), calm(self), lastInput: 90, now: 60).refusals.contains(.userTyping))
    }

    @Test func theRateBreakerStopsAtTheLimit() {
        #expect(check(proposal(), calm(self), sent: DeliveryGate.maxPerHour - 1).allowed)
        #expect(check(proposal(), calm(self), sent: DeliveryGate.maxPerHour).refusals.contains(.rateLimited))
    }

    @Test func textIsRevalidatedAtSendTime() {
        #expect(check(proposal(text: "ok\nrm -rf ~"), calm(self)).refusals.contains(where: { if case .invalidText = $0 { return true } else { return false } }))
        #expect(check(proposal(text: "/clear"), calm(self)).allowed == false)
        #expect(check(proposal(text: "!ls"), calm(self)).allowed == false)
    }

    // MARK: Claude-in-the-tab (a warning for 3a, a requirement for 3b)

    @Test func claudeNotForegroundIsAWarningIn3aAndARefusalWhenRequired() {
        let soft = check(proposal(), calm(self), claude: false)
        #expect(soft.allowed && !soft.warnings.isEmpty)
        let unknown = check(proposal(), calm(self), claude: nil)
        #expect(unknown.allowed && !unknown.warnings.isEmpty)
        let strict = check(proposal(), calm(self), claude: false, requireClaude: true)
        #expect(!strict.allowed && strict.refusals.contains(.notClaude))
        #expect(!check(proposal(), calm(self), claude: nil, requireClaude: true).allowed, "unknown must fail closed")
        #expect(check(proposal(), calm(self), claude: true, requireClaude: true).allowed)
    }

    @Test func everyRefusalIsReportedNotJustTheFirst() {
        let r = check(proposal(), calm(self), running: false, lastInput: 59, sent: 99)
        #expect(Set(r.refusals.map { "\($0)" }).count >= 3)
    }
}
