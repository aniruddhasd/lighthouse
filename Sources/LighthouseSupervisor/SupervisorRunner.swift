import Foundation
import LighthouseAppCore
import LighthouseTaskEngine

/// What one `evaluate` call did.
public enum EvaluationResult: Equatable, Sendable {
    case skipped(SkipReason)
    case ran(RunRecord)
}

/// Wakes the supervisor model when `WakePolicy` says so and records what happened.
/// Orchestration only: the decision is `WakePolicy`, the command line is
/// `SupervisorInvocationBuilder`, the process is behind `ProcessRunning`.
/// One run at a time; settings and state are the only things it persists.
@MainActor
public final class SupervisorRunner {
    public private(set) var settings: SupervisorSettings
    public private(set) var state: SupervisorState
    public private(set) var isRunning = false
    public private(set) var lastResult: EvaluationResult?

    private let source: SupervisorSnapshotSource
    private let process: ProcessRunning
    private let paths: SupervisorPaths
    private let settingsFile: OwnerOnlyJSONFile<SupervisorSettings>
    private let stateFile: OwnerOnlyJSONFile<SupervisorState>
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    /// Set when a persisted file exists but cannot be read: nothing runs, and nothing is
    /// overwritten, until the user fixes or removes it.
    public private(set) var loadError: String?

    public init(
        directory: URL, source: SupervisorSnapshotSource, process: ProcessRunning,
        paths: SupervisorPaths, now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        settingsFile = OwnerOnlyJSONFile(directory: directory, fileName: "supervisor-settings.json")
        stateFile = OwnerOnlyJSONFile(directory: directory, fileName: "supervisor-state.json")
        self.source = source
        self.process = process
        self.paths = paths
        self.now = now
        self.calendar = calendar
        var problems: [String] = []
        do { settings = try settingsFile.load() ?? SupervisorSettings() } catch {
            settings = SupervisorSettings()
            problems.append("supervisor-settings.json could not be read: \(error)")
        }
        do { state = try stateFile.load() ?? SupervisorState() } catch {
            state = SupervisorState()
            problems.append("supervisor-state.json could not be read: \(error)")
        }
        loadError = problems.isEmpty ? nil : problems.joined(separator: " ")
        if let loadError { state.haltReason = loadError }
    }

    // MARK: Settings (the panel's entry points)

    /// Persists new settings. Invalid values are stored (so the user sees what they typed)
    /// but `WakePolicy` refuses to run with them.
    public func update(_ new: SupervisorSettings) throws {
        guard loadError == nil else { throw SupervisorError.unreadableFiles(loadError ?? "") }
        try settingsFile.save(new)
        settings = new
    }

    /// The user's explicit "resume" after a halt: clears the halt and starts a fresh
    /// enabled period, so nothing from before it is woken for.
    public func resume() throws {
        guard loadError == nil else { throw SupervisorError.unreadableFiles(loadError ?? "") }
        var next = state
        next.haltReason = nil
        next.since = now()
        try stateFile.save(next)
        state = next
    }

    // MARK: Evaluation

    /// Decides and, if warranted, runs the supervisor once. Never throws: every problem
    /// is a `skipped` reason or a failed `RunRecord`.
    @discardableResult
    public func evaluate(trigger: WakeTrigger) async -> EvaluationResult {
        let result = await evaluateOnce(trigger: trigger)
        lastResult = result
        return result
    }

