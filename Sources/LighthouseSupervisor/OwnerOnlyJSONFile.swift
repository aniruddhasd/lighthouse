import Foundation

/// Atomic, owner-only persistence of one JSON value — the one place this rule lives.
/// The directory is created 0700 and the file is born 0600 as a temp file, then renamed
/// over the target: owner-only at every instant and never truncated by a crash mid-write.
/// The app is the only writer of anything stored this way.
public struct OwnerOnlyJSONFile<Value: Codable & Sendable>: Sendable {
    private let directory: URL
    private let fileName: String

    public init(directory: URL, fileName: String) {
        self.directory = directory
        self.fileName = fileName
    }

    public var url: URL { directory.appendingPathComponent(fileName) }

    /// A missing file is `nil` (the caller picks the default); a corrupt one THROWS,
    /// because an empty answer would let the next save destroy what could not be read.
    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Value.self, from: Data(contentsOf: url))
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try Self.write(try encoder.encode(value), to: url)
    }

    /// Owner-only atomic replace of arbitrary bytes (also used for files the supervisor
    /// process reads, such as its generated MCP config).
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
}
