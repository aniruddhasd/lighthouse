import Foundation

/// An HONEST context-window occupancy estimate derived from a transcript's
/// last real assistant turn. Framed as an estimate, never an authoritative
/// reading: `usedTokens` is the full prompt size of that turn (uncached +
/// cache-read + cache-creation, which are disjoint and sum to the prompt), and
/// `windowTokens` is the model's known context window. Built ONLY when the
/// model's window is known (see `TranscriptReader.contextWindow`); otherwise
/// the whole estimate is nil and nothing renders.
public struct ContextEstimate: Sendable, Equatable {
    public let usedTokens: Int
    public let windowTokens: Int

    public init(usedTokens: Int, windowTokens: Int) {
        self.usedTokens = usedTokens
        self.windowTokens = windowTokens
    }

    /// 0…1 occupancy. Clamped: a prompt momentarily reported above the window
    /// (rounding, server-side padding) reads as full, never >100%.
    public var fraction: Double {
        guard windowTokens > 0 else { return 0 }
        return min(1, max(0, Double(usedTokens) / Double(windowTokens)))
    }

    /// Whole-percent for display (e.g. 25). Always an estimate.
    public var percent: Int { Int((fraction * 100).rounded()) }
}

/// What a transcript yields for the digest. Each field is best-effort and
/// independently nil-able: a transcript with a readable model but an unknown
/// context window returns `model` set and `context` nil.
public struct TranscriptDigest: Sendable, Equatable {
    public let model: String?
    public let context: ContextEstimate?

    public init(model: String?, context: ContextEstimate?) {
        self.model = model
        self.context = context
    }

    public static let empty = TranscriptDigest(model: nil, context: nil)
}

/// Read-only reader for a Claude Code transcript JSONL (schema verified in
/// docs/claude-code-contract.md, 2026-07-15). Bounded (tails a capped window of
/// bytes — a transcript can be hundreds of MB), malformed-safe (bad/partial
/// JSON is skipped, never throws), and treats every byte as hostile: it reads
/// ONLY `message.model` and the three `message.usage` integer counters, and it
/// sanitises the model id before returning it so a crafted transcript cannot
/// inject arbitrary content into the model chip.
public enum TranscriptReader {
    /// How many trailing bytes to read. The last assistant turn (and its usage)
    /// sits at the very end of the file, so a few hundred KiB is ample while
    /// bounding memory regardless of transcript size.
    public static let defaultTailBytes = 512 * 1024

    /// Reads the transcript at `path`, returning the model + context estimate
    /// from its last non-synthetic assistant turn. Any failure (missing file,
    /// unreadable, empty, all-malformed) degrades to `.empty` — never throws.
    public static func read(path: String, tailBytes: Int = defaultTailBytes) -> TranscriptDigest {
        guard let data = tail(ofFileAt: path, maxBytes: tailBytes), !data.isEmpty else {
            return .empty
        }
        // Split into lines; drop the first line when we tailed mid-file (it is
        // very likely a partial JSON object we must not try to parse).
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        let tailedMidFile = (fileSize(at: path) ?? 0) > data.count
        if tailedMidFile, !lines.isEmpty { lines.removeFirst() }

        // Walk from the end for the last real assistant turn with usable usage.
        for lineBytes in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(lineBytes)),
                  let top = object as? [String: Any],
                  (top["type"] as? String) == "assistant",
                  let message = top["message"] as? [String: Any]
            else { continue }

            let rawModel = message["model"] as? String
            // Synthetic/injected turns are not a real model reading.
            if rawModel == "<synthetic>" { continue }
            let model = sanitizedModel(rawModel)

            var context: ContextEstimate?
            if let usage = message["usage"] as? [String: Any],
               let used = promptTokens(from: usage),
               let resolved = model, let window = contextWindow(forModel: resolved) {
                context = ContextEstimate(usedTokens: used, windowTokens: window)
            }
            // The last turn with a model is authoritative even if the window is
            // unknown (model set, context nil) — stop here.
            if model != nil { return TranscriptDigest(model: model, context: context) }
        }
        return .empty
    }

    /// Prompt-side token total for a turn: uncached + cache-read +
    /// cache-creation. nil unless at least one counter is present (a usage
    /// object with none of them is not a usable reading).
    static func promptTokens(from usage: [String: Any]) -> Int? {
        let keys = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
        var total = 0
        var sawAny = false
        for key in keys {
            if let n = usage[key] as? Int { total += n; sawAny = true }
            else if let d = usage[key] as? Double { total += Int(d); sawAny = true }
        }
        return sawAny ? total : nil
    }

    /// Known context windows (verified 2026-07-15 via the claude-api model
    /// catalog). An unknown model returns nil → the context meter is omitted
    /// rather than estimated against a guessed window.
    static func contextWindow(forModel model: String) -> Int? {
        if model.hasPrefix("claude-opus-4-") { return 1_000_000 }
        if model.hasPrefix("claude-sonnet-5") { return 1_000_000 }
        if model.hasPrefix("claude-sonnet-4-6") { return 1_000_000 }
        if model.hasPrefix("claude-fable-5") { return 1_000_000 }
        if model.hasPrefix("claude-mythos-5") { return 1_000_000 }
        if model.hasPrefix("claude-haiku-4-5") { return 200_000 }
        return nil
    }

    /// Accept a model id only if it looks like one: 1–64 chars of
    /// `[A-Za-z0-9._-]`. A hostile transcript with a huge or markup-laden model
    /// string yields nil (no chip) rather than untrusted content on screen.
    static func sanitizedModel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= 64 else { return nil }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return raw.unicodeScalars.allSatisfy(allowed.contains) ? raw : nil
    }

    // MARK: - Bounded file reading

    private static func fileSize(at path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
    }

    /// Reads at most `maxBytes` from the END of the file. nil on any I/O error
    /// or non-regular file — the caller degrades to `.empty`.
    static func tail(ofFileAt path: String, maxBytes: Int) -> Data? {
        guard maxBytes > 0,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
            try handle.seek(toOffset: start)
            return try handle.readToEnd()
        } catch {
            return nil
        }
    }
}
