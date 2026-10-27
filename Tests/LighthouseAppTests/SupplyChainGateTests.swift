import Foundation
import Testing

/// Exercises the supply-chain gate scripts through `swift test` so the
/// hash-assert logic is proven against tampered fixtures, not just on the
/// happy path every gate run already covers.
@Suite("Supply-chain gates")
struct SupplyChainGateTests {
    // Tests run with CWD = package root under SwiftPM.
    private let root = FileManager.default.currentDirectoryPath

    private func run(_ script: String, _ args: [String]) -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["\(root)/Scripts/\(script)"] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: Vendored-asset checksums

    @Test func vendoredAssetsPassAgainstCanonicalSums() {
        let result = run("verify-vendored-assets.sh",
                         ["\(root)/Sources/LighthouseApp/Resources/diff2html"])
        #expect(result.code == 0, "\(result.output)")
    }

    @Test func vendoredFontsPassAgainstCanonicalSums() {
        let result = run("verify-vendored-assets.sh",
                         ["\(root)/Sources/LighthouseApp/Resources/fonts"])
        #expect(result.code == 0, "\(result.output)")
    }

    @Test func tamperedAssetFailsLoudly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supply-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = URL(fileURLWithPath: "\(root)/Sources/LighthouseApp/Resources/diff2html")
        for file in ["diff2html.min.js", "diff2html.min.css", "SHA256SUMS"] {
            try FileManager.default.copyItem(
                at: source.appendingPathComponent(file), to: dir.appendingPathComponent(file))
        }
        // Flip one byte in a vendored asset — the canonical SHA256SUMS is untouched.
        let victim = dir.appendingPathComponent("diff2html.min.js")
        var bytes = try Data(contentsOf: victim)
        bytes.append(0x21)
        try bytes.write(to: victim)

        let result = run("verify-vendored-assets.sh", [dir.path])
        #expect(result.code != 0)
        #expect(result.output.contains("SUPPLY-CHAIN FAIL"))
        #expect(result.output.contains("diff2html.min.js"))
    }

    @Test func missingSumsFileFails() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supply-empty-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = run("verify-vendored-assets.sh", [dir.path])
        #expect(result.code != 0)
        #expect(result.output.contains("missing"))
    }

    // MARK: Pinned revisions

    @Test func pinsPassAgainstCanonicalLock() {
        let result = run("verify-pins.sh",
                         ["\(root)/Package.resolved", "\(root)/Scripts/pinned-revisions.txt"])
        #expect(result.code == 0, "\(result.output)")
    }

    @Test func driftedPinFailsWithUpgradeRitual() throws {
        let tampered = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolved-\(UUID().uuidString.prefix(8)).json")
        defer { try? FileManager.default.removeItem(at: tampered) }
        let original = try String(contentsOf: URL(fileURLWithPath: "\(root)/Package.resolved"), encoding: .utf8)
        // The pinned revision comes from the canonical lock, so a SwiftTerm upgrade
        // updates one file, not this test as well.
        let lock = try String(contentsOf: URL(fileURLWithPath: "\(root)/Scripts/pinned-revisions.txt"), encoding: .utf8)
        let pinned = try #require(lock.split(separator: "\n")
            .first { $0.hasPrefix("swiftterm ") }?.split(separator: " ").last.map(String.init))
        let drifted = original.replacingOccurrences(
            of: pinned, with: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
        #expect(drifted != original, "fixture revision not found in Package.resolved")
        try drifted.write(to: tampered, atomically: true, encoding: .utf8)

        let result = run("verify-pins.sh", [tampered.path, "\(root)/Scripts/pinned-revisions.txt"])
        #expect(result.code != 0)
        #expect(result.output.contains("swiftterm revision drifted"))
        #expect(result.output.contains("dep-audit"))
    }
}
