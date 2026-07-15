import AppKit
import SwiftUI

/// The two runtime themes. Persisted as a raw String in config (schema v4) so
/// the value layer (LighthouseTaskEngine) never imports SwiftUI; the mapping
/// String <-> enum lives here, and an unknown string fails safe to `.beacon`.
public enum LighthouseTheme: String, Codable, Sendable, CaseIterable, Identifiable {
    case beacon
    case native

    public var id: String { rawValue }

    /// Label for the titlebar switcher segments.
    var label: String {
        switch self {
        case .beacon: return "Beacon"
        case .native: return "Native"
        }
    }

    /// Fail-safe decode of a persisted string: an unrecognised value (a config
    /// written by a newer build, or a hand-edit) resolves to the default dark
    /// theme rather than crashing or blanking the UI.
    static func from(rawValue: String) -> LighthouseTheme {
        LighthouseTheme(rawValue: rawValue) ?? .beacon
    }

    /// The appearance this theme renders in. Beacon is a custom DARK palette,
    /// Native is light. This MUST be pinned per theme (not left to the system):
    /// Native mixes literal-light-hex tokens with NSColor SEMANTIC tokens, and
    /// semantic tokens resolve against the current NSAppearance — so under a
    /// Dark system, Native went half-light/half-dark (2026-07-15 coherence
    /// bug). Pinning makes every semantic token AND every native control
    /// resolve in the theme's intended appearance regardless of the user's
    /// system Light/Dark setting.
    var colorScheme: ColorScheme { self == .beacon ? .dark : .light }
    var nsAppearanceName: NSAppearance.Name { self == .beacon ? .darkAqua : .aqua }
}

/// An NSColor semantic role used by the Native theme so the app respects the
/// user's accent color and accessibility settings (handoff "Native mapping
/// tip"). Each carries the handoff's documented hex as a reference fallback.
enum SemanticRole: String, Equatable, Sendable {
    case windowBackground
    case controlBackground
    case textBackground
    case controlAccent
    case label
    case secondaryLabel
    case tertiaryLabel
    case separator

    var nsColor: NSColor {
        switch self {
        case .windowBackground: return .windowBackgroundColor
        case .controlBackground: return .controlBackgroundColor
        case .textBackground: return .textBackgroundColor
        case .controlAccent: return .controlAccentColor
        case .label: return .labelColor
        case .secondaryLabel: return .secondaryLabelColor
        case .tertiaryLabel: return .tertiaryLabelColor
        case .separator: return .separatorColor
        }
    }
}

/// Where a single token's color comes from. The DATA (this enum) is pure and
/// Equatable so the whole palette is unit-testable without touching SwiftUI or
/// a window server; `.color` / `.nsColor` are the resolution MECHANISM.
enum ColorSource: Equatable, Sendable {
    /// A literal sRGB hex (Beacon, and the Native tokens with no semantic role).
    case hex(UInt32)
    /// A Native semantic role, carrying the handoff hex as the documented
    /// fallback / exact-match reference.
    case semantic(SemanticRole, fallback: UInt32)

    var color: Color {
        switch self {
        case .hex(let value): return Color(hex: value)
        case .semantic(let role, _): return Color(nsColor: role.nsColor)
        }
    }

    var nsColor: NSColor {
        switch self {
        case .hex(let value): return NSColor(Color(hex: value))
        case .semantic(let role, _): return role.nsColor
        }
    }
}

/// The theme-varying tokens as pure data (17 chrome tokens + 4 status accents).
/// Diff/semantic and brand colors do NOT vary per theme (the handoff gives one
/// column for them) and live as constants on `Theme`.
struct ThemeSpec: Equatable, Sendable {
    var bg, chrome, panel, panel2, panel3, elev: ColorSource
    var border, border2, borderSoft: ColorSource
    var text, dim, faint, faint2: ColorSource
    var termbg: ColorSource
    var primary, primaryText, sb: ColorSource
    var working, needs, idle, stale: ColorSource

