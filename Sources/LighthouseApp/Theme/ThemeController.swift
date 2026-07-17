import Observation
import SwiftUI

/// Owns the currently-active theme and drives app-wide re-resolution. Held by
/// `AppRuntime`; the resolved `Theme` is injected via `.environment(\.theme)`.
/// Flipping `theme` mutates observed state, so every view that read `\.theme`
/// (or `resolved`) re-renders through normal SwiftUI observation — no manual
/// invalidation. `onChange` persists the choice (AppRuntime wires it to config).
@MainActor
@Observable
final class ThemeController {
    private(set) var theme: LighthouseTheme
    private let onChange: (LighthouseTheme) -> Void

    init(initial: LighthouseTheme, onChange: @escaping (LighthouseTheme) -> Void = { _ in }) {
        self.theme = initial
        self.onChange = onChange
    }

    /// The resolved token set for the active theme. Reading this in a view body
    /// registers observation on `theme`.
    var resolved: Theme { Theme.forKind(theme) }

    /// Switch themes. A no-op when unchanged so the switcher control doesn't
    /// re-persist or churn observers on redundant taps.
    func set(_ newTheme: LighthouseTheme) {
        guard newTheme != theme else { return }
        theme = newTheme
        onChange(newTheme)
    }

    /// A two-way binding for a segmented `Picker` (the titlebar switcher).
    var binding: Binding<LighthouseTheme> {
        Binding(get: { self.theme }, set: { self.set($0) })
    }
}
