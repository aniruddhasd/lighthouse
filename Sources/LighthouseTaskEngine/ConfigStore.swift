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
    /// Persisted UI theme (schema v4). Raw string ("beacon" / "native") so this
    /// value layer stays free of SwiftUI; the app maps it to its Theme enum and
    /// treats an unknown value as the default. Only this field is wired to the
    /// UI in Phase 1.
    public var theme: String
    /// Preferred landing view (schema v4): "harbor" / "focus". STORED-BUT-UNUSED
    /// in Phase 1 — persisted now so the two-mode shell (Phase 2) needs no
    /// second migration.
    public var startView: String
    /// Ambient Harbor beam on/off (schema v4). STORED-BUT-UNUSED in Phase 1 —
    /// consumed by the motion pass (Phase 5); persisted now to avoid a second
    /// migration.
    public var showBeam: Bool
    /// Terminal font point size (schema v5). Drives the SwiftTerm font in every
    /// session; adjustable from Preferences. Clamped by the app to a sane range.
    public var terminalFontSize: Double

    /// The default terminal font size when none is persisted (schema < v5).
    public static let defaultTerminalFontSize: Double = 13

    public init(
        repos: [RepoConfig] = [], tasks: [TaskRecord] = [],
        worktreesRootOverride: String? = nil,
        hasCompletedSetup: Bool = false,
        notificationsHintDismissed: Bool = false,
        theme: String = "beacon",
        startView: String = "harbor",
        showBeam: Bool = true,
        terminalFontSize: Double = LighthouseConfig.defaultTerminalFontSize
    ) {
        self.repos = repos
        self.tasks = tasks
        self.worktreesRootOverride = worktreesRootOverride
        self.hasCompletedSetup = hasCompletedSetup
        self.notificationsHintDismissed = notificationsHintDismissed
        self.theme = theme
        self.startView = startView
        self.showBeam = showBeam
        self.terminalFontSize = terminalFontSize
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
    public static let currentSchemaVersion = 5
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
            // v3 → v4: no theme/startView/showBeam recorded yet — the init
            // defaults them (beacon / harbor / true). Everything else passes
            // through untouched.
            return LighthouseConfig(
                repos: stored.repos, tasks: stored.tasks,
                worktreesRootOverride: stored.worktreesRootOverride,
                hasCompletedSetup: stored.hasCompletedSetup,
                notificationsHintDismissed: stored.notificationsHintDismissed)
        case 4:
            let stored: StoredConfigV4
            do {
                stored = try decoder.decode(StoredConfigV4.self, from: data)
            } catch {
                throw ConfigStoreError.corruptConfig(path: fileURL.path, detail: String(describing: error))
            }
            // v4 → v5: no terminal font size recorded yet — the init defaults it
            // (defaultTerminalFontSize). Everything else passes through.
            return LighthouseConfig(
                repos: stored.repos, tasks: stored.tasks,
                worktreesRootOverride: stored.worktreesRootOverride,
                hasCompletedSetup: stored.hasCompletedSetup,
                notificationsHintDismissed: stored.notificationsHintDismissed,
                theme: stored.theme,
                startView: stored.startView,
                showBeam: stored.showBeam)
        case 5:
            let stored: StoredConfigV5
            do {
                stored = try decoder.decode(StoredConfigV5.self, from: data)
            } catch {
                throw ConfigStoreError.corruptConfig(path: fileURL.path, detail: String(describing: error))
            }
            return LighthouseConfig(
                repos: stored.repos, tasks: stored.tasks,
                worktreesRootOverride: stored.worktreesRootOverride,
                hasCompletedSetup: stored.hasCompletedSetup,
                notificationsHintDismissed: stored.notificationsHintDismissed,
                theme: stored.theme,
                startView: stored.startView,
                showBeam: stored.showBeam,
                terminalFontSize: stored.terminalFontSize)
        default:
            throw ConfigStoreError.unsupportedSchemaVersion(
                found: probe.schemaVersion, newest: Self.currentSchemaVersion)
        }
    }

    public func save(_ config: LighthouseConfig) throws {
        let stored = StoredConfigV5(
            schemaVersion: Self.currentSchemaVersion,
            repos: config.repos,
            tasks: config.tasks,
            worktreesRootOverride: config.worktreesRootOverride,
            hasCompletedSetup: config.hasCompletedSetup,
            notificationsHintDismissed: config.notificationsHintDismissed,
            theme: config.theme,
            startView: config.startView,
            showBeam: config.showBeam,
            terminalFontSize: config.terminalFontSize)
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

    /// v4 (2026-07-15): adds the persisted UI theme plus start-view and
    /// ambient-beam preferences (the latter two stored-but-unused until later
    /// redesign phases — persisted now so there is no second migration).
    private struct StoredConfigV4: Codable {
        var schemaVersion: Int
        var repos: [RepoConfig]
        var tasks: [TaskRecord]
        var worktreesRootOverride: String?
        var hasCompletedSetup: Bool
        var notificationsHintDismissed: Bool
        var theme: String
        var startView: String
        var showBeam: Bool
    }

    /// v5 (2026-07-17): adds the persisted terminal font size. Everything else
    /// carries over from v4 unchanged.
    private struct StoredConfigV5: Codable {
        var schemaVersion: Int
        var repos: [RepoConfig]
        var tasks: [TaskRecord]
        var worktreesRootOverride: String?
        var hasCompletedSetup: Bool
        var notificationsHintDismissed: Bool
        var theme: String
        var startView: String
        var showBeam: Bool
        var terminalFontSize: Double
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
