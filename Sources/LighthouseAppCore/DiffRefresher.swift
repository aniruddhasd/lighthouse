import Foundation

/// Debounces filesystem-change notifications into diff regenerations.
/// Semantics, all tested:
///  - a burst of events produces ONE regeneration after the quiet interval
///    (agent writes arrive in storms — multi-file edits land within tens of
///    milliseconds; 300 ms groups a burst while staying inside the spec's
///    "< ~1 s feels immediate" target, §7);
///  - events arriving WHILE a regeneration runs coalesce into exactly one
///    follow-up run (latest-wins — a slow diff never queues unboundedly);
///  - stop() cancels everything.
public actor DiffRefresher {
    public static let defaultDebounce: Duration = .milliseconds(300)

    private let interval: Duration
    private let action: @Sendable () async -> Void
    private var pending = false
    private var worker: Task<Void, Never>?
    private var stopped = false

    public init(
        interval: Duration = DiffRefresher.defaultDebounce,
        action: @escaping @Sendable () async -> Void
    ) {
        self.interval = interval
        self.action = action
    }

    /// Called for every filesystem event; cheap and non-blocking.
    public func noteChange() {
        guard !stopped else { return }
        pending = true
        guard worker == nil else { return } // debouncing or running: coalesce
        worker = Task { await drain() }
    }

    /// Runs immediately (initial render), still serialized with the worker.
    public func refreshNow() async {
        guard !stopped else { return }
        pending = true
        if worker == nil {
            worker = Task { await drain(skipDebounce: true) }
        }
        await worker?.value
    }

    public func stop() {
        stopped = true
        pending = false
        worker?.cancel()
        worker = nil
    }

    private func drain(skipDebounce: Bool = false) async {
        if !skipDebounce {
            try? await Task.sleep(for: interval)
        }
        while pending, !stopped, !Task.isCancelled {
            pending = false
            await action()
            // Events that arrived during the action left pending == true:
            // loop once more (latest-wins), never queue deeper.
        }
        worker = nil
        // A change may have slipped in exactly as the worker retired.
        if pending, !stopped {
            worker = Task { await drain() }
        }
    }
}
