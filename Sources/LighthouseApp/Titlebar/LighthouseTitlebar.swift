import AppKit
import SwiftUI

/// The custom 38px titlebar (spec §3.3, handoff §0). Keeps the REAL macOS
/// traffic lights; adds a centered, non-interactive beacon-dot + "Lighthouse"
/// wordmark and a trailing theme switcher + account string.
///
/// Approach (the §8 scar — traffic lights and accessory layout must not
/// collide): the interactive control (theme switcher) is a proper AppKit
/// `NSTitlebarAccessoryViewController` docked TRAILING, well clear of the
/// leading traffic lights. The centered wordmark is genuinely window-centered,
/// which no titlebar-accessory `layoutAttribute` offers (there is no `.center`),
/// so it is a non-interactive `NSHostingView` pinned centerX/centerY to the
/// titlebar container — hit-testing disabled so clicks/drag fall through to the
/// title area and never fight the traffic lights. We do NOT enable
/// `fullSizeContentView`, so the app content below is not reflowed; the band is
/// tinted `--chrome` by tinting the (otherwise content-covered) window
/// background, which shows only through the transparent titlebar.
@MainActor
final class LighthouseTitlebar {
    /// The most recently installed titlebar, for the THEME runtime gate to
    /// assert the accessory + switcher + wordmark are actually present.
    static weak var current: LighthouseTitlebar?

    static let switcherID = NSUserInterfaceItemIdentifier("lh.titlebar.switcher")
    static let wordmarkID = NSUserInterfaceItemIdentifier("lh.titlebar.wordmark")

    private let controller: ThemeController
    private weak var window: NSWindow?
    private var trailingVC: NSTitlebarAccessoryViewController?
    private weak var wordmarkView: NSView?

    init(controller: ThemeController) {
        self.controller = controller
    }

    /// Idempotent: safe to call on every SwiftUI update pass. Configures the
    /// window once, then only re-tints the band for the active theme.
    ///
    /// NOTE ON APPEARANCE (the coherence fix): the window's *appearance* is NOT
    /// pinned here. SwiftUI OWNS its hosting window's `appearance` and resets a
    /// manually-set value on its next update pass (verified 2026-07-15: setting
    /// `window.appearance = .aqua` ran but `effectiveAppearance` stayed dark).
    /// The correct lever is `.preferredColorScheme(theme.colorScheme)` on the
    /// SwiftUI root (ContentView), which drives the window appearance THROUGH
    /// SwiftUI so it isn't clobbered — and cascades to the titlebar accessories,
    /// which inherit the window's effective appearance. This method only owns
    /// the band tint (the window background shown through the transparent
    /// titlebar).
    func apply(on window: NSWindow, theme: Theme) {
        if self.window !== window || trailingVC == nil {
            install(on: window)
        }
        window.backgroundColor = NSColor(theme.chrome)
        Self.current = self
    }

    private func install(on window: NSWindow) {
        self.window = window
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // Trailing accessory: theme switcher + account (interactive → a real
        // accessory so hit-testing and layout are handled by AppKit).
        let trailingHost = NSHostingView(rootView: TitlebarTrailingView(controller: controller))
        trailingHost.identifier = Self.switcherID
        trailingHost.translatesAutoresizingMaskIntoConstraints = true
        trailingHost.frame = NSRect(x: 0, y: 0, width: trailingHost.fittingSize.width,
                                    height: Theme.Metric.titlebarHeight)
        let vc = NSTitlebarAccessoryViewController()
        vc.view = trailingHost
        vc.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(vc)
        trailingVC = vc

        // Centered, non-interactive wordmark pinned to the titlebar container.
        if let titlebarContainer = window.standardWindowButton(.closeButton)?.superview {
            let wordmark = PassthroughHostingView(
                rootView: TitlebarWordmarkView(controller: controller))
            wordmark.identifier = Self.wordmarkID
            wordmark.translatesAutoresizingMaskIntoConstraints = false
            titlebarContainer.addSubview(wordmark)
            NSLayoutConstraint.activate([
                wordmark.centerXAnchor.constraint(equalTo: titlebarContainer.centerXAnchor),
                wordmark.centerYAnchor.constraint(equalTo: titlebarContainer.centerYAnchor),
            ])
            wordmarkView = wordmark
        }
    }

