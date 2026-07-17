import Testing
@testable import LighthouseTaskEngine

/// The transition function is total by construction (exhaustive switch, no
/// default). These tests pin the WHOLE table — a behavior change must edit
/// the expected matrix here, deliberately.
@Suite("AttentionStateMachine")
struct AttentionStateMachineTests {

    typealias S = TaskAttentionState
    typealias E = AttentionEvent

    /// Expected next state for every (state, event) cell. Order of states:
    /// [working, needsInput, done, dirty].
    static let expectedTable: [E: [S: S]] = [
        .agentWorking: [.working: .working, .needsInput: .working, .done: .working, .dirty: .working],
        .agentNeedsInput: [.working: .needsInput, .needsInput: .needsInput, .done: .needsInput, .dirty: .needsInput],
        .agentStopped: [.working: .done, .needsInput: .done, .done: .done, .dirty: .dirty],
        .sessionDied: [.working: .dirty, .needsInput: .dirty, .done: .done, .dirty: .dirty],
        .workspaceDirtyDetected: [.working: .working, .needsInput: .needsInput, .done: .dirty, .dirty: .dirty],
        .workspaceCleanDetected: [.working: .working, .needsInput: .needsInput, .done: .done, .dirty: .done],
        .mergeStarted: [.working: .working, .needsInput: .working, .done: .working, .dirty: .working],
        .mergeConflicted: [.working: .needsInput, .needsInput: .needsInput, .done: .needsInput, .dirty: .needsInput],
        .mergeCompleted: [.working: .done, .needsInput: .done, .done: .done, .dirty: .done],
    ]

    @Test func expectedTableCoversEveryPair() {
        // Guard the test data itself: every event and state must be present.
        #expect(Self.expectedTable.count == E.allCases.count)
        for event in E.allCases {
            #expect(Self.expectedTable[event]?.count == S.allCases.count)
        }
    }

    @Test(arguments: AttentionEvent.allCases)
    func everyCellMatchesThePinnedTable(event: AttentionEvent) throws {
        for state in S.allCases {
            let expected = try #require(Self.expectedTable[event]?[state])
            #expect(
                AttentionStateMachine.nextState(from: state, on: event) == expected,
                "(\(state), \(event))")
        }
    }

    // MARK: Sequences, including out-of-order and repeated events

    @Test func typicalAgentTurnReachesDone() {
        let result = AttentionStateMachine.replay(
            [.agentWorking, .agentNeedsInput, .agentWorking, .agentStopped], from: .done)
        #expect(result == .done)
    }

    @Test func sessionDeathMidWorkFlagsDirtyAndStaysDirtyOnStop() {
        // Out-of-order: a straggling agentStopped after the pty died must not
        // mask the orphaned-changes signal.
        let result = AttentionStateMachine.replay(
            [.agentWorking, .sessionDied, .agentStopped], from: .done)
        #expect(result == .dirty)
    }

    @Test func mergeConflictInterruptsAnything() {
        for start in S.allCases {
            #expect(AttentionStateMachine.nextState(from: start, on: .mergeConflicted) == .needsInput)
        }
    }

    @Test func repeatedEventsAreIdempotent() {
        for event in E.allCases {
            for start in S.allCases {
                let once = AttentionStateMachine.nextState(from: start, on: event)
                let twice = AttentionStateMachine.nextState(from: once, on: event)
                #expect(once == twice, "\(event) not idempotent from \(start)")
            }
        }
    }

    @Test func dirtyResolvesToDoneOnlyWhenWorkspaceCleans() {
        #expect(AttentionStateMachine.replay([.workspaceCleanDetected], from: .dirty) == .done)
        #expect(AttentionStateMachine.replay([.agentStopped], from: .dirty) == .dirty)
    }

    @Test func randomLongSequencesAlwaysLandInDefinedStates() {
        // Deterministic pseudo-random walk over all events: totality means no
        // trap and always a member of the state set.
        var seed: UInt64 = 0x1E51_7005
        var state = S.done
        for _ in 0..<10_000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let event = E.allCases[Int(seed >> 33) % E.allCases.count]
            state = AttentionStateMachine.nextState(from: state, on: event)
            #expect(S.allCases.contains(state))
        }
    }
}
