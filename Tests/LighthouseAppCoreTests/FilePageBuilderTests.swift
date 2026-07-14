import Foundation
import Testing
@testable import LighthouseAppCore

/// The builder is where untrusted file content meets HTML. Failure-first: a
/// hostile file (script close + injected handler + unicode) must never appear
/// in an executable form in the page source — it lives only inside the base64
/// payload and is decoded into TEXT nodes. Same discipline as DiffPageBuilder.
@Suite("FilePageBuilder security and shape")
struct FilePageBuilderTests {

    @Test func hostileContentNeverAppearsRawAndPayloadRoundTrips() {
        let page = FilePageBuilder.page(content: FilePageBuilder.hostileContent, filename: "evil.txt")
        // Executable forms must be absent from the page source...
        #expect(!page.contains("<img src=x onerror=alert(1)>"))
        #expect(!page.contains("<script>window.__pwned=true</script>"))
        // ...while the content survives, intact, as base64 (text preserved).
        let payload = Data(FilePageBuilder.hostileContent.utf8).base64EncodedString()
        #expect(page.contains(payload))
    }

    @Test func hostileFilenameIsBase64NotRaw() {
        let page = FilePageBuilder.page(
            content: "x", filename: "</h2><script>alert(1)</script>.txt")
        #expect(!page.contains("<script>alert(1)</script>"))
    }

    @Test func arbitraryHostileContentNeverLeaksRaw() {
        let corpus = ["</script><script>alert(1)</script>", "\"'`${}\\", "\u{0}\u{7}",
                      "]]><!--", "<iframe src=x>", "😈<style>*{display:none}</style>"]
        for hostile in corpus {
            let page = FilePageBuilder.page(content: hostile, filename: "f")
            #expect(!page.contains(hostile), "leaked raw: \(hostile)")
        }
    }

    @Test func cspForbidsAllNetworkSourcesAndNoExternalScript() {
        let page = FilePageBuilder.page(content: "x", filename: "f")
        #expect(page.contains("Content-Security-Policy"))
        #expect(page.contains("default-src 'none'"))
        #expect(!page.contains("http://"))
        #expect(!page.contains("https://"))
        // No vendored/highlighter asset: no external <script src=...>.
        #expect(!page.contains("<script src="))
    }

    @Test func nonceIsPresentAndDiffersPerBuild() {
        func nonce(_ html: String) -> String? {
            html.components(separatedBy: "'nonce-").dropFirst().first?
                .components(separatedBy: "'").first
        }
        let a = FilePageBuilder.page(content: "x", filename: "f")
        let b = FilePageBuilder.page(content: "x", filename: "f")
        #expect(a.contains("script-src 'nonce-"))
        #expect(nonce(a) != nonce(b))
    }

    @Test func emptyFileStillProducesAValidPage() {
        let page = FilePageBuilder.page(content: "", filename: "empty.txt")
        #expect(page.contains("default-src 'none'"))
        #expect(page.contains("id=\"file\""))
        #expect(page.contains("id=\"title\""))
    }

    @Test func normalContentIsCarriedAsBase64() {
        let content = "let x = 1\nlet y = 2\n"
        let page = FilePageBuilder.page(content: content, filename: "a.swift")
        #expect(page.contains(Data(content.utf8).base64EncodedString()))
        #expect(!page.contains("let x = 1")) // never raw
    }
}
