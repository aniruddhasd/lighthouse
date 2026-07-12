import AppKit
import Foundation

/// Diagnostic scar from the terminal-sizing bug (2026-07-12): unit tests
/// proved the AppKit layer while the real app still mis-sized, because the
/// failure lived in the SwiftUI↔representable size negotiation that only a
/// running app exercises. This env-gated mode makes real-app geometry
/// observable and scriptable:
///
///   LIGHTHOUSE_DEBUG_GEOMETRY=1  → an ephemeral probe task with a /bin/cat
///   session is selected at launch, GEOMETRY lines are printed on every
///   layout pass, and the window auto-resizes once so the check sees two
///   sizes. Scripts/smoke-run.sh parses and asserts them.
enum GeometryDebug {
    static let enabled = ProcessInfo.processInfo.environment["LIGHTHOUSE_DEBUG_GEOMETRY"] == "1"

    static func log(window: NSSize, container: NSRect, terminal: NSRect) {
        guard enabled else { return }
        let line = String(
            format: "GEOMETRY window=%.0fx%.0f container=%.0fx%.0f terminal=%.0fx%.0f terminalOrigin=%.0f,%.0f\n",
            window.width, window.height,
            container.width, container.height,
            terminal.width, terminal.height,
            terminal.origin.x, terminal.origin.y)
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}

/// Container that reports its own and its terminal subview's frames on every
/// layout pass while the debug mode is on.
final class TerminalContainerView: NSView {
    override func layout() {
        super.layout()
        guard GeometryDebug.enabled, let terminal = subviews.first else { return }
        GeometryDebug.log(
            window: window?.contentLayoutRect.size ?? .zero,
            container: frame,
            terminal: terminal.frame)
    }
}

/// Which build is running — never ambiguous again. make-app.sh stamps the
/// git short hash into CFBundleVersion; bare `swift run` builds show "dev".
enum BuildInfo {
    static var stamp: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            .flatMap { $0 == "1" ? nil : $0 } ?? "dev"
    }
}

import SwiftUI

/// SwiftUI-side size probe: logs the ACTUAL laid-out size of the view it is
/// attached to, labeled, on every change. Debug mode only; otherwise inert.
struct DebugSizeModifier: ViewModifier {
    let label: String

    func body(content: Content) -> some View {
        if GeometryDebug.enabled {
            content.background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { report(geo.size) }
                        .onChange(of: geo.size) { _, new in report(new) }
                })
        } else {
            content
        }
    }

    private func report(_ size: CGSize) {
        let line = String(format: "GEOMETRY-SWIFTUI label=%@ size=%.0fx%.0f\n", label, size.width, size.height)
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}

extension View {
    func debugSize(_ label: String) -> some View {
        modifier(DebugSizeModifier(label: label))
    }
}
