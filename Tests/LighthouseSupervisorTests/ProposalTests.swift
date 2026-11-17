import Foundation
import Testing
import LighthouseTaskEngine
@testable import LighthouseSupervisor

private func task(_ name: String, supervised: Bool = true) -> TaskRecord {
    TaskRecord(name: name, branch: "b", adapterKind: "c", sessionRef: "s-\(name)", supervised: supervised, workspaces: [])
}

private func draft(
    _ kind: ProposalKind = .send, task: String = "a", text: String = "please rebase onto develop",
    reason: String = "turn finished", basedOn: Date? = Date(timeIntervalSince1970: 100)
) -> ProposalDraft {
    ProposalDraft(kind: kind, task: task, text: text, reason: reason, basedOn: basedOn)
}

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("lh-prop-\(UUID().uuidString.prefix(8))")
}

// MARK: - Validator

@Suite("ProposalValidator")
struct ProposalValidatorTests {
    private let tasks = [task("a"), task("hidden", supervised: false)]

    private func reason(_ d: ProposalDraft) -> String? {
        do { _ = try ProposalValidator.validate(d, tasks: tasks); return nil }
        catch let e as ProposalRejection { return e.reason }
        catch { return "other: \(error)" }
    }

    // Keystroke smuggling: a `send` is typed into a pty. Each of these would act as
    // a key press there, so none may get through — and the check runs on the RAW text
    // (a trailing newline would submit the line; trimming first would hide it).
    @Test(arguments: ["hello\n", "hello\r", "a\tb", "\u{1B}[31mred", "x\u{7F}", "\u{03}", "\u{04}",
                      "line1\nline2", "\u{85}next", "a\u{2028}b", "a\u{2029}b"])
    func controlCharactersAreRejectedInText(_ text: String) {
        #expect(reason(draft(text: text)) != nil, "text \(text.debugDescription) must be rejected")
    }

    @Test func controlCharactersAreRejectedInReasonToo() {
        #expect(reason(draft(reason: "why\u{1B}[2J")) != nil)
        #expect(reason(draft(reason: "a\nb")) != nil)
    }

    @Test func emptyOrWhitespaceTextAndReasonRejected() {
        #expect(reason(draft(text: "")) != nil)
        #expect(reason(draft(text: "   ")) != nil)
        #expect(reason(draft(reason: "")) != nil)
        #expect(reason(draft(reason: "  ")) != nil)
    }

    @Test func overLengthRejectedAtBoundaryInclusive() {
        #expect(reason(draft(text: String(repeating: "x", count: ProposalValidator.maxTextChars))) == nil)
        #expect(reason(draft(text: String(repeating: "x", count: ProposalValidator.maxTextChars + 1))) != nil)
        #expect(reason(draft(reason: String(repeating: "x", count: ProposalValidator.maxReasonChars + 1))) != nil)
    }

    @Test func sendRequiresBasedOnButTheOthersDoNot() {
        #expect(reason(draft(.send, basedOn: nil)) != nil)
        #expect(reason(draft(.hold, basedOn: nil)) == nil)
        #expect(reason(draft(.askUser, basedOn: nil)) == nil)
    }

    @Test func unsupervisedAndUnknownTasksAreRejectedIdentically() {
        let a = reason(draft(task: "hidden")), b = reason(draft(task: "nope"))
        #expect(a != nil)
        #expect(a?.replacingOccurrences(of: "hidden", with: "X") == b?.replacingOccurrences(of: "nope", with: "X"))
    }

    @Test func validDraftIsNormalizedAndResolved() throws {
        let t = tasks[0]
        let v = try ProposalValidator.validate(draft(task: t.id.uuidString, text: "  go ahead  ", reason: " ok "), tasks: tasks)
        #expect(v.taskId == t.id && v.draft.text == "go ahead" && v.draft.reason == "ok")
    }

    // The agent's prompt box gives some leading characters meaning (slash commands, shell
    // mode, …), and the exact list isn't something we should rely on from memory. So a
    // `send` is deny-by-default: it must START with a letter or digit.
    @Test(arguments: ["!ls", "/clear", "#note", "@file", "-x", "$HOME", "\"quoted\"", "'x'", "(x)",
                      "[x]", "\\n", "?", "👍 ok", "…and then", "*bold*", "> quote", "~/x", "| pipe", "; ls"])
    func aSendMustStartWithALetterOrDigit(_ text: String) {
        #expect(reason(draft(.send, text: text)) != nil, "\(text.debugDescription) must be rejected")
    }

