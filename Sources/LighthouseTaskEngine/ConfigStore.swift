import Foundation

/// Everything Lighthouse persists. Secrets are never part of this shape:
/// env files are copied between worktrees at creation but their CONTENT is
/// never read into config (guardrail 4).
public struct LighthouseConfig: Codable, Sendable, Equatable {
    public var repos: [RepoConfig]
    public var tasks: [TaskRecord]
    /// Global override for where task worktrees are created. nil (the
    /// default) derives the location per repo — `<repo parent>/
    /// lighthouse-worktrees/<task>/<repo>` — which keeps sessions inside the
    /// directory trees that cwd-keyed tooling (per-folder account selectors,
    /// direnv) watches. Added in schema v2.
    public var worktreesRootOverride: String?
    /// First-run setup has been completed at least once (schema v3). Controls
    /// whether the setup sheet auto-opens; the sheet is always re-runnable
    /// from Help → Run Setup Checks.
    public var hasCompletedSetup: Bool
    /// The "notifications are off" inbox hint has been dismissed (schema v3) —
    /// shown once, never nagging.
    public var notificationsHintDismissed: Bool

    public init(
        repos: [RepoConfig] = [], tasks: [TaskRecord] = [],
        worktreesRootOverride: String? = nil,
        hasCompletedSetup: Bool = false,
        notificationsHintDismissed: Bool = false
    ) {
        self.repos = repos
        self.tasks = tasks
        self.worktreesRootOverride = worktreesRootOverride
        self.hasCompletedSetup = hasCompletedSetup
        self.notificationsHintDismissed = notificationsHintDismissed
    }

    public static let empty = LighthouseConfig()
}

public enum ConfigStoreError: Error, Sendable, Equatable {
    /// The file declares a schema version this build does not understand.
    /// The file is left byte-identical — never silently rewritten.
    case unsupportedSchemaVersion(found: Int, newest: Int)
    /// The file exists but is not valid config JSON.
    case corruptConfig(path: String, detail: String)
    case ioFailure(path: String, detail: String)
}

/// Schema-versioned JSON store with atomic writes (write temp file in the
/// same directory, then rename over the target). The directory is injected;
/// production uses `ConfigStore.defaultDirectory()`, tests use temp dirs.
public struct ConfigStore: Sendable {
    public static let currentSchemaVersion = 3
    public static let fileName = "config.json"

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/Lighthouse/` — production location.
    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lighthouse", isDirectory: true)
    }

    /// Missing file means first launch: an empty config, not an error.
    public func load() throws -> LighthouseConfig {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .empty
        } catch {
            throw ConfigStoreError.ioFailure(path: fileURL.path, detail: String(describing: error))
        }

        let decoder = JSONDecoder()
        let probe: SchemaVersionProbe
        do {
            probe = try decoder.decode(SchemaVersionProbe.self, from: data)
        } catch {
            throw ConfigStoreError.corruptConfig(path: fileURL.path, detail: String(describing: error))
        }

        // Version dispatch. Each historical version gets a case and a
        // migration to the current shape; an unknown (future) version fails
        // loud so a newer app's config is never destroyed by an older build.
        switch probe.schemaVersion {
        case 1:
            let stored: StoredConfigV1
            do {
                stored = try decoder.decode(StoredConfigV1.self, from: data)
            } catch {
                throw ConfigStoreError.corruptConfig(path: fileURL.path, detail: String(describing: error))
            }
            return Self.migrateV1(stored)
        case 2:
            let stored: StoredConfigV2
            do {
                stored = try decoder.decode(StoredConfigV2.self, from: data)
            } catch {
                throw ConfigStoreError.corruptConfig(path: fileURL.path, detail: String(describing: error))
            }
            // v2 → current: no setup flags recorded yet. A migrated config
            // has repos, so setup is effectively done (don't re-ambush).
            return LighthouseConfig(
                repos: stored.repos, tasks: stored.tasks,
                worktreesRootOverride: stored.worktreesRootOverride,
                hasCompletedSetup: !stored.repos.isEmpty,
                notificationsHintDismissed: false)
        case 3:
            let stored: StoredConfigV3
            do {
                stored = try decoder.decode(StoredConfigV3.self, from: data)
            } catch {
                throw ConfigStoreError.corruptConfig(path: fileURL.path, detail: String(describing: error))
            }
            return LighthouseConfig(
                repos: stored.repos, tasks: stored.tasks,
                worktreesRootOverride: stored.worktreesRootOverride,
                hasCompletedSetup: stored.hasCompletedSetup,
                notificationsHintDismissed: stored.notificationsHintDismissed)
        default:
            throw ConfigStoreError.unsupportedSchemaVersion(
                found: probe.schemaVersion, newest: Self.currentSchemaVersion)
        }
    }

    public func save(_ config: LighthouseConfig) throws {
        let stored = StoredConfigV3(
            schemaVersion: Self.currentSchemaVersion,
            repos: config.repos,
            tasks: config.tasks,
            worktreesRootOverride: config.worktreesRootOverride,
            hasCompletedSetup: config.hasCompletedSetup,
            notificationsHintDismissed: config.notificationsHintDismissed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(stored)
        } catch {
            throw ConfigStoreError.ioFailure(path: fileURL.path, detail: String(describing: error))
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Atomic: temp file in the SAME directory (same filesystem), then
            // rename(2), which atomically replaces any existing target.
            let temp = directory.appendingPathComponent(".\(Self.fileName).tmp-\(UUID().uuidString)")
            try data.write(to: temp)
            guard rename(temp.path, fileURL.path) == 0 else {
                let code = errno
                try? FileManager.default.removeItem(at: temp)
                throw ConfigStoreError.ioFailure(
                    path: fileURL.path, detail: "rename failed: \(String(cString: strerror(code)))")
            }
        } catch let error as ConfigStoreError {
            throw error
        } catch {
            throw ConfigStoreError.ioFailure(path: fileURL.path, detail: String(describing: error))
        }
    }

    // MARK: - Versioned shapes

    private struct SchemaVersionProbe: Decodable {
        let schemaVersion: Int
    }

    private struct StoredConfigV1: Codable {
        var schemaVersion: Int
        var repos: [RepoConfig]
        var tasks: [TaskRecord]
    }

    /// v2 (2026-07-12): adds the optional global worktrees-root override;
    /// default (absent) means per-repo derivation next to each repo.
    private struct StoredConfigV2: Codable {
        var schemaVersion: Int
        var repos: [RepoConfig]
        var tasks: [TaskRecord]
        var worktreesRootOverride: String?
    }

    /// v3 (2026-07-14): adds first-run setup flags.
    private struct StoredConfigV3: Codable {
        var schemaVersion: Int
        var repos: [RepoConfig]
        var tasks: [TaskRecord]
        var worktreesRootOverride: String?
        var hasCompletedSetup: Bool
        var notificationsHintDismissed: Bool
    }

    /// v1 → current: same repos/tasks; no override configured; setup treated
    /// as done iff repos already exist. Existing tasks keep their persisted
    /// per-workspace worktreePath values, so old worktree locations still work.
    private static func migrateV1(_ stored: StoredConfigV1) -> LighthouseConfig {
        LighthouseConfig(
            repos: stored.repos, tasks: stored.tasks, worktreesRootOverride: nil,
            hasCompletedSetup: !stored.repos.isEmpty, notificationsHintDismissed: false)
    }
}
