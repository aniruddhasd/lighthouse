import SwiftUI

/// Centralised typography. DECIDED (spec §3.2): SF Pro (UI) + SF Mono (mono) —
/// stock, zero supply-chain surface, accessibility-respecting. Every font in
/// the app goes through here so swapping to the branded families (Space Grotesk
/// / JetBrains Mono) later is a one-file change.
///
/// Scale (handoff "Typography"): 23 / 20 / 15 / 14.5 / 13 / 12.5 / 11 / 10.5.
enum LHFont {
    /// SF Pro UI text at an explicit size + weight.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// SF Mono at an explicit size + weight (terminal chrome, code, meta, keycaps).
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // Named scale (the roles the handoff calls out).
    static let harborTitle = ui(23, .bold)        // Harbor title
    static let summaryHead = ui(20, .semibold)    // summary headline
    static let cardTitle = ui(15, .semibold)      // task-card title
    static let taskHeader = ui(14.5, .semibold)   // Focus task header
    static let button = ui(13, .medium)           // buttons / body
    static let body = ui(13)
    static let secondary = ui(12.5)               // secondary / terminal-size text
    static let wordmark = ui(12.5, .semibold)     // titlebar "Lighthouse"
    static let meta = mono(11)                     // meta lines (repo · branch)
    static let metaFaint = mono(11)                // footer / account (size 11)
    static let pill = ui(10.5, .semibold)          // status pills
    static let keycap = mono(10.5, .medium)        // ⌘K etc.
}
