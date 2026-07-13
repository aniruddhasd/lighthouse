import Foundation
import Testing
@testable import LighthouseAppCore

/// Parser + transform are the deterministic heart (spec §7). Tests are
/// byte-exact against golden inputs: nested/adjacent blocks, zdiff3 base
/// sections, markers at file start/end, missing final newline, CRLF.
@Suite("ConflictParser + ConflictTransform (golden)")
struct ConflictParserTests {

    // A canonical zdiff3 block.
    private let zdiff3 = """
    a
    <<<<<<< HEAD
    ours1
    ours2
    ||||||| base
    base1
    =======
    theirs1
    >>>>>>> feature
    z
    """

    // MARK: Round-trip identity (render must reproduce input byte-for-byte)

    @Test func roundTripPreservesBytes() throws {
        let segments = try ConflictParser.parse(zdiff3)
        #expect(ConflictParser.render(segments) == zdiff3)
    }

    @Test func roundTripNoTrailingNewline() throws {
        let text = "<<<<<<< a\nx\n=======\ny\n>>>>>>> b"  // no final newline
        let segments = try ConflictParser.parse(text)
        #expect(ConflictParser.render(segments) == text)
    }

    @Test func roundTripCRLF() throws {
        let text = "a\r\n<<<<<<< a\r\nx\r\n=======\r\ny\r\n>>>>>>> b\r\nz\r\n"
        let segments = try ConflictParser.parse(text)
        #expect(ConflictParser.render(segments) == text)
    }

    @Test func markersAtFileStartAndEnd() throws {
        let text = "<<<<<<< a\nx\n=======\ny\n>>>>>>> b\n"
        let segments = try ConflictParser.parse(text)
        #expect(segments.count == 1)
        #expect(ConflictParser.render(segments) == text)
        #expect(try ConflictTransform.blockCount(in: text) == 1)
    }

    @Test func adjacentBlocks() throws {
        let text = """
        <<<<<<< a
        o1
        =======
        t1
        >>>>>>> b
        <<<<<<< a
        o2
        =======
        t2
        >>>>>>> b

        """
        #expect(try ConflictTransform.blockCount(in: text) == 2)
        #expect(ConflictParser.render(try ConflictParser.parse(text)) == text)
    }

    @Test func textSeparatedBlocks() throws {
        let text = """
        header
        <<<<<<< a
        o1
        =======
        t1
        >>>>>>> b
        middle
        <<<<<<< a
        o2
        =======
        t2
        >>>>>>> b
        footer

        """
        #expect(try ConflictTransform.blockCount(in: text) == 2)
        #expect(ConflictParser.render(try ConflictParser.parse(text)) == text)
    }

    // MARK: Broken markup throws (never silently mis-parses)

    @Test func unterminatedBlockThrows() {
        let text = "<<<<<<< a\nx\n=======\ny\n"  // no >>>>>>>
        #expect(throws: ConflictParseError.self) { _ = try ConflictParser.parse(text) }
    }

    @Test func strayCloseMarkerThrows() {
        let text = "x\n>>>>>>> b\n"
        #expect(throws: ConflictParseError.self) { _ = try ConflictParser.parse(text) }
    }

    @Test func eightMarkerCharsIsContentNotMarker() throws {
        // "========" (8) is content, not a separator.
        let text = "========\nplain\n"
        let segments = try ConflictParser.parse(text)
        #expect(segments.count == 1)
        if case .text = segments[0] {} else { Issue.record("should be plain text") }
    }

    // MARK: Transform byte-exactness

    @Test func acceptCurrentKeepsOnlyOurs() throws {
        let out = try ConflictTransform.apply(
            FileResolution(choices: [0: .current]), to: zdiff3)
        #expect(out == "a\nours1\nours2\nz")
    }

    @Test func acceptIncomingKeepsOnlyTheirs() throws {
        let out = try ConflictTransform.apply(
            FileResolution(choices: [0: .incoming]), to: zdiff3)
        #expect(out == "a\ntheirs1\nz")
    }

    @Test func acceptBothKeepsCurrentThenIncoming() throws {
        let out = try ConflictTransform.apply(
            FileResolution(choices: [0: .both]), to: zdiff3)
        #expect(out == "a\nours1\nours2\ntheirs1\nz")
    }

    @Test func perBlockDifferentChoices() throws {
        let text = """
        <<<<<<< a
        o1
        =======
        t1
        >>>>>>> b
        mid
        <<<<<<< a
        o2
        =======
        t2
        >>>>>>> b

        """
        let out = try ConflictTransform.apply(
            FileResolution(choices: [0: .current, 1: .incoming]), to: text)
        #expect(out == "o1\nmid\nt2\n")
    }

    @Test func wholeFileOursAndTheirs() throws {
        let text = """
        <<<<<<< a
        o1
        =======
        t1
        >>>>>>> b
        <<<<<<< a
        o2
        =======
        t2
        >>>>>>> b

        """
        #expect(try ConflictTransform.resolveWholeFile(.current, in: text) == "o1\no2\n")
        #expect(try ConflictTransform.resolveWholeFile(.incoming, in: text) == "t1\nt2\n")
    }

    @Test func transformPreservesCRLFAndNoFinalNewline() throws {
        let text = "<<<<<<< a\r\no\r\n=======\r\nt\r\n>>>>>>> b"  // CRLF, no final NL
        #expect(try ConflictTransform.apply(FileResolution(choices: [0: .current]), to: text) == "o\r\n")
    }

    // MARK: Transform refuses incomplete/invalid plans

    @Test func unresolvedBlockThrows() {
        let text = "<<<<<<< a\no1\n=======\nt1\n>>>>>>> b\n<<<<<<< a\no2\n=======\nt2\n>>>>>>> b\n"
        #expect {
            try ConflictTransform.apply(FileResolution(choices: [0: .current]), to: text)
        } throws: { error in
            error as? ConflictTransformError == .unresolvedBlocks([1])
        }
    }

    @Test func unknownBlockIndexThrows() {
        #expect {
            try ConflictTransform.apply(FileResolution(choices: [0: .current, 5: .current]), to: zdiff3)
        } throws: { error in
            error as? ConflictTransformError == .unknownBlock(5)
        }
    }

    @Test func hasConflictMarkersDetectsResolvedVsNot() throws {
        #expect(ConflictParser.hasConflictMarkers(zdiff3))
        let resolved = try ConflictTransform.apply(FileResolution(choices: [0: .current]), to: zdiff3)
        #expect(!ConflictParser.hasConflictMarkers(resolved))
    }
}
