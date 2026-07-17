import AppKit
import Foundation
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

    /// The default text color is near-white, not SwiftTerm's dim grey.
    @Test func defaultForegroundIsNearWhite() {
        let fg = TerminalFont.foreground.usingColorSpace(.sRGB)
        #expect((fg?.brightnessComponent ?? 0) > 0.85)
    }

    /// A freshly-created terminal actually adopts the bundled font AND the
    /// near-white foreground — proves the wiring in TerminalController, not just
    /// the constants.
    @MainActor @Test func terminalControllerAppliesFontAndForeground() {
        let controller = TerminalController(key: TabKey(taskId: UUID(), tabId: UUID()))
        #expect(controller.terminalView.font.familyName == TerminalFont.familyName)
        let fg = controller.terminalView.nativeForegroundColor.usingColorSpace(.sRGB)
        #expect((fg?.brightnessComponent ?? 0) > 0.85)
    }
}
