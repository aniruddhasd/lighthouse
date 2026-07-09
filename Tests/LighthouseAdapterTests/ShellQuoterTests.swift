import Foundation
import Testing
import LighthouseGit
@testable import LighthouseAdapter

/// The quoter guards the ONE shell string in the app. The proof standard is
/// not "looks quoted" but a live round-trip: /bin/sh must reproduce the
/// original bytes exactly, for every hostile input we can think of and a
/// seeded random corpus.
@Suite("ShellQuoter")
struct ShellQuoterTests {

    /// Round-trips a string through a real shell: `sh -c "printf %s <quoted>"`.
    private func shellRoundTrip(_ original: String) async throws -> String {
        let command = "printf %s " + ShellQuoter.quote(original)
        let result = try await ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", command],
            workingDirectory: FileManager.default.temporaryDirectory)
        #expect(result.exitCode == 0)
        return String(decoding: result.stdout, as: UTF8.self)
    }

    static let hostileCorpus: [String] = [
        "simple",
        "with spaces everywhere",
        "single'quote",
        "'leading and trailing'",
        "''",
        "double\"quote",
        "$HOME and ${PWD}",
        "`whoami`",
        "$(rm -rf /tmp/nope)",
        "semi;colon && chained || piped | out",
        "redirect > /tmp/x < /dev/null 2>&1",
        "back\\slash",
        "glob * ? [a-z] {a,b}",
        "newline\nin the middle",
        "tab\tand carriage\r",
        "tilde ~ and hash # comment",
        "exclaim!history",
        "unicode — émojis 🚨 and 中文",
        "-leading-dash",
        "--flag=value",
    ]

    @Test(arguments: hostileCorpus)
    func hostileStringsSurviveARealShell(original: String) async throws {
        #expect(try await shellRoundTrip(original) == original)
    }

    @Test func emptyStringQuotesToEmptyWord() async throws {
        #expect(ShellQuoter.quote("") == "''")
        // Word count proof: printf sees exactly one (empty) argument.
        let result = try await ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf '[%s]' " + ShellQuoter.quote("")],
            workingDirectory: FileManager.default.temporaryDirectory)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "[]")
    }

    @Test func commandPreservesWordBoundaries() async throws {
        // Each argv element must arrive as exactly one word, however hostile.
        let argv = ["a b", "c'd", "$e", "", "f\ng"]
        let command = "printf '[%s]' " + ShellQuoter.command(argv)
        let result = try await ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", command],
            workingDirectory: FileManager.default.temporaryDirectory)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "[a b][c'd][$e][][f\ng]")
    }

    @Test func seededRandomCorpusRoundTrips() async throws {
        // Deterministic pseudo-random strings over a nasty alphabet.
        let alphabet = Array(#" abcdefXYZ'"`$\;|&<>(){}[]*?!#~^%\n\t-=/"#)
        var seed: UInt64 = 0xC0FFEE
        for _ in 0..<60 {
            var string = ""
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let length = Int(seed % 24) + 1
            for _ in 0..<length {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                string.append(alphabet[Int(seed >> 33) % alphabet.count])
            }
            #expect(try await shellRoundTrip(string) == string, "failed for: \(string)")
        }
    }

    @Test func zshAgreesWithSh() async throws {
        // The plan runs through the user's shell, which is zsh here — the
        // quoting must hold there too.
        for original in Self.hostileCorpus {
            let command = "printf %s " + ShellQuoter.quote(original)
            let result = try await ProcessRunner.run(
                executable: "/bin/zsh", arguments: ["-c", command],
                workingDirectory: FileManager.default.temporaryDirectory)
            #expect(String(decoding: result.stdout, as: UTF8.self) == original)
        }
    }
}
