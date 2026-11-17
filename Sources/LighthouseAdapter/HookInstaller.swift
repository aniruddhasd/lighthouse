import Foundation
import LighthouseGit

public enum HookInstallerError: Error, Sendable, Equatable {
    /// The existing settings file is not valid JSON — refuse loudly and touch
    /// nothing (in -p mode Claude Code silently ignores invalid settings
    /// files, so clobbering or "fixing" one would hide a real user problem).
    case existingSettingsInvalid(path: String, detail: String)
    case ioFailure(path: String, detail: String)
}

/// Writes Lighthouse's supervision hooks into a workspace's
/// `.claude/settings.local.json` (orchestrator phase 1a: observation only),
/// kept surgical: MERGE semantics, existing user content survives byte-for-byte
/// in structure, double-install is a no-op, uninstall removes only ours.
///
/// Also ensures the file is git-ignored: the docs promise auto-gitignore only
/// "when Claude Code creates" the file — WE create it, so WE own the ignore
/// (contract doc). One entry in the repo's shared `info/exclude` (resolved
/// via `git rev-parse --git-path` from the worktree) covers all worktrees
/// and can never be committed.
public struct HookInstaller: Sendable {
    static let settingsRelativePath = ".claude/settings.local.json"
    static let excludeEntry = ".claude/settings.local.json"
    /// The marker by which our handlers are recognized on merge/uninstall:
    /// exec-form curl POSTing to this URL over a unix socket. The URL host is
    /// ignored by curl with --unix-socket; the path names us.
    static let hookURL = "http://localhost/lighthouse-hook"

    /// Hook events installed, with per-event matcher (nil = fires always).
    /// Phase 1a OBSERVES, so the set is wide and `Notification` is unfiltered
    /// (every notification type is logged, then we learn which matter). Names are
    /// from the hooks reference (docs/claude-code-contract.md, re-verified
    /// 2026-10-22 against CLI 2.1.308).
    static let installedEvents: [(event: String, matcher: String?)] = [
        ("SessionStart", nil),
        ("UserPromptSubmit", nil),
        ("Stop", nil),
        ("StopFailure", nil),
        ("SubagentStart", nil),
        ("SubagentStop", nil),
        ("Notification", nil),
        ("PermissionRequest", nil),
        // Experiment: does the questionnaire tool's completion fire PostToolUse (an
        // "unblocked" signal)? Matched to that ONE tool — unfiltered it would fire
        // after every tool call. Docs: fires only after a tool *succeeds*, so a
        // cancelled questionnaire may stay silent.
        ("PostToolUse", "AskUserQuestion"),
        ("SessionEnd", nil),
    ]

    private let git: GitClient

    public init(git: GitClient = GitClient()) {
        self.git = git
    }

    // MARK: - Install

    public func install(in workspace: URL, socketPath: URL) async throws {
        let settingsURL = workspace.appendingPathComponent(Self.settingsRelativePath)
        var root = try Self.readSettings(at: settingsURL)

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        // Replace, don't skip: drop any handler of ours first (including stale
        // ones from the removed attention system, which point at a dead socket
        // path), then add fresh. Re-install is therefore idempotent AND repairs a
        // moved socket path. User handlers are never touched.
        hooks = Self.removingOurHandlers(from: hooks)
        for (event, matcher) in Self.installedEvents {
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            var group: [String: Any] = [
                "hooks": [Self.handler(socketPath: socketPath)]
            ]
            if let matcher {
                group["matcher"] = matcher
            }
            groups.append(group)
            hooks[event] = groups
        }
        root["hooks"] = hooks

        try Self.writeSettings(root, to: settingsURL)
        try await ensureGitExcluded(workspace: workspace)
    }

    // MARK: - Uninstall

