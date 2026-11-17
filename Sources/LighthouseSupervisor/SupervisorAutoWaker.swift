import Foundation
import LighthouseAppCore

/// What the auto-waker needs from the runner. A protocol so the waker's own logic —
/// when to ask, how bursts coalesce, when to stop — is tested without a process.
@MainActor
public protocol SupervisorEvaluating: AnyObject {
    /// True only when the supervisor is enabled, automatic runs are on, and it is not halted.
    var automaticEnabled: Bool { get }
    func evaluate(trigger: WakeTrigger) async -> EvaluationResult
}

/// Turns "a supervised task's turn just ended" into an automatic evaluation. It owns no
/// policy: whether anything actually runs is `WakePolicy`'s call (debounce, watermark, caps,
/// breaker). This only decides WHEN to ask, and makes sure that
/// - a burst of turn ends is one evaluation, not many;
/// - a turn that ends during a run gets exactly one follow-up check;
/// - a debounce skip is waited out and retried (bounded);
/// - a run is never repeated without a new event — a failed run waits for the next trigger.
@MainActor
public final class SupervisorAutoWaker {
    private let runner: SupervisorEvaluating
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let now: @Sendable () -> Date
    private let maxDebounceWaits: Int
    private var loop: Task<Void, Never>?
    private var dirty = false

    public init(
        runner: SupervisorEvaluating,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        now: @escaping @Sendable () -> Date = { Date() },
        maxDebounceWaits: Int = 20
    ) {
        self.runner = runner
        self.sleep = sleep
        self.now = now
        self.maxDebounceWaits = maxDebounceWaits
    }

    /// Call for every event the hook log records, AFTER it has been persisted (the
    /// evaluation reads the persisted log).
    public func eventRecorded(_ logged: LoggedHookEvent) {
        guard TurnOrdering.isTurnEnd(logged), runner.automaticEnabled else { return }
        dirty = true
        guard loop == nil else { return } // the running loop will see `dirty`
        loop = Task { @MainActor [weak self] in
            await self?.drain()
            self?.loop = nil
        }
    }

    /// Waits for any in-flight round to finish (tests; shutdown).
    public func idle() async { await loop?.value }

    private func drain() async {
        var debounceWaits = 0
        while dirty {
            dirty = false
            guard runner.automaticEnabled else { return }
            let result = await runner.evaluate(trigger: .automatic)
            if case .skipped(.debouncing(let until)) = result {
                guard debounceWaits < maxDebounceWaits else { return }
                debounceWaits += 1
                dirty = true
                await sleep(max(0, until.timeIntervalSince(now())) + 0.05)
            }
        }
    }
}