    // MARK: - Gate introspection (real window state, not a mock)
    var hasTrailingAccessory: Bool {
        guard let window, let vc = trailingVC else { return false }
        return window.titlebarAccessoryViewControllers.contains { $0 === vc }
    }
    var hasSwitcher: Bool { trailingVC?.view.identifier == Self.switcherID }
    var hasWordmark: Bool { wordmarkView?.superview != nil }
    /// The live effective appearance of the host window — proves the app
    /// actually pinned the theme's appearance (the THEME gate reads this and
    /// resolves tokens within it, so its coherence check depends on the fix).
    var windowEffectiveAppearance: NSAppearance? { window?.effectiveAppearance }
}

/// A hosting view that never intercepts mouse events, so the centered wordmark
/// does not steal clicks or window-drag from the title area / traffic lights.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The centered beacon dot + wordmark. Non-interactive. The amber is the brand
/// constant — identical in both themes.
private struct TitlebarWordmarkView: View {
    @Bindable var controller: ThemeController

    var body: some View {
        HStack(spacing: 8) {
            BeaconDot()
            Text("Lighthouse")
                .font(LHFont.wordmark)
                .foregroundStyle(controller.resolved.dim)
        }
        .padding(.horizontal, 4)
        .allowsHitTesting(false)
    }
}

/// The 13px radial-amber beacon dot with its glow (handoff §0). Brand color,
/// theme-independent.
struct BeaconDot: View {
    var diameter: CGFloat = 13

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Theme.beaconAmber, Theme.beaconAmberDeep],
                    center: .center, startRadius: 0, endRadius: diameter / 2))
            .frame(width: diameter, height: diameter)
            .shadow(color: Theme.beaconGlow, radius: 5)
    }
}

/// Trailing accessory: the Beacon/Native switcher + account string.
private struct TitlebarTrailingView: View {
    @Bindable var controller: ThemeController

    var body: some View {
        let theme = controller.resolved
        HStack(spacing: 12) {
            Picker("Theme", selection: controller.binding) {
                ForEach(LighthouseTheme.allCases) { theme in
                    Text(theme.label).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Switch between the Beacon (dark) and Native (light) themes")

            Text(TitlebarAccount.label)
                .font(LHFont.metaFaint)
                .foregroundStyle(theme.faint2)
                .lineLimit(1)
        }
        .padding(.trailing, 14)
    }
}

/// The account string shown in the titlebar. PROVISIONAL source: the active
/// Claude config dir name if set, else the OS user name — both are real,
/// non-fabricated values. The authoritative per-session account source is a
/// Phase-4 data-layer question (spec §4, `account` ⚠️); wired to a real source
/// there. Never invents an identity.
enum TitlebarAccount {
    static var label: String {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !dir.isEmpty {
            return (dir as NSString).lastPathComponent
        }
        return NSUserName()
    }
}

/// Installs / maintains the custom titlebar from within the SwiftUI tree. A
/// zero-size background view that reaches its host `NSWindow`; `updateNSView`
/// re-runs whenever the injected `theme` changes (ContentView reads `\.theme`),
/// re-tinting the band on a flip. Placed in ContentView's background so it does
/// not affect layout.
struct TitlebarConfigurator: NSViewRepresentable {
    let controller: ThemeController
    let theme: Theme

    func makeCoordinator() -> LighthouseTitlebar { LighthouseTitlebar(controller: controller) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.apply(on: window, theme: theme)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        context.coordinator.apply(on: window, theme: theme)
    }
}
