import AppKit
import SwiftUI
import Testing
@testable import LighthouseApp

/// Pure value-layer contracts for the theme system. These run without a window
/// server (unlike the THEME runtime gate in Scripts/smoke-run.sh, which proves
/// the titlebar accessory + live flip in the assembled app).
@MainActor
@Suite("Theme tokens")
struct ThemeTests {

    /// Every token resolves to a real sRGB triple in BOTH themes — a nil would
    /// mean a token that could not be resolved (a real crash risk in views).
    @Test func bothThemesResolveEveryToken() {
        for theme in [Theme.beacon, Theme.native] {
            let tokens: [Color] = [
                theme.bg, theme.chrome, theme.panel, theme.panel2, theme.panel3, theme.elev,
                theme.border, theme.border2, theme.borderSoft,
                theme.text, theme.dim, theme.faint, theme.faint2, theme.termbg,
                theme.primary, theme.primaryText, theme.sb,
                theme.working, theme.needs, theme.idle, theme.stale,
                theme.addedTextChrome, theme.addedTextTerminal,
                theme.removedTextChrome, theme.removedTextTerminal,
                theme.modelDot, theme.contextMeterStart, theme.contextMeterEnd, theme.diffVsBase,
                theme.badgeAdded, theme.badgeModified, theme.badgeDeleted,
            ]
            for color in tokens {
                #expect(color.srgbHex != nil, "\(theme.kind) had an unresolvable token")
            }
        }
    }

    /// Beacon reproduces the handoff's exact documented hex (a representative
    /// sample across chrome, text, primary, terminal, panel, and two accents).
    @Test func beaconReturnsExactDocumentedHex() {
        #expect(Theme.beacon.bg.srgbHex == "0a0d14")
        #expect(Theme.beacon.chrome.srgbHex == "0b0f18")
        #expect(Theme.beacon.panel.srgbHex == "131926")
        #expect(Theme.beacon.text.srgbHex == "e7ebf3")
        #expect(Theme.beacon.primary.srgbHex == "f0b45e")
        #expect(Theme.beacon.termbg.srgbHex == "080b11")
        #expect(Theme.beacon.working.srgbHex == "5ec8e0")
        #expect(Theme.beacon.needs.srgbHex == "f0b45e")
        #expect(Theme.beacon.idle.srgbHex == "6fd39a")
        #expect(Theme.beacon.stale.srgbHex == "cbbb5f")
    }

    /// Native binds the mapped roles to NSColor semantics (asserted on the DATA,
    /// so accent/appearance settings are respected and the check is immune to
    /// SwiftUI Color-equality fragility). The unmapped tokens stay literal hex.
    @Test func nativeMapsRolesToNSColorSemantics() {
        let native = ThemeSpec.native
        #expect(native.bg == .semantic(.windowBackground, fallback: 0xf3f3f5))
        #expect(native.panel == .semantic(.textBackground, fallback: 0xffffff))
        #expect(native.primary == .semantic(.controlAccent, fallback: 0x0a84ff))
        #expect(native.text == .semantic(.label, fallback: 0x1d1d1f))
        #expect(native.dim == .semantic(.secondaryLabel, fallback: 0x6b6b70))
        #expect(native.faint == .semantic(.tertiaryLabel, fallback: 0x8a8a90))
        #expect(native.border == .semantic(.separator, fallback: 0xd6d6dc))
        #expect(native.border2 == .semantic(.separator, fallback: 0xdcdce2))
        #expect(native.borderSoft == .semantic(.separator, fallback: 0xe0e0e6))
        // Unmapped tokens remain literal hex (chrome/termbg are the load-bearing
        // "stays a custom value" cases).
        #expect(native.chrome == .hex(0xe9e9ec))
        #expect(native.termbg == .hex(0x1e1e22))
    }

    /// The terminal + viewer background is near-black in BOTH themes — the guard
    /// on the "viewer stays dark regardless of app theme" rule. Fails the moment
    /// someone lightens termbg toward the theme's chrome.
    @Test func termbgIsDarkInBothThemes() {
        let beaconLum = Theme.beacon.termbg.srgbLuminance
        let nativeLum = Theme.native.termbg.srgbLuminance
        #expect(beaconLum != nil && beaconLum! < 0.15, "beacon termbg not dark: \(beaconLum ?? -1)")
        #expect(nativeLum != nil && nativeLum! < 0.15, "native termbg not dark: \(nativeLum ?? -1)")
    }

