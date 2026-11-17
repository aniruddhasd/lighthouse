import Foundation

/// The submission channel from the (separate) MCP process to the app: one JSON file
/// per proposal in an owner-only directory, written to a hidden temp file and renamed
/// into place, so the app never observes a half-written submission. File names are
/// UUIDs generated here — never derived from tool input.
/// What the MCP layer needs from the submission channel — a protocol so the tool
/// tests don't touch the filesystem.
public protocol ProposalSubmitting: Sendable {
    func submit(_ draft: ProposalDraft) throws
}

extension ProposalInbox: ProposalSubmitting {
    public func submit(_ draft: ProposalDraft) throws {
        _ = try enqueue(draft)
    }
}

public struct ProposalInbox: Sendable {
    public static let maxFileBytes = 16 * 1024
    public static let directoryName = "supervisor-inbox"

    public enum DrainItem: Equatable, Sendable {
        case draft(ProposalDraft)
        /// A file that could not become a draft (oversize, malformed, not a regular
        /// file). It is removed and reported so it is recorded, not silently lost.
        case invalid(String)
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The inbox that lives under an app config directory.
    public init(configDirectory: URL) {
        self.directory = configDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    // MARK: Writer side (MCP process)

    /// Writes one submission and returns its id (the file's name).
    @discardableResult
    public func enqueue(_ draft: ProposalDraft) throws -> UUID {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(draft)
        guard data.count <= Self.maxFileBytes else {
            throw ProposalRejection(reason: "The proposal is too large.")
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700) // enforce even if it pre-existed looser

        let id = UUID()
        let temp = directory.appendingPathComponent(".\(id.uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.moveItem(
            at: temp, to: directory.appendingPathComponent("\(id.uuidString).json"))
        return id
    }

    // MARK: Reader side (app)

    /// A set of submissions read but NOT yet removed. The app saves the queue first and
    /// only then `discard`s the batch, so a failed save loses nothing — the files are
    /// still there for the next attempt (re-ingesting an identical pending proposal is
    /// a no-op).
    public struct Batch: Sendable {
        public let items: [DrainItem]
        fileprivate let urls: [URL]
    }

    /// Reads up to `limit` submissions (oldest first); the rest wait for the next
    /// pass. A symlink is reported and never followed, and reads are capped no matter
    /// what `stat` said.
    public func take(limit: Int) -> Batch {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [])
        else { return Batch(items: [], urls: []) }

        let candidates = Array(urls
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }
            .prefix(max(limit, 0)))

        var items: [DrainItem] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in candidates {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isSymbolicLink != true, values?.isRegularFile == true else {
                items.append(.invalid("A submission was not a regular file."))
                continue
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                items.append(.invalid("A submission could not be read."))
                continue
            }
            let data = (try? handle.read(upToCount: Self.maxFileBytes + 1)) ?? Data()
            try? handle.close()
            guard data.count <= Self.maxFileBytes else {
                items.append(.invalid("A submission was larger than \(Self.maxFileBytes) bytes."))
                continue
            }
            if let draft = try? decoder.decode(ProposalDraft.self, from: data) {
                items.append(.draft(draft))
            } else {
                items.append(.invalid("A submission was not a valid proposal."))
            }
        }
        return Batch(items: items, urls: candidates)
    }

    /// How many submissions are waiting (cheap directory listing; reads and removes
    /// nothing). Lets the supervisor see work it queued that the app hasn't ingested yet.
    public func pendingCount() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.count
    }

    /// Removes the files of a batch (a symlink is removed as a link, never its target).
    public func discard(_ batch: Batch) {
        for url in batch.urls { try? FileManager.default.removeItem(at: url) }
    }

    /// `take` + `discard` in one step, for callers that have nothing to persist.
    public func drain(limit: Int) -> [DrainItem] {
        let batch = take(limit: limit)
        discard(batch)
        return batch.items
    }
}
