import Foundation
import Observation
import LighthouseAdapter
import LighthouseAppCore
import LighthouseGit
import LighthouseTaskEngine

/// Composition root: builds the model, the attention socket, and the session
/// registry; pumps socket signals into the model; owns UI-level state that
/// isn't worth persisting (selection, switcher visibility, last error).
@MainActor @Observable
final class AppRuntime {
    let model: AppModel
    let registry = SessionRegistry()
    private let listener: AttentionSocketListener
    private let adapter = ClaudeCodeAdapter()

    var selectedTaskId: UUID?
    var switcherPresented = false
    /// Surfaced verbatim in the UI — always the full typed description.
    var lastError: String?
    /// Set when the attention socket could not start: sessions still run,
    /// badges degrade to unknown (spec §8 fail-safe) — but say so visibly.
    var attentionDegraded: String?

    init(
        configDirectory: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lighthouse", isDirectory: true)
    ) {
        // Socket at the config-directory ROOT: unix socket paths cap at ~104
        // bytes (sun_path), so no nesting.
        listener = AttentionSocketListener(directory: configDirectory, adapter: adapter)
        model = AppModel(
            store: ConfigStore(directory: configDirectory),
            socketPath: listener.socketURL,
            adapter: adapter)
        do {
            try model.load()
        } catch {
            lastError = "Could not load config: \(error)"
        }
        Task { await runAttentionPipeline() }
    }

    private func runAttentionPipeline() async {
        do {
            try await listener.start()
        } catch {
            attentionDegraded =
                "Attention socket failed to start (\(error)). Sessions still work; badges won't update."
            return
        }
        for task in model.tasks {
            if let ref = task.sessionRef {
                await listener.register(sessionRef: ref, taskId: task.id)
            }
        }
        let stream = await listener.signals()
        for await signal in stream {
            model.apply(signal)
        }
    }

    // MARK: - Task + session flows

    func createTaskAndStartSession(name: String, branch: String, repoIds: [UUID]) async {
        do {
            let (task, plan) = try await model.createTask(
                name: name, branch: branch, repoIds: repoIds)
            await listener.register(sessionRef: plan.sessionRef, taskId: task.id)
            startSession(taskId: task.id, plan: plan)
            selectedTaskId = task.id
        } catch let failure as TaskCreationFailure {
            lastError = FailureDescriber.describe(failure)
        } catch let error as TaskEngineError {
            lastError = FailureDescriber.describe(error)
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Resume: `claude --resume <id>`. A dead/unknown id fails fast and
    /// visibly inside the terminal (verified: "No conversation found…",
    /// exit 1) — the exit lands as sessionDied, and resume stays available.
    func resumeSession(for task: TaskRecord) {
        do {
            guard let plan = try model.resumePlan(for: task) else {
                lastError = "\(task.name) has no stored session to resume."
                return
            }
            startSession(taskId: task.id, plan: plan)
        } catch {
            lastError = String(describing: error)
        }
    }

    private func startSession(taskId: UUID, plan: LaunchPlan) {
        _ = registry.start(taskId: taskId, plan: plan) { [weak self] id, _ in
            self?.model.noteSessionEnded(taskId: id)
        }
        model.noteSessionStarted(taskId: taskId)
    }

    func removeTask(_ task: TaskRecord, mode: TaskRemovalMode) async -> Bool {
        do {
            if let ref = task.sessionRef {
                await listener.unregister(sessionRef: ref)
            }
            registry.discard(taskId: task.id)
            _ = try await model.removeTask(task, mode: mode)
            if selectedTaskId == task.id { selectedTaskId = nil }
            return true
        } catch let error as TaskEngineError {
            lastError = FailureDescriber.describe(error)
            return false
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    /// Called on the way out (applicationWillTerminate): unlink the socket.
    /// Ptys die with the app; conversation context survives via --resume.
    nonisolated func shutdown() {
        listener.stop()
    }
}
