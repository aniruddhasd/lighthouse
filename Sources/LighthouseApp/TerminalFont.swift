import AppKit
import CoreText

/// The terminal typeface: **JetBrains Mono** (bundled — the Ghostty default),
/// falling back to SF Mono if the bundled font cannot be registered so the
/// terminal never fails to draw. The four faces are vendored under
/// `Resources/fonts` and pinned by `SHA256SUMS` (the supply-chain gate verifies
/// them at build time, same as the diff2html assets).
enum TerminalFont {
    /// Fallback point size when no persisted preference is available. The live
    /// size comes from `AppModel.terminalFontSize` (config schema v5) and is
    /// pushed into every terminal via `SessionRegistry.applyFontSize`.
    static let defaultSize: CGFloat = 13

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

    /// The base terminal font at `size`: JetBrains Mono when the bundled font is
    /// present, else SF Mono at the same size. Forcing `registered` first
    /// guarantees the faces are available before `NSFont(name:)` looks them up.
    static func base(size: CGFloat = defaultSize) -> NSFont {
        _ = registered
        return NSFont(name: familyName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Default (un-ANSI-colored) text color — a soft near-white matching
    /// Ghostty's foreground, replacing SwiftTerm's dim grey default. Paired with
    /// the dark-gray `background` this lands contrast at ~9.9:1 (an exact
    /// Ghostty match — comfortable for long sessions, still clearly light).
    /// ANSI-colored output overrides this per run.
    static let foreground = NSColor(srgbRed: 0.816, green: 0.824, blue: 0.835, alpha: 1) // #d0d2d5

    /// Terminal background — a dark GRAY, not near-black. Measured against
    /// Ghostty (bg #23272D), our old near-black #080b11 pushed contrast to
    /// ~14:1 (near-white on near-black), which haloes and tires the eyes over a
    /// long session. This gray lands contrast in the comfortable ~10:1 range
    /// like Ghostty while the text stays crisp and near-white. The fallback when
    /// a program hasn't set its own background.
    static let background = NSColor(srgbRed: 0.137, green: 0.153, blue: 0.176, alpha: 1) // #23272D
}