    private func evaluateOnce(trigger: WakeTrigger) async -> EvaluationResult {
        guard !isRunning else { return .skipped(.runInFlight) }
        let at = now()

        // A new enabled period starts the moment we first see it enabled; leaving the
        // enabled state ends it. Persisted before anything can run.
        if loadError == nil {
            let wantSince: Date? = settings.enabled ? (state.since ?? at) : nil
            if wantSince != state.since {
                var next = state
                next.since = wantSince
                if !persist(next) { return .skipped(.halted(state.haltReason ?? "state could not be saved")) }
            }
        }

        let snapshot: SupervisorSnapshot
        do { snapshot = try source.snapshot() } catch {
            return .skipped(.snapshotUnavailable("\(error)"))
        }

        let decision = WakePolicy.decide(
            trigger: trigger, settings: settings, state: state,
            tasks: snapshot.tasks, events: snapshot.events, now: at, calendar: calendar)
        guard case .wake(let turns) = decision else {
            if case .skip(let reason) = decision { return .skipped(reason) }
            return .skipped(.nothingNew)
        }

        for (name, url) in [("claude", paths.claude), ("the supervisor MCP server", paths.mcpServer)]
        where !FileManager.default.isExecutableFile(atPath: url.path) {
            return .skipped(.misconfigured("\(name) was not found at \(url.path)."))
        }

        let invocation = SupervisorInvocationBuilder.build(
            settings: settings, paths: paths, turns: turns, trigger: trigger,
            ledger: state.runs, now: at)
        do {
            for file in invocation.supportFiles { try OwnerOnlyJSONFile<SupervisorState>.write(file.contents, to: file.url) }
        } catch {
            return .skipped(.misconfigured("The supervisor's work files could not be written: \(error)"))
        }

        isRunning = true
        defer { isRunning = false }
        let outcome = await run(invocation)
        let cost = outcome.costUSD ?? settings.maxBudgetPerRunUSD // unknown ≠ free
        let record = RunRecord(
            startedAt: at, trigger: trigger, taskNames: turns.map(\.taskName),
            ok: outcome.ok, costUSD: cost, note: outcome.note)

        var next = state
        next.append(record)
        for turn in turns {
            let key = turn.taskId.uuidString
            if outcome.ok {
                next.watermarks[key] = max(next.watermarks[key] ?? .distantPast, turn.endedAt)
                next.attempts[key] = nil
            } else {
                let prior = next.attempts[key]
                let same = prior.map { Int($0.turn.timeIntervalSince1970) == Int(turn.endedAt.timeIntervalSince1970) } ?? false
                next.attempts[key] = TurnAttempt(turn: turn.endedAt, count: same ? (prior?.count ?? 0) + 1 : 1)
            }
        }
        if let halt = WakePolicy.haltReason(afterRuns: next.runs, threshold: settings.failureBreaker) {
            next.haltReason = halt
        }
        // If the record cannot be saved, the spend and watermark are unknown after a
        // restart: halt in memory rather than risk running again blind.
        _ = persist(next)
        return .ran(record)
    }

    private func run(_ invocation: SupervisorInvocation) async -> RunOutcome {
        do {
            let output = try await process.run(invocation, timeout: settings.timeoutSeconds)
            guard output.exitStatus == 0 else {
                let tail = String(decoding: output.stderr.suffix(300), as: UTF8.self)
                // The result JSON still carries a cost and the CLI's message when the run
                // died of its budget or a login problem.
                let parsed = RunOutcome.parse(output.stdout)
                let detail = parsed.note.hasPrefix("The supervisor's output was not") ? tail : parsed.note
                return RunOutcome(
                    ok: false, costUSD: parsed.costUSD,
                    note: "Exited with status \(output.exitStatus). \(detail)")
            }
            return RunOutcome.parse(output.stdout)
        } catch let error as ProcessRunError {
            switch error {
            case .timedOut: return RunOutcome(ok: false, costUSD: nil, note: "The run timed out and was stopped.")
            case .outputTooLarge: return RunOutcome(ok: false, costUSD: nil, note: "The run produced too much output and was stopped.")
            case .launchFailed(let why): return RunOutcome(ok: false, costUSD: nil, note: "The process could not be started: \(why)")
            }
        } catch {
            return RunOutcome(ok: false, costUSD: nil, note: "The run failed: \(error)")
        }
    }

    /// Saves `next` and adopts it; on failure adopts a halted copy in memory.
    private func persist(_ next: SupervisorState) -> Bool {
        do {
            try stateFile.save(next)
            state = next
            return true
        } catch {
            var halted = next
            halted.haltReason = "The supervisor's state could not be saved (\(error)); stopped so spend is not lost track of."
            state = halted
            return false
        }
    }
}

public enum SupervisorError: Error, Equatable, Sendable {
    case unreadableFiles(String)
}
