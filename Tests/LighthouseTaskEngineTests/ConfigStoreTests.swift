import Foundation
import Testing
@testable import LighthouseTaskEngine

@Suite("ConfigStore")
final class ConfigStoreTests {
    private let directory: URL
    private let store: ConfigStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lighthouse-config-tests-\(UUID().uuidString)", isDirectory: true)
        store = ConfigStore(directory: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sampleConfig() -> LighthouseConfig {
        let repoFull = RepoConfig(
            path: "/tmp/repos/alpha", baseBranch: "main",
            setupScript: "scripts/setup.sh", envCopyList: [".env", "config/.env.local"])
        let repoMinimal = RepoConfig(path: "/tmp/repos/beta", baseBranch: "develop")
        let task = TaskRecord(
            name: "payments-fix", branch: "task/payments-fix", adapterKind: "claude-code",
            sessionRef: "session-123", status: "waiting on review",
            workspaces: [
                Workspace(repoId: repoFull.id, worktreePath: "/tmp/wt/alpha", mergeState: .conflicted),
                Workspace(repoId: repoMinimal.id, worktreePath: "/tmp/wt/beta", mergeState: .merged),
            ])
        return LighthouseConfig(repos: [repoFull, repoMinimal], tasks: [task])
    }

    // MARK: Broken cases first

    @Test func unknownFutureSchemaVersionFailsLoudAndLeavesFileUntouched() throws {
        let futureFile = Data(#"{"schemaVersion": 99, "somethingNew": true}"#.utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try futureFile.write(to: store.fileURL)

        #expect {
            _ = try self.store.load()
        } throws: { error in
            error as? ConfigStoreError == .unsupportedSchemaVersion(found: 99, newest: 5)
        }
        // Never silently rewritten: byte-identical after the failed load.
        #expect(try Data(contentsOf: store.fileURL) == futureFile)
    }

    @Test func corruptJSONFailsLoud() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.fileURL)
        #expect {
            _ = try self.store.load()
        } throws: { error in
            guard case .corruptConfig = error as? ConfigStoreError else { return false }
            return true
        }
    }

    @Test func versionFieldMissingFailsLoud() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"repos": [], "tasks": []}"#.utf8).write(to: store.fileURL)
        #expect {
            _ = try self.store.load()
        } throws: { error in
            guard case .corruptConfig = error as? ConfigStoreError else { return false }
            return true
        }
    }

    @Test func missingFileMeansFirstLaunchEmptyConfig() throws {
        #expect(try store.load() == .empty)
    }

    // MARK: Guardrail 4 — env CONTENT never reaches the store

    @Test func envFileContentNeverAppearsInStoreDirectory() throws {
        let sentinel = "SUPER_SECRET_API_KEY=sk-live-0123456789abcdef"
        let envDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lighthouse-env-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: envDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: envDir) }
        try Data("\(sentinel)\n".utf8).write(to: envDir.appendingPathComponent(".env"))

        let repo = RepoConfig(path: envDir.path, baseBranch: "main", envCopyList: [".env"])
        try store.save(LighthouseConfig(repos: [repo], tasks: []))

        // Assert on the raw bytes of EVERY file in the store directory.
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!files.isEmpty)
        for file in files {
            let bytes = try Data(contentsOf: directory.appendingPathComponent(file))
            let text = String(decoding: bytes, as: UTF8.self)
            #expect(!text.contains(sentinel), "env content leaked into \(file)")
            #expect(!text.contains("sk-live"), "env content leaked into \(file)")
        }
        // The env PATH (not content) is what belongs in config.
        let stored = try store.load()
        #expect(stored.repos.first?.envCopyList == [".env"])
    }

    // MARK: Round-trips

    @Test func fullFidelityRoundTrip() throws {
        let config = sampleConfig()
        try store.save(config)
        #expect(try store.load() == config)
    }

    @Test func worktreesRootOverrideRoundTrips() throws {
        var config = sampleConfig()
        config.worktreesRootOverride = "/Users/dev/my worktrees"
        try store.save(config)
        #expect(try store.load().worktreesRootOverride == "/Users/dev/my worktrees")
    }

    /// A real v1 file (written before the override existed) must load and
    /// migrate: same repos/tasks, no override configured, worktree paths
    /// untouched (they are per-workspace data, so old-style locations keep
    /// working).
    @Test func v1FileMigratesToCurrentShape() throws {
        let repoId = UUID()
        let v1 = """
        {"schemaVersion": 1,
         "repos": [{"id": "\(repoId.uuidString)", "path": "/tmp/repos/alpha", "baseBranch": "main"}],
         "tasks": [{"id": "\(UUID().uuidString)", "name": "old task", "branch": "task/old",
                    "adapterKind": "claude-code", "state": "done",
                    "workspaces": [{"repoId": "\(repoId.uuidString)",
                                    "worktreePath": "/Users/dev/Lighthouse/old task/alpha",
                                    "mergeState": "unmerged"}]}]}
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(v1.utf8).write(to: store.fileURL)

        let migrated = try store.load()
        #expect(migrated.worktreesRootOverride == nil)
        #expect(migrated.repos.count == 1)
        // v1→v3: a config that already has repos is treated as setup-done.
        #expect(migrated.hasCompletedSetup)
        #expect(!migrated.notificationsHintDismissed)
        #expect(migrated.tasks.first?.workspaces.first?.worktreePath
            == "/Users/dev/Lighthouse/old task/alpha")
    }

    @Test func v2FileMigratesAndSetsSetupDoneWhenReposExist() throws {
        let repoId = UUID()
        let v2 = """
        {"schemaVersion": 2, "worktreesRootOverride": "/custom",
         "repos": [{"id": "\(repoId.uuidString)", "path": "/tmp/r", "baseBranch": "main"}],
         "tasks": []}
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(v2.utf8).write(to: store.fileURL)
        let migrated = try store.load()
        #expect(migrated.worktreesRootOverride == "/custom")
        #expect(migrated.hasCompletedSetup) // repos present → don't re-ambush
    }

    @Test func setupFlagsRoundTripInV3() throws {
        var config = sampleConfig()
        config.hasCompletedSetup = true
        config.notificationsHintDismissed = true
        try store.save(config)
        let loaded = try store.load()
        #expect(loaded.hasCompletedSetup)
        #expect(loaded.notificationsHintDismissed)
    }

    @Test func optionalFieldsAbsentRoundTrip() throws {
        let config = LighthouseConfig(
            repos: [RepoConfig(path: "/tmp/r", baseBranch: "main")],
            tasks: [TaskRecord(
                name: "t", branch: "task/t", adapterKind: "claude-code",
                sessionRef: nil, workspaces: [])])
        try store.save(config)
        let loaded = try store.load()
        #expect(loaded == config)
        #expect(loaded.repos[0].setupScript == nil)
        #expect(loaded.repos[0].envCopyList == nil)
        #expect(loaded.tasks[0].sessionRef == nil)
    }

    @Test func saveReplacesAtomicallyAndLeavesNoTempFiles() throws {
        try store.save(sampleConfig())
        let second = LighthouseConfig(repos: [], tasks: [])
        try store.save(second)
        #expect(try store.load() == second)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files == [ConfigStore.fileName])
    }

    @Test func schemaVersionIsWrittenFromDayOne() throws {
        try store.save(.empty)
        let text = String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self)
        #expect(text.contains(#""schemaVersion" : 5"#))
    }

    // MARK: v3 → v4 (theme + start-view + beam preferences)

    /// A real v3 file (written before the theme existed) must load and migrate:
    /// existing fields preserved, the new preferences defaulted (beacon / harbor
    /// / true) rather than crashing or blanking.
    @Test func v3FileMigratesToV4WithDefaultPreferences() throws {
        let repoId = UUID()
        let v3 = """
        {"schemaVersion": 3, "worktreesRootOverride": "/custom",
         "hasCompletedSetup": true, "notificationsHintDismissed": true,
         "repos": [{"id": "\(repoId.uuidString)", "path": "/tmp/r", "baseBranch": "main"}],
         "tasks": []}
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(v3.utf8).write(to: store.fileURL)

        let migrated = try store.load()
        // Existing fields survive.
        #expect(migrated.worktreesRootOverride == "/custom")
        #expect(migrated.hasCompletedSetup)
        #expect(migrated.notificationsHintDismissed)
        #expect(migrated.repos.count == 1)
        // New preferences default.
        #expect(migrated.theme == "beacon")
        #expect(migrated.startView == "harbor")
        #expect(migrated.showBeam == true)
    }

    /// A v4 file round-trips every new preference (non-default values, so the
    /// test fails if any field is dropped or defaulted on the way through).
    @Test func v4PreferencesRoundTrip() throws {
        var config = sampleConfig()
        config.theme = "native"
        config.startView = "focus"
        config.showBeam = false
        try store.save(config)
        let loaded = try store.load()
        #expect(loaded.theme == "native")
        #expect(loaded.startView == "focus")
        #expect(loaded.showBeam == false)
        #expect(loaded == config)
    }

    // MARK: v4 → v5 (terminal font size)

    /// A real v4 file (written before the terminal font size existed) must load
    /// and migrate: existing preferences preserved, the font size defaulted
    /// rather than crashing or blanking.
    @Test func v4FileMigratesToV5WithDefaultFontSize() throws {
        let v4 = """
        {"schemaVersion": 4, "worktreesRootOverride": null,
         "hasCompletedSetup": true, "notificationsHintDismissed": false,
         "theme": "native", "startView": "focus", "showBeam": false,
         "repos": [], "tasks": []}
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(v4.utf8).write(to: store.fileURL)

        let migrated = try store.load()
        // Existing preferences survive.
        #expect(migrated.theme == "native")
        #expect(migrated.startView == "focus")
        #expect(migrated.showBeam == false)
        // The new field defaults.
        #expect(migrated.terminalFontSize == LighthouseConfig.defaultTerminalFontSize)
    }

    /// A v5 file round-trips a non-default font size (fails if the field is
    /// dropped or defaulted on the way through).
    @Test func v5TerminalFontSizeRoundTrips() throws {
        var config = sampleConfig()
        config.terminalFontSize = 11
        try store.save(config)
        let loaded = try store.load()
        #expect(loaded.terminalFontSize == 11)
        #expect(loaded == config)
    }
}