    /// Flipping the theme visibly changes the chrome (proves the switch is real).
    @Test func beaconAndNativeChromeDiffer() {
        #expect(Theme.beacon.bg.srgbHex != Theme.native.bg.srgbHex)
        #expect(Theme.beacon.chrome.srgbHex != Theme.native.chrome.srgbHex)
    }

    // MARK: ThemeController

    /// The controller toggles and persists exactly once per real change, and
    /// no-ops (no persist churn) on a redundant set.
    @Test func themeControllerTogglesAndPersistsOncePerChange() {
        var persisted: [LighthouseTheme] = []
        let controller = ThemeController(initial: .beacon) { persisted.append($0) }
        #expect(controller.theme == .beacon)

        controller.set(.native)
        #expect(controller.theme == .native)
        #expect(controller.resolved.kind == .native)
        #expect(persisted == [.native])

        // Redundant set is a no-op (no extra persist).
        controller.set(.native)
        #expect(persisted == [.native])

        controller.set(.beacon)
        #expect(persisted == [.native, .beacon])
    }

    /// An unrecognised persisted string fails safe to Beacon (a newer build's
    /// value, or a hand-edit, must never crash or blank the UI).
    @Test func unknownThemeStringFailsSafeToBeacon() {
        #expect(LighthouseTheme.from(rawValue: "beacon") == .beacon)
        #expect(LighthouseTheme.from(rawValue: "native") == .native)
        #expect(LighthouseTheme.from(rawValue: "chartreuse") == .beacon)
        #expect(LighthouseTheme.from(rawValue: "") == .beacon)
    }

    /// Typography goes through one helper; mono and UI at the same size are
    /// distinct fonts (guards a regression that collapses the two).
    @Test func monoAndUIFontsDiffer() {
        #expect(LHFont.mono(13) != LHFont.ui(13))
    }

    // MARK: Per-theme appearance pinning (the 2026-07-15 coherence fix)

    /// Each theme declares the appearance it must render in — Beacon dark,
    /// Native light — so the app can pin it regardless of the system setting.
    @Test func themeAppearanceIsPinnedPerTheme() {
        #expect(LighthouseTheme.beacon.colorScheme == .dark)
        #expect(LighthouseTheme.native.colorScheme == .light)
        #expect(LighthouseTheme.beacon.nsAppearanceName == .darkAqua)
        #expect(LighthouseTheme.native.nsAppearanceName == .aqua)
    }

    /// Resolved WITHIN each theme's own appearance, the palette is COHERENT:
    /// Native's semantic bg/chrome are light and its text is dark; Beacon's are
    /// dark with light text. This is the guard on the half-light bug — the
    /// mixed literal-hex + NSColor-semantic Native palette must not split into
    /// light-chrome / dark-content. Fails if the appearance is mapped wrong
    /// (e.g. Native → darkAqua would resolve its semantic bg dark).
    @Test func tokensResolveCoherentlyInThemeAppearance() {
        let native = Theme.native
        let nativeAp = native.nsAppearance
        #expect((native.bg.srgbLuminance(in: nativeAp) ?? -1) > 0.7, "native bg not light")
        #expect((native.chrome.srgbLuminance(in: nativeAp) ?? -1) > 0.7, "native chrome not light")
        #expect((native.text.srgbLuminance(in: nativeAp) ?? 1) < 0.3, "native text not dark")

        let beacon = Theme.beacon
        let beaconAp = beacon.nsAppearance
        #expect((beacon.bg.srgbLuminance(in: beaconAp) ?? 1) < 0.15, "beacon bg not dark")
        #expect((beacon.chrome.srgbLuminance(in: beaconAp) ?? 1) < 0.15, "beacon chrome not dark")
        #expect((beacon.text.srgbLuminance(in: beaconAp) ?? -1) > 0.6, "beacon text not light")
    }
}