    /// Beacon (custom dark "night-watch") — literal hex from the handoff's
    /// Chrome-tokens + Status-accent tables.
    static let beacon = ThemeSpec(
        bg: .hex(0x0a0d14), chrome: .hex(0x0b0f18), panel: .hex(0x131926),
        panel2: .hex(0x101623), panel3: .hex(0x141b28), elev: .hex(0x18202f),
        border: .hex(0x2a3346), border2: .hex(0x242c3c), borderSoft: .hex(0x1c2331),
        text: .hex(0xe7ebf3), dim: .hex(0x8a93a6), faint: .hex(0x6f7890), faint2: .hex(0x525b6f),
        termbg: .hex(0x080b11),
        primary: .hex(0xf0b45e), primaryText: .hex(0x241a08), sb: .hex(0x2a3346),
        working: .hex(0x5ec8e0), needs: .hex(0xf0b45e), idle: .hex(0x6fd39a), stale: .hex(0xcbbb5f))

    /// Native (light macOS). The mapped roles bind to NSColor semantics per the
    /// handoff tip; the fallback hex is the documented exact-match reference.
    /// Not every token maps: chrome/panel3/elev/faint2/termbg/primaryText/sb and
    /// the status accents stay literal hex (the handoff maps only bg, panel,
    /// primary, text, dim, faint, and the borders).
    static let native = ThemeSpec(
        bg: .semantic(.windowBackground, fallback: 0xf3f3f5),
        chrome: .hex(0xe9e9ec),
        panel: .semantic(.textBackground, fallback: 0xffffff),
        panel2: .semantic(.textBackground, fallback: 0xffffff),
        panel3: .hex(0xededf1), elev: .hex(0xeef0f4),
        border: .semantic(.separator, fallback: 0xd6d6dc),
        border2: .semantic(.separator, fallback: 0xdcdce2),
        borderSoft: .semantic(.separator, fallback: 0xe0e0e6),
        text: .semantic(.label, fallback: 0x1d1d1f),
        dim: .semantic(.secondaryLabel, fallback: 0x6b6b70),
        faint: .semantic(.tertiaryLabel, fallback: 0x8a8a90),
        faint2: .hex(0xa0a0a8),
        termbg: .hex(0x1e1e22),
        primary: .semantic(.controlAccent, fallback: 0x0a84ff),
        primaryText: .hex(0xffffff), sb: .hex(0xc8c8d0),
        working: .hex(0x0a84c2), needs: .hex(0xc8871a), idle: .hex(0x1f9d55), stale: .hex(0x98811a))

    static func spec(for theme: LighthouseTheme) -> ThemeSpec {
        switch theme {
        case .beacon: return beacon
        case .native: return native
        }
    }
}

/// The resolved, SwiftUI-facing theme: every token as a `Color`, plus the
/// theme-invariant diff/semantic + brand colors and layout metrics. A pure
/// value; flipping the active theme just hands views a different `Theme`, and
/// normal SwiftUI observation re-renders everything that read `\.theme`.
struct Theme: Equatable {
    let kind: LighthouseTheme
    let spec: ThemeSpec

    init(_ kind: LighthouseTheme) {
        self.kind = kind
        self.spec = ThemeSpec.spec(for: kind)
    }

    static let beacon = Theme(.beacon)
    static let native = Theme(.native)
    static func forKind(_ kind: LighthouseTheme) -> Theme { Theme(kind) }

    /// The appearance every surface in this theme must render in (see
    /// `LighthouseTheme.colorScheme`). Pinned on the host window so semantic
    /// tokens + native controls stay coherent under any system setting.
    var colorScheme: ColorScheme { kind.colorScheme }
    var nsAppearance: NSAppearance { NSAppearance(named: kind.nsAppearanceName)! }

    // MARK: Chrome tokens
    var bg: Color { spec.bg.color }
    var chrome: Color { spec.chrome.color }
    var panel: Color { spec.panel.color }
    var panel2: Color { spec.panel2.color }
    var panel3: Color { spec.panel3.color }
    var elev: Color { spec.elev.color }
    var border: Color { spec.border.color }
    var border2: Color { spec.border2.color }
    var borderSoft: Color { spec.borderSoft.color }
    var text: Color { spec.text.color }
    var dim: Color { spec.dim.color }
    var faint: Color { spec.faint.color }
    var faint2: Color { spec.faint2.color }
    /// Terminal + WKWebView viewer background — DARK IN BOTH THEMES (handoff
    /// rule). Only used where chrome deliberately abuts those dark surfaces;
    /// the page builders and SwiftTerm own their own colors and are not themed.
    var termbg: Color { spec.termbg.color }
    var primary: Color { spec.primary.color }
    var primaryText: Color { spec.primaryText.color }
    var sb: Color { spec.sb.color }

