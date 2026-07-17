import Foundation
import Testing
@testable import LighthouseAppCore

/// The read-only transcript reader: malformed/hostile/missing cases first, then
/// the honest model + ctx extraction, then bounded-tail behaviour. No real
/// transcript content is used — every fixture is hand-crafted here.
@Suite("TranscriptReader")
struct TranscriptReaderTests {
    /// Writes lines to a throwaway .jsonl and returns its path.
    private func writeTranscript(_ lines: [String]) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").appending("\n").write(
            to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func assistant(model: String, input: Int, cacheRead: Int, cacheCreate: Int) -> String {
        """
        {"type":"assistant","message":{"model":"\(model)","usage":{"input_tokens":\(input),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheCreate),"output_tokens":10}}}
        """
    }

    // MARK: Failure & hostile cases first

    @Test func missingFileDegradesToEmpty() {
        let digest = TranscriptReader.read(path: "/no/such/transcript.jsonl")
        #expect(digest == .empty)
    }

    @Test func allMalformedDegradesToEmptyNoCrash() throws {
        let path = try writeTranscript([
            "not json at all",
            "{unterminated",
            #"{"type":"user","message":{}}"#,
            "]",
        ])
        #expect(TranscriptReader.read(path: path) == .empty)
    }

    @Test func hostileModelStringIsRejected() throws {
        // A crafted model id with markup must not become the model chip.
        let path = try writeTranscript([
            #"{"type":"assistant","message":{"model":"<script>alert(1)</script>","usage":{"input_tokens":100}}}"#,
        ])
        let digest = TranscriptReader.read(path: path)
        #expect(digest.model == nil)
        #expect(digest.context == nil) // no model → no window → no ctx
    }

    @Test func syntheticTurnIsSkipped() throws {
        // The last assistant line is <synthetic>; the real reading is the prior.
        let path = try writeTranscript([
            assistant(model: "claude-opus-4-8", input: 2, cacheRead: 240_000, cacheCreate: 8_000),
            #"{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":2}}}"#,
        ])
        let digest = TranscriptReader.read(path: path)
        #expect(digest.model == "claude-opus-4-8")
        #expect(digest.context?.usedTokens == 248_002) // 2 + 240_000 + 8_000
    }

    @Test func knownModelUnknownWindowOmitsContext() throws {
        // A clean but unmapped model id: model set, ctx omitted (window unknown).
        let path = try writeTranscript([
            assistant(model: "claude-experimental-9", input: 100, cacheRead: 0, cacheCreate: 0),
        ])
        let digest = TranscriptReader.read(path: path)
        #expect(digest.model == "claude-experimental-9")
        #expect(digest.context == nil)
    }

    @Test func usageWithoutTokenCountsOmitsContext() throws {
        let path = try writeTranscript([
            #"{"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"service_tier":"standard"}}}"#,
        ])
        let digest = TranscriptReader.read(path: path)
        #expect(digest.model == "claude-opus-4-8")
        #expect(digest.context == nil)
    }

    // MARK: The honest extraction

    @Test func lastTurnModelAndContextEstimate() throws {
        // used = input + cache_read + cache_creation; window = 1M (opus 4.8);
        // percent = round(246319/1_000_000 * 100) = 25.
        let path = try writeTranscript([
            assistant(model: "claude-opus-4-8", input: 5, cacheRead: 100, cacheCreate: 1),
            assistant(model: "claude-opus-4-8", input: 2, cacheRead: 243_546, cacheCreate: 2_771),
        ])
        let digest = TranscriptReader.read(path: path)
        #expect(digest.model == "claude-opus-4-8")
        #expect(digest.context?.usedTokens == 246_319)
        #expect(digest.context?.windowTokens == 1_000_000)
        #expect(digest.context?.percent == 25)
    }

    @Test func haikuWindowIs200k() throws {
        let path = try writeTranscript([
            assistant(model: "claude-haiku-4-5", input: 100_000, cacheRead: 0, cacheCreate: 0),
        ])
        #expect(TranscriptReader.read(path: path).context?.windowTokens == 200_000)
    }

    @Test func fractionClampsAtOneHundred() {
        let ctx = ContextEstimate(usedTokens: 1_200_000, windowTokens: 1_000_000)
        #expect(ctx.fraction == 1.0)
        #expect(ctx.percent == 100)
    }

    // MARK: Bounded reading

    @Test func smallTailStillFindsLastTurn() throws {
        // Many early assistant turns + a distinctive last one; a small tail must
        // still surface the LAST reading (partial first line dropped safely).
        var lines: [String] = []
        for _ in 0..<200 {
            lines.append(assistant(model: "claude-opus-4-8", input: 1, cacheRead: 1, cacheCreate: 1))
        }
        lines.append(assistant(model: "claude-haiku-4-5", input: 50_000, cacheRead: 0, cacheCreate: 0))
        let path = try writeTranscript(lines)
        let digest = TranscriptReader.read(path: path, tailBytes: 400)
        #expect(digest.model == "claude-haiku-4-5")
        #expect(digest.context?.usedTokens == 50_000)
    }
}