    @Test func leadingWhitespaceDoesNotHideAForbiddenFirstCharacter() {
        #expect(reason(draft(.send, text: "   /clear")) != nil)
        #expect(reason(draft(.send, text: "  go ahead")) == nil, "trimmed text starts with a letter")
    }

    @Test(arguments: ["Rebase onto develop", "9 failing tests remain", "café ✓ — retry", "日本語 step"])
    func lettersAndDigitsStartAnyScript(_ text: String) {
        #expect(reason(draft(.send, text: text)) == nil)
    }

    @Test func holdAndAskUserTextIsNeverTypedSoItMayStartWithAnything() {
        #expect(reason(draft(.hold, text: "! VPN is down")) == nil)
        #expect(reason(draft(.askUser, text: "/clear or keep?")) == nil)
    }

    @Test func ordinaryUnicodeIsAllowed() {
        #expect(reason(draft(text: "café ✓ — retry the 日本語 step 👍")) == nil)
    }
}

// MARK: - Queue

@Suite("ProposalQueue")
struct ProposalQueueTests {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let a = task("a")

    @Test func rejectedDraftsAreRecordedWithAReasonNotDropped() {
        var q = ProposalQueue()
        let p = q.ingest(draft(text: "bad\n"), tasks: [a], now: now)
        #expect(p.status == .rejected && p.rejectionReason != nil)
        #expect(p.taskId == a.id, "a resolvable task is linked so the rejection shows on its card")
        #expect(!p.text.unicodeScalars.contains { $0.properties.generalCategory == .control },
                "stored rejected text must not carry control characters")
        #expect(q.entries.count == 1)
    }

    @Test func unknownTaskRejectionKeepsOnlyABoundedRef() {
        var q = ProposalQueue()
        let p = q.ingest(draft(task: String(repeating: "z", count: 500)), tasks: [a], now: now)
        #expect(p.status == .rejected && p.taskRef.count <= 80 && p.taskId == nil)
    }

    @Test func duplicatePendingIsNotAddedTwice() {
        var q = ProposalQueue()
        let first = q.ingest(draft(task: "a"), tasks: [a], now: now)
        let second = q.ingest(draft(task: "a"), tasks: [a], now: now.addingTimeInterval(5))
        #expect(first.id == second.id && q.entries.count == 1)
    }

    @Test func perTaskPendingCapRejectsTheExcess() {
        var q = ProposalQueue()
        for i in 0..<ProposalQueue.maxPendingPerTask {
            let accepted = q.ingest(draft(text: "t\(i)"), tasks: [a], now: now)
            #expect(accepted.status == .pending)
        }
        let over = q.ingest(draft(text: "one too many"), tasks: [a], now: now)
        #expect(over.status == .rejected && over.rejectionReason?.contains("pending") == true)
    }

    @Test func totalCapPrunesOldestNonPendingFirstAndNeverAPending() {
        var q = ProposalQueue()
        let p = q.ingest(draft(text: "keep me"), tasks: [a], now: now)   // pending, oldest
        for i in 0..<(ProposalQueue.maxEntries + 20) {
            _ = q.ingest(draft(task: "nope", text: "bad\(i)"), tasks: [a], now: now.addingTimeInterval(Double(i)))
        }
        #expect(q.entries.count <= ProposalQueue.maxEntries)
        #expect(q.entries.contains { $0.id == p.id }, "a pending proposal must survive pruning")
    }

    @Test func dismissWorksOnceAndOnlyOnPending() {
        var q = ProposalQueue()
        let p = q.ingest(draft(), tasks: [a], now: now)
        let first = q.dismiss(p.id)
        #expect(first)
        #expect(q.entries[0].status == .dismissed)
        let again = q.dismiss(p.id), unknown = q.dismiss(UUID())
        #expect(!again, "already dismissed")
        #expect(!unknown, "unknown id")
        #expect(q.pending(for: a.id).isEmpty)
    }

    @Test func dismissedDuplicateCanBeProposedAgain() {
        var q = ProposalQueue()
        let p = q.ingest(draft(), tasks: [a], now: now)
        _ = q.dismiss(p.id)
        let again = q.ingest(draft(), tasks: [a], now: now)
        #expect(again.status == .pending)
    }
}

