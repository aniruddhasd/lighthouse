import SwiftUI
import LighthouseAppCore

/// The standard macOS Preferences window (⌘,), the `Settings { }` scene's
/// content. Exactly the three prefs from spec §7 — default theme, start view,
/// ambient beam — no others. Token-driven + theme-aware: it reads the SAME
/// `themeController` the titlebar switcher drives (single source of truth), so a
/// theme change here and there never diverge.
struct PreferencesView: View {
    @Environment(AppRuntime.self) private var runtime

    var body: some View {
        // Reading `.resolved` registers observation on the ThemeController, so a
        // flip (here or from the titlebar) re-themes this window too.
        let theme = runtime.themeController.resolved
        Form {
            Section {
                Picker("Default theme", selection: runtime.themeController.binding) {
                    ForEach(LighthouseTheme.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                Text("Beacon is the custom dark palette; Native follows the light macOS look and your accent color.")
                    .font(LHFont.metaFaint)
                    .foregroundStyle(theme.dim)
            }

            Section {
                Picker("Start view", selection: startViewBinding) {
                    Text("Harbor").tag("harbor")
                    Text("Focus").tag("focus")
                }
                .pickerStyle(.segmented)
                Text("Which view Lighthouse opens on the next launch.")
                    .font(LHFont.metaFaint)
                    .foregroundStyle(theme.dim)
            }

            Section {
                Toggle("Ambient beam", isOn: showBeamBinding)
                Text("A subtle rotating glow behind the Harbor grid. Always off while Reduce Motion is on.")
                    .font(LHFont.metaFaint)
                    .foregroundStyle(theme.dim)
            }

            Section {
                Stepper(
                    value: terminalFontSizeBinding,
                    in: AppModel.terminalFontRange,
                    step: 1
                ) {
                    Text("Terminal font size: \(Int(runtime.model.terminalFontSize.rounded())) pt")
                }
                Text("Applies to every terminal immediately. JetBrains Mono, \(Int(AppModel.terminalFontRange.lowerBound))–\(Int(AppModel.terminalFontRange.upperBound)) pt.")
                    .font(LHFont.metaFaint)
                    .foregroundStyle(theme.dim)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .background(theme.bg)
        .environment(\.theme, theme)
        // Pin the window appearance to the theme, exactly as the main window
        // does (the 2026-07-15 coherence fix) so Native's semantic tokens
        // resolve light even under a Dark system.
        .preferredColorScheme(theme.colorScheme)
    }

    /// Start view is a persisted DEFAULT (consumed only at launch), so this
    /// binding just writes the preference — it does not switch the live view.
    private var startViewBinding: Binding<String> {
        Binding(
            get: { runtime.model.startView == "focus" ? "focus" : "harbor" },
            set: { runtime.model.setStartView($0) })
    }

    /// The Harbor beam reads `model.showBeam` live, so toggling this mounts /
    /// unmounts the beam immediately (subject to reduce-motion).
    private var showBeamBinding: Binding<Bool> {
        Binding(
            get: { runtime.model.showBeam },
            set: { runtime.model.setShowBeam($0) })
    }

    /// Font size routes through the runtime (not the model directly) so live
    /// terminals are re-fonted in the same call that persists the value.
    private var terminalFontSizeBinding: Binding<Double> {
        Binding(
            get: { runtime.model.terminalFontSize },
            set: { runtime.setTerminalFontSize($0) })
    }
}
