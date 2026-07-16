import AppKit
import Foundation
import SwiftUI

/// The single reduce-motion decision point (spec §6 Phase 5). PURE and
/// SwiftUI-free so the whole policy is unit-tested without a window server: the
/// `motionEnabled` / `beamVisible` bright lines are just boolean algebra over
/// three inputs (system reduce-motion, the debug override, the beam pref).
///
/// The SwiftUI layer resolves `reduceMotion` from
/// `@Environment(\.accessibilityReduceMotion)` (invalidates automatically when
/// the user flips the System-Settings toggle) or, off the view tree,
/// `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`; the runtime gate
/// forces it via `LIGHTHOUSE_DEBUG_REDUCE_MOTION=1`. Whatever the source, it
/// flows through these three functions so there is exactly one policy.
enum MotionResolver {
    /// Motion runs exactly when reduce-motion is OFF. There is no third state:
    /// reduce-motion on ⇒ every animation is disabled and shown in its final
    /// static frame (no infinite pulse, no rotating beam, instant transitions).
    static func motionEnabled(reduceMotion: Bool) -> Bool { !reduceMotion }

    /// The ambient Harbor beam is visible only when BOTH the pref is on AND
    /// motion is enabled — reduce-motion wins over the pref (handoff: "gate
    /// behind the showBeam preference AND reduce-motion").
    static func beamVisible(showBeam: Bool, motionEnabled: Bool) -> Bool {
        showBeam && motionEnabled
    }

    /// The effective reduce-motion signal: the debug override forces it on
    /// regardless of the system setting (so the MOTION gate can prove motion is
    /// disabled in a headless/CI environment where the real accessibility flag
    /// cannot be toggled); otherwise the system value stands.
    static func effectiveReduceMotion(system: Bool, forcedByDebug: Bool) -> Bool {
        forcedByDebug || system
    }
}

/// LIGHTHOUSE_DEBUG_MOTION=1 / LIGHTHOUSE_DEBUG_REDUCE_MOTION=1 hooks for the
/// MOTION runtime gate. The pure decisions above are unit-tested; this proves,
/// in the assembled app, that reduce-motion genuinely suppresses the ambient
/// beam (the safety property no unit test can reach — the beam is a live
/// SwiftUI layer). Mirrors FocusDebug/HarborDebug.
enum MotionDebug {
    /// The gate is running (emit MOTION-STAGE lines).
    static let enabled = ProcessInfo.processInfo.environment["LIGHTHOUSE_DEBUG_MOTION"] == "1"

    /// Force reduce-motion ON regardless of the system/appearance setting, so
    /// the gate can assert motion-disabled + beam-absent deterministically.
    /// Read once at process start (env is immutable for the run); the gate
    /// proves the opposite (beam-present) case via the pure resolver matrix.
    static let forceReduceMotion =
        ProcessInfo.processInfo.environment["LIGHTHOUSE_DEBUG_REDUCE_MOTION"] == "1"

    /// Whether the ambient beam layer is currently MOUNTED — set by the beam's
    /// onAppear/onDisappear so the driver can prove reduce-motion kept it out of
    /// the tree entirely (not merely hidden). Main-thread only.
    nonisolated(unsafe) static var beamMounted = false

    static func emit(_ message: String) {
        guard enabled else { return }
        FileHandle.standardOutput.write(Data("MOTION-STAGE \(message)\n".utf8))
    }
}

/// Delivers the resolved "should things animate" decision to the whole view
/// tree. Default `true` (motion on) so any view rendered outside an injected
/// scope (previews, detached hosting views) animates normally rather than
/// freezing. `ContentView` injects the real value (system reduce-motion + the
/// debug override) once at the root.
private struct MotionEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var motionEnabled: Bool {
        get { self[MotionEnabledKey.self] }
        set { self[MotionEnabledKey.self] = newValue }
    }
}
