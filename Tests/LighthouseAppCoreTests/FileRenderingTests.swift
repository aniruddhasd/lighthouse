import Foundation
import Testing
@testable import LighthouseAppCore

/// The decision of HOW to show a file, and the page it produces. The page's own
/// DOM behaviour is proved in real WebKit by the FILERENDER gate in
/// Scripts/smoke-run.sh; these pin what can be pinned without a web view.
@Suite("FileRendering choice and page shape")
struct FileRenderingTests {

    // MARK: Failure modes first

    @Test func oversizedFileIsPlainNotHighlighted() {
        let big = String(repeating: "x", count: FileRendering.maxHighlightBytes + 1)
        #expect(FileRendering.forFile(named: "a.swift", content: big) == .plain)
        #expect(FileRendering.forFile(named: "README.md", content: big) == .plain)
    }

    @Test func tooManyLinesIsPlain() {
        let many = String(repeating: "\n", count: FileRendering.maxHighlightLines + 1)
        #expect(FileRendering.forFile(named: "a.py", content: many) == .plain)
        let ok = String(repeating: "\n", count: FileRendering.maxHighlightLines - 1)
        #expect(FileRendering.forFile(named: "a.py", content: ok).language == "python")
    }

    @Test func unknownAndExtensionlessFilesArePlain() {
        #expect(FileRendering.forFile(named: "notes.xyz", content: "x") == .plain)
        #expect(FileRendering.forFile(named: "LICENSE", content: "x") == .plain)
        #expect(FileRendering.forFile(named: ".gitignore", content: "x") == .plain)
    }

    @Test func unsafeLanguageTokenIsNeverInterpolated() {
        let page = FilePageBuilder.page(
            content: "x", filename: "f",
            rendering: FileRendering(language: "swift\";window.__pwned=true;//", markdown: false))
        #expect(!page.contains("__pwned"))
        #expect(page.contains("const LANGUAGE = \"\";"))
    }

    @Test func everyTableLanguageIsASafeToken() {
        let all = Set(FileRendering.languageByExtension.values).union(FileRendering.languageByName.values)
        for language in all { #expect(FileRendering.isSafeLanguageToken(language), "\(language)") }
        #expect(!FileRendering.isSafeLanguageToken(""))
        #expect(!FileRendering.isSafeLanguageToken("a b"))
        #expect(!FileRendering.isSafeLanguageToken("C"))
    }

    // MARK: Choice

    @Test func extensionAndNameMapping() {
        #expect(FileRendering.forFile(named: "Sources/App/Main.SWIFT", content: "x").language == "swift")
        #expect(FileRendering.forFile(named: "a/b/Makefile", content: "x").language == "makefile")
        #expect(FileRendering.forFile(named: "x.tsx", content: "x").language == "typescript")
        #expect(FileRendering.forFile(named: "a.swift", content: "x").markdown == false)
    }

    @Test func markdownFilesGetRenderedView() {
        for name in ["README.md", "docs/a.markdown", "B.MD"] {
            let r = FileRendering.forFile(named: name, content: "# hi")
            #expect(r.markdown, "\(name)")
            #expect(r.needsAssets)
        }
    }

    @Test func plainNeedsNoAssets() {
        #expect(!FileRendering.plain.needsAssets)
    }

    // MARK: Page shape

    @Test func plainPageKeepsTheAssetFreeCSP() {
        let page = FilePageBuilder.page(content: "x", filename: "f")
        #expect(page.contains("script-src 'nonce-"))
        #expect(!page.contains("'self'"))
        #expect(!page.contains("<script src="))
        #expect(!page.contains("<link"))
    }

    @Test func codePageLoadsOnlyTheHighlighterFromTheRenderDirectory() {
        let page = FilePageBuilder.page(
            content: "let x = 1", filename: "a.swift",
            rendering: FileRendering.forFile(named: "a.swift", content: "let x = 1"))
        #expect(page.contains("default-src 'none'"))
        #expect(page.contains("script-src 'self' 'nonce-"))
        #expect(page.contains("<script src=\"\(FilePageBuilder.highlightScript)\">"))
        #expect(!page.contains(FilePageBuilder.markdownScript))
        #expect(!page.contains("http://") && !page.contains("https://"))
        #expect(!page.contains("img-src"))
    }

    @Test func markdownPageLoadsParserAndNeverTheNetwork() {
        let page = FilePageBuilder.page(
            content: "# hi", filename: "a.md",
            rendering: FileRendering.forFile(named: "a.md", content: "# hi"))
        #expect(page.contains("<script src=\"\(FilePageBuilder.markdownScript)\">"))
        #expect(page.contains("const MARKDOWN = true;"))
        #expect(page.contains("html: false"))   // raw HTML in a .md file is shown as text
        #expect(!page.contains("http://") && !page.contains("https://"))
    }

    @Test func hostileMarkdownNeverAppearsRaw() {
        let page = FilePageBuilder.page(
            content: FilePageBuilder.hostileMarkdown, filename: "evil.md",
            rendering: FileRendering(language: "markdown", markdown: true))
        for needle in ["<iframe", "javascript:", "onerror", "evil.example", "__pwned=true"] {
            #expect(!page.contains(needle), "leaked raw: \(needle)")
        }
        #expect(page.contains(Data(FilePageBuilder.hostileMarkdown.utf8).base64EncodedString()))
    }

    @Test func presenterPicksRenderingByFilenameAndKeepsPlaceholdersPlain() {
        let code = NavigatorPresenter.filePage(for: .text("let x = 1"), filename: "a.swift")
        #expect(code.contains(FilePageBuilder.highlightScript))
        let binary = NavigatorPresenter.filePage(for: .binary, filename: "a.swift")
        #expect(!binary.contains(FilePageBuilder.highlightScript))
        let large = NavigatorPresenter.filePage(for: .tooLarge(bytes: 9), filename: "README.md")
        #expect(!large.contains(FilePageBuilder.markdownScript))
    }
}