    // MARK: Status accents (working / needs / idle / stale)
    var working: Color { spec.working.color }
    var needs: Color { spec.needs.color }
    var idle: Color { spec.idle.color }
    var stale: Color { spec.stale.color }

    // MARK: Diff / semantic (theme-invariant — one handoff column)
    var addedTextChrome: Color { Color(hex: 0x4fb07a) }
    var addedTextTerminal: Color { Color(hex: 0x6fd39a) }
    var removedTextChrome: Color { Color(hex: 0xd46b64) }
    var removedTextTerminal: Color { Color(hex: 0xe0736d) }
    var addedLineBg: Color { Color(hex: 0x6fd39a, opacity: 0.10) }
    var removedLineBg: Color { Color(hex: 0xe0736d, opacity: 0.10) }
    var modelDot: Color { Color(hex: 0x3f6cd6) }
    var contextMeterStart: Color { Color(hex: 0x5ec8e0) }
    var contextMeterEnd: Color { Color(hex: 0x4a9fd6) }
    var diffVsBase: Color { Color(hex: 0x4a9fd6) }
    var badgeAdded: Color { Color(hex: 0x5fc389) }
    var badgeModified: Color { Color(hex: 0xe0a34a) }
    var badgeDeleted: Color { Color(hex: 0xd46b64) }

    // MARK: Brand — the beacon amber, IDENTICAL in both themes (handoff §0).
    /// The titlebar beacon dot uses these regardless of the active theme.
    static let beaconAmber = Color(hex: 0xf0b45e)
    static let beaconAmberDeep = Color(hex: 0xb97a26)
    static let beaconGlow = Color(hex: 0xf0b45e, opacity: 0.6)

    /// Radius scale (handoff "Radius / spacing / shadow").
    enum Radius {
        static let palette: CGFloat = 16
        static let card: CGFloat = 14
        static let row: CGFloat = 12
        static let rail: CGFloat = 11
        static let search: CGFloat = 10
        static let chip: CGFloat = 9
        static let tab: CGFloat = 8
        static let segment: CGFloat = 7
        static let keycap: CGFloat = 6
        static let pill: CGFloat = 20
    }

    /// Fixed layout metrics (handoff "Standard paddings").
    enum Metric {
        static let titlebarHeight: CGFloat = 38
        static let gutter: CGFloat = 30
        static let headerRow: CGFloat = 52
        static let footer: CGFloat = 30
        static let rail: CGFloat = 60
        static let navigator: CGFloat = 340
    }
}

// MARK: - Color helpers (sRGB hex in, sRGB hex/luminance out)

extension Color {
    /// Build a color from a packed 0xRRGGBB sRGB hex.
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xff) / 255
        let g = Double((hex >> 8) & 0xff) / 255
        let b = Double(hex & 0xff) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    /// The resolved sRGB "rrggbb" string (current appearance for semantic
    /// colors). Used by the theme unit tests and the THEME runtime gate to
    /// prove exact reproduction; nil if the color cannot be resolved to sRGB.
    var srgbHex: String? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "%02x%02x%02x", r, g, b)
    }

    /// Relative luminance (0 = black, 1 = white) in sRGB, for "is this dark?"
    /// assertions (the terminal/viewer stay-dark rule). nil if unresolvable.
    var srgbLuminance: Double? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    /// Resolve the sRGB hex WITHIN a specific appearance. Semantic (Native)
    /// tokens resolve against the current drawing appearance, so pinning it
    /// makes resolution independent of the process/system Light/Dark setting —
    /// exactly what the app does by pinning the window appearance. Verified
    /// (2026-07-15) that the `Color(nsColor:)` round-trip stays dynamic under
    /// `performAsCurrentDrawingAppearance`, so this mirrors the real render.
    func srgbHex(in appearance: NSAppearance) -> String? {
        var out: String?
        appearance.performAsCurrentDrawingAppearance { out = self.srgbHex }
        return out
    }

    /// Relative luminance resolved within a specific appearance (see above).
    func srgbLuminance(in appearance: NSAppearance) -> Double? {
        var out: Double?
        appearance.performAsCurrentDrawingAppearance { out = self.srgbLuminance }
        return out
    }
}
