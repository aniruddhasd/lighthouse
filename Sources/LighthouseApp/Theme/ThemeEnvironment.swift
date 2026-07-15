import SwiftUI

/// Delivers the resolved `Theme` to the whole view tree. The default is Beacon
/// so any view rendered outside an injected scope (previews, detached hosting
/// views) still resolves real tokens rather than crashing.
private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = .beacon
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