// MARK: - Inbox

@Suite("ProposalInbox")
struct ProposalInboxTests {
    private func inbox() -> (ProposalInbox, URL) {
        let dir = tempDir(); return (ProposalInbox(directory: dir), dir)
    }

    @Test func submitThenDrainRoundTripsAndRemovesTheFile() throws {
        let (box, dir) = inbox(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = try box.enqueue(draft(text: "hello"))
        let files = try FileManager.default.contentsOfDirectory(atPath: box.directory.path)
        #expect(files == ["\(id.uuidString).json"], "exactly one finished file, no temp left behind")
        let items = box.drain(limit: 10)
        #expect(items.count == 1)
        if case .draft(let d) = items[0] { #expect(d.text == "hello") } else { Issue.record("expected a draft") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.directory.path).isEmpty)
    }

    @Test func directoryIsOwnerOnlyAndFilesAreTooBeforeTheyAreVisible() throws {
        let (box, dir) = inbox(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = try box.enqueue(draft())
        let dperm = try #require((try FileManager.default.attributesOfItem(atPath: box.directory.path))[.posixPermissions] as? NSNumber)
        let fperm = try #require((try FileManager.default.attributesOfItem(
            atPath: box.directory.appendingPathComponent("\(id.uuidString).json").path))[.posixPermissions] as? NSNumber)
        #expect(dperm.uint16Value & 0o777 == 0o700 && fperm.uint16Value & 0o777 == 0o600)
    }

    @Test func malformedAndOversizeFilesBecomeInvalidItemsAndAreRemoved() throws {
        let (box, dir) = inbox(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: box.directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: box.directory.appendingPathComponent("\(UUID().uuidString).json"))
        try Data(repeating: 0x41, count: ProposalInbox.maxFileBytes + 1)
            .write(to: box.directory.appendingPathComponent("\(UUID().uuidString).json"))
        let items = box.drain(limit: 10)
        #expect(items.count == 2)
        #expect(items.allSatisfy { if case .invalid = $0 { return true } else { return false } })
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.directory.path).isEmpty)
    }

    @Test func aSymlinkIsNeverFollowedAndItsTargetIsUntouched() throws {
        let (box, dir) = inbox(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: box.directory, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("secret.txt")
        try Data("do-not-read-or-delete".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: box.directory.appendingPathComponent("\(UUID().uuidString).json"), withDestinationURL: target)
        let items = box.drain(limit: 10)
        #expect(items.count == 1)
        if case .draft = items[0] { Issue.record("a symlink must not become a draft") }
        #expect(try String(contentsOf: target, encoding: .utf8) == "do-not-read-or-delete")
    }

    @Test func tempFilesAndForeignNamesAreIgnored() throws {
        let (box, dir) = inbox(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: box.directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: box.directory.appendingPathComponent(".\(UUID().uuidString).tmp"))
        try Data("x".utf8).write(to: box.directory.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: box.directory.appendingPathComponent("stray.json"))
        #expect(box.drain(limit: 10).count == 1, "only *.json files are considered (temp and foreign names are not)")
        #expect(FileManager.default.fileExists(atPath: box.directory.appendingPathComponent("notes.txt").path))
    }

    @Test func drainHonoursTheLimitAndTheRestComesNextTime() throws {
        let (box, dir) = inbox(); defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<7 { _ = try box.enqueue(draft(text: "m\(i)")) }
        #expect(box.drain(limit: 3).count == 3)
        #expect(box.drain(limit: 50).count == 4)
        #expect(box.drain(limit: 50).isEmpty)
    }

    @Test func missingInboxDirectoryIsAnEmptyDrain() {
        #expect(ProposalInbox(directory: tempDir()).drain(limit: 5).isEmpty)
    }
}

// MARK: - Store

@Suite("ProposalStore")
struct ProposalStoreTests {
    @Test func missingFileIsAnEmptyQueue() throws {
        #expect(try ProposalStore(directory: tempDir()).load().entries.isEmpty)
    }

