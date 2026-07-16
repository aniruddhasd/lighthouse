import AppKit
import CoreText

/// The terminal typeface: **JetBrains Mono** (bundled — the Ghostty default),
/// falling back to SF Mono if the bundled font cannot be registered so the
/// terminal never fails to draw. The four faces are vendored under
/// `Resources/fonts` and pinned by `SHA256SUMS` (the supply-chain gate verifies
/// them at build time, same as the diff2html assets).
enum TerminalFont {
    /// Point size (chosen 14pt). SwiftTerm derives the bold/italic faces from
    /// this base via NSFontManager, which finds the registered JetBrains Mono
    /// bold/italic faces.
    static let size: CGFloat = 14

    /// The PostScript family name Core Text exposes for the bundled font.
    static let familyName = "JetBrains Mono"

    /// Registers the bundled `.ttf` faces with Core Text exactly once (lazy
    /// static ⇒ one-time, process-scoped). Returns whether any face registered;
    /// a fresh process registers cleanly, and re-entry is a no-op.
    private static let registered: Bool = {
        guard let urls = Bundle.module.urls(
            forResourcesWithExtension: "ttf", subdirectory: "Resources/fonts") else {
            return false
        }
        var any = false
        for url in urls where CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) {
            any = true
        }
        return any
    }()

    /// The base terminal font: JetBrains Mono when the bundled font is present,
    /// else SF Mono at the same size. Forcing `registered` first guarantees the
    /// faces are available before `NSFont(name:)` looks them up.
    static var base: NSFont {
        _ = registered
        return NSFont(name: familyName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Default (un-ANSI-colored) text color — a crisp near-white, replacing
    /// SwiftTerm's dim grey default so plain shell/agent output is readable on
    /// the dark terminal. ANSI-colored output overrides this per run.
    static let foreground = NSColor(srgbRed: 0.918, green: 0.929, blue: 0.957, alpha: 1) // #eaedf4

    /// Terminal background — near-black, matching the design's `--termbg`
    /// (the terminal stays dark in both themes). The fallback when a program
    /// hasn't set its own background.
    static let background = NSColor(srgbRed: 0.031, green: 0.043, blue: 0.067, alpha: 1) // #080b11
}
