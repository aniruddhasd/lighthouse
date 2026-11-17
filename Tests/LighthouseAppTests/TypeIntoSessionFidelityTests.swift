import AppKit
import Foundation
import Testing
import LighthouseAdapter
@testable import LighthouseApp

/// What a confirmed proposal actually puts into the terminal. The pty is put in RAW
/// mode and the bytes that arrive are read from the other end, so nothing the tty line
/// discipline does (echo, newline translation) can mask what was really sent.
@MainActor
@Suite("typeIntoSession fidelity", .serialized)
final class TypeIntoSessionFidelityTests {
    private func capture(typing text: String, expectBytes: Int) async throws -> (bytes: Data, delivered: Bool) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lh-tf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("received.bin")

        let registry = SessionRegistry()
        let taskId = UUID()
        defer { registry.discardTask(taskId: taskId) }
        registry.open(
            taskId: taskId, tabId: TabID.agent,
            plan: LaunchPlan(
                executable: "/bin/sh",
                arguments: ["-c", "stty raw -echo; head -c \(expectBytes) > '\(out.path)'"],
                environment: [:], workingDirectory: dir, sessionRef: "", typedCommand: nil),
            onExit: { _, _ in })
        try await Task.sleep(for: .milliseconds(400))          // let `stty raw` take effect
        let delivered = registry.typeIntoSession(taskId: taskId, text: text)
        for _ in 0..<60 where !FileManager.default.fileExists(atPath: out.path) ||
            ((try? Data(contentsOf: out).count) ?? 0) < expectBytes {
            try await Task.sleep(for: .milliseconds(50))
        }
        return ((try? Data(contentsOf: out)) ?? Data(), delivered)
    }

    @Test func theExactBytesArriveWithNothingAppended() async throws {
        let text = "please open the PR"
        let got = try await capture(typing: text, expectBytes: text.utf8.count)
        #expect(got.delivered)
        #expect(got.bytes == Data(text.utf8), "got \(String(decoding: got.bytes, as: UTF8.self).debugDescription)")
        #expect(!got.bytes.contains(0x0A) && !got.bytes.contains(0x0D), "no Enter may be sent in 3a")
    }

    @Test func nonASCIIArrivesIntactAsUTF8() async throws {
        let text = "café ✓ 日本語"
        let got = try await capture(typing: text, expectBytes: text.utf8.count)
        #expect(got.bytes == Data(text.utf8))
    }

    @Test func noTerminalMeansNothingIsDelivered() {
        let registry = SessionRegistry()
        #expect(registry.typeIntoSession(taskId: UUID(), text: "hello") == false)
    }
}
