import AppKit
import Testing
@testable import LighthouseApp

@Suite("Terminal font")
struct TerminalFontTests {
    /// The bundled JetBrains Mono registers from the resource bundle and
    /// resolves to the real family — proving the vendored font is wired end to
    /// end (bundle → Core Text registration → NSFont) without launching the
    /// app. If registration had failed, `base` would be the SF Mono fallback
    /// and the family name would differ.
    @Test func bundledFontRegistersAndResolvesToJetBrainsMono() {
        let font = TerminalFont.base
        #expect(font.familyName == TerminalFont.familyName)
        #expect(font.pointSize == TerminalFont.size)
    }
}
