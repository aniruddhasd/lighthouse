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
            sessionRef: "session-123", state: .needsInput,
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
            error as? ConfigStoreError == .unsupportedSchemaVersion(found: 99, newest: 1)
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

    @Test func optionalFieldsAbsentRoundTrip() throws {
        let config = LighthouseConfig(
            repos: [RepoConfig(path: "/tmp/r", baseBranch: "main")],
            tasks: [TaskRecord(
                name: "t", branch: "task/t", adapterKind: "claude-code",
                sessionRef: nil, state: .done, workspaces: [])])
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
        #expect(text.contains(#""schemaVersion" : 1"#))
    }
}
