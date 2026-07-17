import Foundation
import Testing
import LighthouseFixtures
import LighthouseGit
@testable import LighthouseAdapter

/// The guardrail-2 third exception must stay surgical: merge in, never
/// clobber; remove only ours; refuse loudly on files we can't understand.
@Suite("HookInstaller")
final class HookInstallerTests {
    private let fixtures: FixtureFactory
    private let git = GitClient()
    private let installer: HookInstaller
    private let socket = URL(fileURLWithPath: "/tmp/lighthouse test/attention.sock")

    init() throws {
        fixtures = try FixtureFactory()
        installer = HookInstaller(git: GitClient())
    }

    deinit {
        try? fixtures.destroy()
    }

    private func settingsURL(_ repo: FixtureRepo) -> URL {
        repo.path.appendingPathComponent(".claude/settings.local.json")
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try #require(object as? [String: Any])
    }

    // MARK: Broken cases first

    @Test func invalidExistingJSONRefusedFileUntouched() async throws {
        let repo = try fixtures.cleanRepo()
        let url = settingsURL(repo)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("{ definitely not json".utf8)
        try garbage.write(to: url)

        await #expect {
            try await self.installer.install(in: repo.path, socketPath: self.socket)
        } throws: { error in
            guard case .existingSettingsInvalid = error as? HookInstallerError else {
                return false
            }
            return true
        }
        #expect(try Data(contentsOf: url) == garbage)
    }

    @Test func nonObjectJSONRefused() async throws {
        let repo = try fixtures.cleanRepo()
        let url = settingsURL(repo)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[1, 2, 3]".utf8).write(to: url)

        await #expect {
            try await self.installer.install(in: repo.path, socketPath: self.socket)
        } throws: { error in
            (error as? HookInstallerError) != nil
        }
    }

    @Test func uninstallOnMissingFileIsNoOp() async throws {
        let repo = try fixtures.cleanRepo()
        try await installer.uninstall(from: repo.path)
        #expect(!FileManager.default.fileExists(atPath: settingsURL(repo).path))
    }

    // MARK: Merge semantics

    @Test func freshInstallWritesValidSettingsWithAllEvents() async throws {
        let repo = try fixtures.cleanRepo()
        try await installer.install(in: repo.path, socketPath: socket)

        let root = try readJSON(settingsURL(repo))
        let hooks = try #require(root["hooks"] as? [String: Any])
        for (event, _) in HookInstaller.installedEvents {
            let groups = try #require(hooks[event] as? [[String: Any]], "missing \(event)")
            #expect(groups.contains(where: HookInstaller.containsOurHandler))
        }
        // Notification carries the type matcher; Stop has none.
        let notification = try #require((hooks["Notification"] as? [[String: Any]])?.first)
        #expect(notification["matcher"] as? String
            == "permission_prompt|idle_prompt|agent_needs_input|agent_completed")
        let stop = try #require((hooks["Stop"] as? [[String: Any]])?.first)
        #expect(stop["matcher"] == nil)
        // Exec form: args present → no shell parses the command (contract doc).
        let handler = try #require((stop["hooks"] as? [[String: Any]])?.first)
        #expect(handler["command"] as? String == "/usr/bin/curl")
        let args = try #require(handler["args"] as? [String])
        #expect(args.contains(socket.path))
        #expect(args.contains("--unix-socket"))
        #expect(handler["async"] as? Bool == true)
    }

    @Test func existingUserHooksSurviveMerge() async throws {
        let repo = try fixtures.cleanRepo()
        let url = settingsURL(repo)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let userSettings: [String: Any] = [
            "permissions": ["allow": ["Bash(npm test)"]],
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "say done"]]]],
                "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "./check.sh"]]]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: userSettings)
            .write(to: url)

        try await installer.install(in: repo.path, socketPath: socket)

        let root = try readJSON(url)
        // Non-hook keys intact.
        #expect((root["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(npm test)"])
        let hooks = try #require(root["hooks"] as? [String: Any])
        // User's PreToolUse untouched; user's Stop handler still present
        // alongside ours in a separate group.
        #expect((hooks["PreToolUse"] as? [[String: Any]])?.count == 1)
        let stopGroups = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stopGroups.count == 2)
        let userHandlers = stopGroups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .filter { $0["command"] as? String == "say done" }
        #expect(userHandlers.count == 1)
    }

    @Test func doubleInstallIsIdempotent() async throws {
        let repo = try fixtures.cleanRepo()
        try await installer.install(in: repo.path, socketPath: socket)
        let first = try Data(contentsOf: settingsURL(repo))
        try await installer.install(in: repo.path, socketPath: socket)
        let second = try Data(contentsOf: settingsURL(repo))
        #expect(first == second)
    }

    @Test func uninstallRemovesOnlyOurs() async throws {
        let repo = try fixtures.cleanRepo()
        let url = settingsURL(repo)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "env": ["FOO": "bar"],
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]],
        ]).write(to: url)

        try await installer.install(in: repo.path, socketPath: socket)
        try await installer.uninstall(from: repo.path)

        let root = try readJSON(url)
        #expect((root["env"] as? [String: String]) == ["FOO": "bar"])
        let hooks = try #require(root["hooks"] as? [String: Any])
        // Only the user's Stop group remains; our events are gone entirely.
        #expect(Set(hooks.keys) == ["Stop"])
        let stopGroups = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stopGroups.count == 1)
        #expect(!HookInstaller.containsOurHandler(stopGroups[0]))
    }

    @Test func uninstallAfterFreshInstallDeletesTheFile() async throws {
        let repo = try fixtures.cleanRepo()
        try await installer.install(in: repo.path, socketPath: socket)
        try await installer.uninstall(from: repo.path)
        #expect(!FileManager.default.fileExists(atPath: settingsURL(repo).path))
    }

    // MARK: Gitignore ownership (docs: we create the file, we own the ignore)

    @Test func installedFileIsInvisibleToGitStatus() async throws {
        let repo = try fixtures.cleanRepo()
        try await installer.install(in: repo.path, socketPath: socket)
        let status = try await git.status(in: repo.path)
        #expect(status.isClean, "settings.local.json leaked into git status: \(status.untracked)")
    }

    @Test func excludeCoversLinkedWorktreesToo() async throws {
        let fixture = try fixtures.repoWithAttachedWorktrees(count: 1)
        let worktree = fixture.worktrees[0].path
        try await installer.install(in: worktree, socketPath: socket)

        // Invisible in the worktree it was installed in...
        #expect(try await git.status(in: worktree).isClean)
        // ...and a second install in the main checkout stays invisible too
        // (shared info/exclude, verified in the contract doc).
        try await installer.install(in: fixture.repo.path, socketPath: socket)
        #expect(try await git.status(in: fixture.repo.path).isClean)
    }
}
