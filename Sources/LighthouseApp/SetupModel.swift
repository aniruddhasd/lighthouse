import AppKit
import Foundation
import LighthouseAppCore
import LighthouseGit

/// One prerequisite check's outcome, fail-loud with the exact fix.
struct CheckResult: Identifiable, Sendable, Equatable {
    enum Status: Sendable, Equatable { case pass, fail, warn }
    let id: String
    let title: String
    let status: Status
    let detail: String
}

/// Drives first-run setup: the prerequisite checks Lighthouse still depends on.
/// Attention hooks and notifications were removed (2026-07-29), so the checks
/// are now just the two things a session genuinely needs — git, and a resolvable
/// `claude` in the interactive login shell. Re-runnable and idempotent.
@MainActor @Observable
final class SetupModel {
    private let git: GitClient
    private let loginShell: String

    private(set) var checks: [CheckResult] = []
    private(set) var running = false

    init(git: GitClient, loginShell: String) {
        self.git = git
        self.loginShell = loginShell
    }

    // MARK: - Prerequisite checks

    func runChecks() async {
        running = true
        defer { running = false }
        checks = [await checkGit(), await checkClaude()]
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
}
