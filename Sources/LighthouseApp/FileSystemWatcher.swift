import CoreServices
import Foundation

/// Thin FSEvents wrapper: one watched root, one callback. The review pane
/// creates exactly one of these — for the SELECTED task's SELECTED repo
/// worktree — and tears it down when the pane disappears or the selection
/// changes; watching every worktree of every task would thrash.
final class FileSystemWatcher {
    private var stream: FSEventStreamRef?

    /// - Parameter latency: FSEvents' own coalescing window; kept short
    ///   (0.2s) because DiffRefresher owns the real debounce.
    init?(path: String, latency: TimeInterval = 0.2, onChange: @escaping @Sendable () -> Void) {
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        let box = CallbackBox(onChange: onChange)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: { info in
                if let info { Unmanaged<CallbackBox>.fromOpaque(info).release() }
            },
            copyDescription: nil)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents))
        else {
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }

    private final class CallbackBox {
        let onChange: @Sendable () -> Void
        init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    }
}