    /// Removes exactly our handlers. User hooks, other settings keys, and the
    /// exclude entry (harmless, repo-local) are left alone. A file reduced to
    /// an empty object is deleted.
    public func uninstall(from workspace: URL) async throws {
        let settingsURL = workspace.appendingPathComponent(Self.settingsRelativePath)
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        var root = try Self.readSettings(at: settingsURL)

        if let hooks = root["hooks"] as? [String: Any] {
            let remaining = Self.removingOurHandlers(from: hooks)
            if remaining.isEmpty {
                root.removeValue(forKey: "hooks")
            } else {
                root["hooks"] = remaining
            }
        }

        if root.isEmpty {
            try FileManager.default.removeItem(at: settingsURL)
        } else {
            try Self.writeSettings(root, to: settingsURL)
        }
    }

    /// `hooks` with every handler of ours removed; groups and events left empty by
    /// that are dropped. Anything that is not ours passes through untouched.
    static func removingOurHandlers(from hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, groupsAny) in hooks {
            guard let groups = groupsAny as? [[String: Any]] else {
                result[event] = groupsAny
                continue
            }
            let kept: [[String: Any]] = groups.compactMap { group in
                var group = group
                guard var handlers = group["hooks"] as? [[String: Any]] else { return group }
                let before = handlers.count
                handlers.removeAll(where: isOurHandler)
                if handlers.isEmpty && before > 0 { return nil } // group was only ours
                group["hooks"] = handlers
                return group
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    // MARK: - Handler shape

    /// Exec-form command hook: with `args` present, Claude Code spawns the
    /// executable directly — no shell parses any of this (contract doc,
    /// "Hook configuration shape"). The socket path is app-generated; no
    /// user input reaches these strings. `async` keeps a dead listener from
    /// ever blocking the agent (spec §8 fail-safe).
    public static func handler(socketPath: URL) -> [String: Any] {
        [
            "type": "command",
            "command": "/usr/bin/curl",
            "args": [
                "-s", "--max-time", "5",
                "--unix-socket", socketPath.path,
                "-X", "POST",
                "-H", "Content-Type: application/json",
                "--data-binary", "@-",
                hookURL,
            ],
            "async": true,
        ]
    }

    static func isOurHandler(_ handler: [String: Any]) -> Bool {
        guard handler["command"] as? String == "/usr/bin/curl",
              let args = handler["args"] as? [String] else {
            return false
        }
        return args.contains(hookURL) && args.contains("--unix-socket")
    }

        static func containsOurHandler(_ group: [String: Any]) -> Bool {
        ((group["hooks"] as? [[String: Any]]) ?? []).contains(where: isOurHandler)
    }

    // MARK: - File I/O

    private static func readSettings(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw HookInstallerError.ioFailure(path: url.path, detail: String(describing: error))
        }
        // Empty file counts as empty settings (some tools truncate-create).
        if data.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw HookInstallerError.existingSettingsInvalid(
                path: url.path, detail: "not a JSON object")
        }
        return dictionary
    }

    private static func writeSettings(_ root: [String: Any], to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            // Atomic (temp-then-rename): a crash mid-write must never truncate
            // the user's settings file — we only ever leave the old or the new.
            try data.write(to: url, options: .atomic)
        } catch {
            throw HookInstallerError.ioFailure(path: url.path, detail: String(describing: error))
        }
    }

    /// Appends the exclude entry to the repo's shared info/exclude if absent.
    private func ensureGitExcluded(workspace: URL) async throws {
        let excludeURL = try await git.gitPath("info/exclude", in: workspace)
        let existing = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
        if existing.split(separator: "\n").contains(Substring(Self.excludeEntry)) {
            return
        }
        var content = existing
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        content += Self.excludeEntry + "\n"
        do {
            try FileManager.default.createDirectory(
                at: excludeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Atomic: this is the repo's SHARED info/exclude — a truncating
            // crash here would corrupt a file we don't own.
            try Data(content.utf8).write(to: excludeURL, options: .atomic)
        } catch {
            throw HookInstallerError.ioFailure(
                path: excludeURL.path, detail: String(describing: error))
        }
    }
}
