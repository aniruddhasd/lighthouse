import Foundation

/// Everything Lighthouse persists. Secrets are never part of this shape:
/// env files are copied between worktrees at creation but their CONTENT is
/// never read into config (guardrail 4).
public struct LighthouseConfig: Codable, Sendable, Equatable {
    public var repos: [RepoConfig]
    public var tasks: [TaskRecord]

    public init(repos: [RepoConfig] = [], tasks: [TaskRecord] = []) {
        self.repos = repos
        self.tasks = tasks
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
    public static let currentSchemaVersion = 1
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
        default:
            throw ConfigStoreError.unsupportedSchemaVersion(
                found: probe.schemaVersion, newest: Self.currentSchemaVersion)
        }
    }

    public func save(_ config: LighthouseConfig) throws {
        let stored = StoredConfigV1(
            schemaVersion: Self.currentSchemaVersion,
            repos: config.repos,
            tasks: config.tasks)
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

    /// v1 is the current shape: identity migration. The dispatch above is the
    /// mechanism future versions plug into.
    private static func migrateV1(_ stored: StoredConfigV1) -> LighthouseConfig {
        LighthouseConfig(repos: stored.repos, tasks: stored.tasks)
    }
}
