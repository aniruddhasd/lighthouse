import AppKit
import Foundation
import LighthouseAdapter
import LighthouseAppCore
import LighthouseGit
import UserNotifications

/// One prerequisite check's outcome, fail-loud with the exact fix.
struct CheckResult: Identifiable, Sendable, Equatable {
    enum Status: Sendable, Equatable { case pass, fail, warn }
    let id: String
    let title: String
    let status: Status
    let detail: String
}

/// Drives first-run setup: prerequisite checks, notification authorization,
/// and the hook self-test (real transport). Re-runnable and idempotent.
@MainActor @Observable
final class SetupModel {
    private let git: GitClient
    private let loginShell: String
    private let socketPath: URL
    private let notifications: NotificationService
    private let makeListener: (URL) -> AttentionSocketListener

    private(set) var checks: [CheckResult] = []
    private(set) var notificationStatus = "unknown"
    private(set) var running = false

    init(
        git: GitClient, loginShell: String, socketPath: URL,
        notifications: NotificationService,
        makeListener: @escaping (URL) -> AttentionSocketListener
    ) {
        self.git = git
        self.loginShell = loginShell
        self.socketPath = socketPath
        self.notifications = notifications
        self.makeListener = makeListener
    }

    // MARK: - Prerequisite checks

    func runChecks() async {
        running = true
        defer { running = false }
        var results: [CheckResult] = []
        results.append(await checkGit())
        results.append(await checkClaude())
        results.append(checkContainerWritable())
        results.append(checkSocketPath())
        results.append(await checkHookSelfTest())
        checks = results
        notificationStatus = describe(await notifications.authorizationStatus())
    }

    private func run(_ executable: String, _ args: [String]) async -> (Int32, String) {
        do {
            let r = try await ProcessRunner.run(
                executable: executable, arguments: args,
                workingDirectory: FileManager.default.temporaryDirectory)
            return (r.exitCode, r.stdoutText + r.stderrText)
        } catch {
            return (-1, String(describing: error))
        }
    }

    private func checkGit() async -> CheckResult {
        let (code, out) = await run("/usr/bin/env", ["git", "--version"])
        guard code == 0, let version = PrerequisiteChecks.parseGitVersion(out) else {
            return CheckResult(id: "git", title: "git on PATH", status: .fail,
                detail: "git not found or unparseable. Install the Xcode Command Line Tools (xcode-select --install).")
        }
        guard PrerequisiteChecks.gitMeetsMinimum(version) else {
            return CheckResult(id: "git", title: "git ≥ 2.35", status: .fail,
                detail: "Found git \(version.display); Lighthouse needs ≥ 2.35 for zdiff3 conflict markers. Update git.")
        }
        return CheckResult(id: "git", title: "git ≥ 2.35", status: .pass,
            detail: "Found git \(version.display).")
    }

    private func checkClaude() async -> CheckResult {
        // Resolve THROUGH the login+interactive shell — the per-folder account
        // function only exists there; a bare PATH lookup would be wrong.
        let (code, out) = await run(loginShell, ["-l", "-i", "-c", "command -v claude"])
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code == 0, !path.isEmpty else {
            return CheckResult(id: "claude", title: "claude via login shell", status: .fail,
                detail: "`\(loginShell) -l -i -c 'command -v claude'` found nothing. Claude Code isn't resolvable in your interactive shell — install it, or fix your shell rc so `claude` is on PATH there (Lighthouse launches sessions through this exact shell).")
        }
        return CheckResult(id: "claude", title: "claude via login shell", status: .pass,
            detail: "Resolves to \(path).")
    }

    private func checkContainerWritable() -> CheckResult {
        let dir = socketPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let writable = FileManager.default.isWritableFile(atPath: dir.path)
        return CheckResult(id: "container", title: "app container writable",
            status: writable ? .pass : .fail,
            detail: writable ? "Writable: \(dir.path)"
                             : "Not writable: \(dir.path). Check permissions on Application Support.")
    }

    private func checkSocketPath() -> CheckResult {
        let fits = PrerequisiteChecks.socketPathFits(socketPath.path)
        return CheckResult(id: "socket-path", title: "socket path within limit",
            status: fits ? .pass : .fail,
            detail: fits ? "\(socketPath.path.utf8.count) bytes (≤ \(PrerequisiteChecks.maxSocketPathBytes))."
                         : "Socket path is \(socketPath.path.utf8.count) bytes; macOS caps it at \(PrerequisiteChecks.maxSocketPathBytes). Sessions would work but attention badges could not.")
    }

    /// The piece that turns "why are my badges dead" into a checked box: fire
    /// a synthetic hook through the REAL curl transport against a live socket
    /// with a registered fixture session, and confirm a signal arrives.
    private func checkHookSelfTest() async -> CheckResult {
        func fail(_ stage: String) -> CheckResult {
            CheckResult(id: "hook", title: "hook delivery self-test", status: .fail,
                detail: "Failed at: \(stage). Attention badges depend on this path.")
        }
        // curl present?
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/curl") else {
            return fail("curl missing (/usr/bin/curl)")
        }
        // Live socket in an isolated temp dir (never the real one).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lh-hooktest-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let listener = makeListener(dir)
        let socketURL: URL
        do { socketURL = try await listener.start() } catch { return fail("socket dead (\(error))") }
        defer { listener.stop() }

        let sessionRef = UUID().uuidString.lowercased()
        let taskId = UUID()
        await listener.register(sessionRef: sessionRef, taskId: taskId)
        let stream = await listener.signals()

        // The exact production hook command (exec-form curl), fed the payload
        // on stdin like Claude Code does.
        let args = (HookInstaller.handler(socketPath: socketURL)["args"] as? [String]) ?? []
        let payload = "{\"session_id\":\"\(sessionRef)\",\"hook_event_name\":\"Stop\",\"cwd\":\"/x\"}"
        let command = "printf %s " + ShellQuoter.quote(payload)
            + " | /usr/bin/curl " + ShellQuoter.command(args)
        let curl = await run("/bin/sh", ["-c", command])
        guard curl.0 == 0 else { return fail("payload rejected (curl exit \(curl.0))") }

        // Confirm the listener emitted a signal for our session → badge path OK.
        let received: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await signal in stream where signal.taskId == taskId { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        return received
            ? CheckResult(id: "hook", title: "hook delivery self-test", status: .pass,
                detail: "A synthetic Stop hook reached the socket and updated attention state.")
            : fail("badge state not updated (signal never arrived)")
    }

    // MARK: - Notifications

    func requestNotifications() async {
        _ = await notifications.requestAuthorization()
        notificationStatus = describe(await notifications.authorizationStatus())
    }

    private func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral: return "on"
        case .denied: return "off (denied)"
        case .notDetermined: return "not requested"
        @unknown default: return "unknown"
        }
    }
}