    @Test func corruptFileThrowsInsteadOfSilentlyEmptying() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: dir.appendingPathComponent(ProposalStore.fileName))
        #expect(throws: (any Error).self) { try ProposalStore(directory: dir).load() }
    }

    @Test func saveLoadRoundTripsAndIsOwnerOnly() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var q = ProposalQueue()
        _ = q.ingest(draft(), tasks: [task("a")], now: Date(timeIntervalSince1970: 5))
        let store = ProposalStore(directory: dir)
        try store.save(q)
        #expect(try store.load() == q)
        let perm = try #require((try FileManager.default.attributesOfItem(atPath: store.url.path))[.posixPermissions] as? NSNumber)
        #expect(perm.uint16Value & 0o777 == 0o600)
    }
}

// MARK: - Resolution states (slice 3a)

@Suite("ProposalQueue resolution")
struct ProposalQueueResolutionTests {
    private let now = Date(timeIntervalSince1970: 5_000)
    private let a = task("a")

    private func pending(_ q: inout ProposalQueue, _ text: String = "go on") -> Proposal {
        q.ingest(draft(text: text), tasks: [a], now: now)
    }

    @Test func markSentWorksOnlyOnPendingAndStampsTheTime() {
        var q = ProposalQueue()
        let p = pending(&q)
        let ok = q.markSent(p.id, now: now.addingTimeInterval(3))
        #expect(ok)
        #expect(q.entries[0].status == .sent && q.entries[0].resolvedAt == now.addingTimeInterval(3))
        let again = q.markSent(p.id, now: now), unknown = q.markSent(UUID(), now: now)
        #expect(!again && !unknown, "at-most-once: a second confirm must not succeed")
    }

    @Test func dismissedAndExpiredCannotBeSent() {
        var q = ProposalQueue()
        let a1 = pending(&q, "one"), a2 = pending(&q, "two")
        _ = q.dismiss(a1.id, now: now)
        let expired = q.expire(a2.id, reason: "newer activity", now: now)
        #expect(expired)
        let s1 = q.markSent(a1.id, now: now), s2 = q.markSent(a2.id, now: now)
        #expect(!s1 && !s2)
        #expect(q.entries[1].status == .expired && q.entries[1].resolutionNote == "newer activity")
    }

    @Test func aSentEntryCanBecomeFailedButAPendingOneCanToo() {
        var q = ProposalQueue()
        let p = pending(&q)
        _ = q.markSent(p.id, now: now)
        let failed = q.markFailed(p.id, reason: "session not running", now: now)
        #expect(failed)
        #expect(q.entries[0].status == .failed && q.entries[0].resolutionNote == "session not running")
        let again = q.markFailed(p.id, reason: "x", now: now)
        #expect(!again, "a terminal state does not change again")
    }

    @Test func sentCountOnlyCountsRecentSendsForThatTask() {
        var q = ProposalQueue()
        let other = task("b")
        let p1 = pending(&q, "one"), p2 = pending(&q, "two")
        let o = q.ingest(draft(task: "b", text: "other"), tasks: [a, other], now: now)
        _ = q.markSent(p1.id, now: now.addingTimeInterval(-7_200))     // 2 h ago
        _ = q.markSent(p2.id, now: now.addingTimeInterval(-60))
        _ = q.markSent(o.id, now: now)
        #expect(q.sentCount(for: a.id, since: now.addingTimeInterval(-3_600)) == 1)
        #expect(q.sentCount(for: other.id, since: now.addingTimeInterval(-3_600)) == 1)
    }

    @Test func aFailedDeliveryDoesNotCountTowardsTheRateLimit() {
        var q = ProposalQueue()
        let p = pending(&q)
        _ = q.markSent(p.id, now: now); _ = q.markFailed(p.id, reason: "x", now: now)
        #expect(q.sentCount(for: a.id, since: now.addingTimeInterval(-3_600)) == 0)
    }

    @Test func legacyQueueFilesWithoutResolutionFieldsStillDecode() throws {
        var q = ProposalQueue()
        _ = pending(&q)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        var obj = try #require(try JSONSerialization.jsonObject(with: enc.encode(q)) as? [String: Any])
        var entries = try #require(obj["entries"] as? [[String: Any]])
        entries[0].removeValue(forKey: "resolvedAt"); entries[0].removeValue(forKey: "resolutionNote")
        obj["entries"] = entries
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(ProposalQueue.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(back.entries.count == 1 && back.entries[0].resolvedAt == nil)
    }
}
