import Foundation
import Testing
import LighthouseGit
@testable import LighthouseAppCore

/// The digest cache: baked timing (incl. the failure paths), the known-zero vs
/// unknown diff distinction, action sanitising, and present-vs-absent assembly.
@MainActor
@Suite("TaskDigestCache")
struct TaskDigestTests {
    // MARK: Absent-by-default

    @Test func emptyDigestIsAllBlank() {
        let cache = TaskDigestCache()
        let d = cache.digest(for: UUID())
        #expect(d.diffStat == nil && d.baked == nil && d.model == nil
            && d.context == nil && d.action == nil)
    }

    // MARK: baked timing (deterministic clocks)

    @Test func bakedIsTheTurnDuration() {
        let cache = TaskDigestCache()
        let id = UUID()
        let t0 = Date()
        cache.noteWorkStarted(taskId: id, at: t0)
        cache.recordStop(taskId: id, action: nil, at: t0.addingTimeInterval(2))
        #expect(cache.digest(for: id).baked == 2)
    }

    @Test func bakedNilWithoutAStart() {
        let cache = TaskDigestCache()
        let id = UUID()
        cache.recordStop(taskId: id, action: "done", at: Date())
        #expect(cache.digest(for: id).baked == nil)
    }

    @Test func bakedNilWhenClockGoesBackward() {
        let cache = TaskDigestCache()
        let id = UUID()
        let t0 = Date()
        cache.noteWorkStarted(taskId: id, at: t0)
        cache.recordStop(taskId: id, action: nil, at: t0.addingTimeInterval(-5))
        #expect(cache.digest(for: id).baked == nil)
    }

    @Test func startIsConsumedSoASecondStopKeepsTheLastMeasuredBaked() {
        let cache = TaskDigestCache()
        let id = UUID()
        let t0 = Date()
        cache.noteWorkStarted(taskId: id, at: t0)
        cache.recordStop(taskId: id, action: nil, at: t0.addingTimeInterval(3)) // measures 3s
        cache.recordStop(taskId: id, action: nil, at: t0.addingTimeInterval(9)) // no start now
        // The start was consumed, so the second stop can't measure a new turn —
        // it keeps the last real measurement rather than clobbering it to nil.
        #expect(cache.digest(for: id).baked == 3)
    }

    // MARK: known-zero vs unknown diff

    @Test func nilDiffIsUnknownZeroDiffIsKnown() {
        let cache = TaskDigestCache()
        let id = UUID()
        #expect(cache.digest(for: id).diffStat == nil)          // unknown → blank
        cache.setDiffStat(taskId: id, .zero)
        #expect(cache.digest(for: id).diffStat == DiffStat.zero) // known zero → renders 0
        cache.setDiffStat(taskId: id, nil)
        #expect(cache.digest(for: id).diffStat == nil)          // back to unknown
    }

    // MARK: action sanitising (untrusted)

    @Test func emptyOrWhitespaceActionBecomesNil() {
        #expect(TaskDigestCache.sanitizedAction(nil) == nil)
        #expect(TaskDigestCache.sanitizedAction("") == nil)
        #expect(TaskDigestCache.sanitizedAction("   \n\t ") == nil)
    }

    @Test func hostileActionIsKeptVerbatimNotInterpreted() {
        let hostile = "<script>alert(1)</script> **not bold** [x](y)"
        #expect(TaskDigestCache.sanitizedAction(hostile) == hostile)
    }

    @Test func overlongActionIsClamped() {
        let long = String(repeating: "x", count: TaskDigestCache.maxActionChars + 500)
        #expect(TaskDigestCache.sanitizedAction(long)?.count == TaskDigestCache.maxActionChars)
    }

    // MARK: assembly + removal

    @Test func fieldsLandIndependently() {
        let cache = TaskDigestCache()
        let id = UUID()
        cache.setDiffStat(taskId: id, DiffStat(filesChanged: 2, added: 5, deleted: 1))
        cache.setTranscript(
            taskId: id, model: "claude-opus-4-8",
            context: ContextEstimate(usedTokens: 250_000, windowTokens: 1_000_000))
        cache.recordStop(taskId: id, action: "shipped", at: Date())
        let d = cache.digest(for: id)
        #expect(d.diffStat?.added == 5)
        #expect(d.model == "claude-opus-4-8")
        #expect(d.context?.percent == 25)
        #expect(d.action == "shipped")
    }

    @Test func transcriptCanSetModelWithoutContext() {
        let cache = TaskDigestCache()
        let id = UUID()
        cache.setTranscript(taskId: id, model: "claude-experimental-9", context: nil)
        #expect(cache.digest(for: id).model == "claude-experimental-9")
        #expect(cache.digest(for: id).context == nil)
    }

    @Test func removeClearsEverything() {
        let cache = TaskDigestCache()
        let id = UUID()
        cache.setDiffStat(taskId: id, .zero)
        cache.remove(taskId: id)
        #expect(cache.digest(for: id).diffStat == nil)
    }
}
