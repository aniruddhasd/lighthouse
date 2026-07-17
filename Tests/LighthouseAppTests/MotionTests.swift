import Testing
@testable import LighthouseApp

/// The pure reduce-motion policy (spec §6 Phase 5). These run without a window
/// server; the MOTION runtime gate in Scripts/smoke-run.sh proves the LIVE beam
/// layer is absent under reduce-motion (which no unit test can reach).
@Suite("Motion decisions")
struct MotionTests {

    /// motionEnabled is exactly the inverse of reduce-motion — no third state.
    @Test func motionEnabledIsInverseOfReduceMotion() {
        #expect(MotionResolver.motionEnabled(reduceMotion: false) == true)
        #expect(MotionResolver.motionEnabled(reduceMotion: true) == false)
    }

    /// The beam requires BOTH the pref AND motion — the full matrix, so a
    /// regression that drops either input is caught. Reduce-motion (motion off)
    /// wins over the pref.
    @Test func beamVisibleRequiresPrefAndMotion() {
        #expect(MotionResolver.beamVisible(showBeam: true, motionEnabled: true) == true)
        #expect(MotionResolver.beamVisible(showBeam: true, motionEnabled: false) == false)
        #expect(MotionResolver.beamVisible(showBeam: false, motionEnabled: true) == false)
        #expect(MotionResolver.beamVisible(showBeam: false, motionEnabled: false) == false)
    }

    /// The debug override forces reduce-motion regardless of the system value
    /// (so the gate can force it headlessly); with no override the system value
    /// stands.
    @Test func debugOverrideForcesReduceMotion() {
        #expect(MotionResolver.effectiveReduceMotion(system: false, forcedByDebug: true) == true)
        #expect(MotionResolver.effectiveReduceMotion(system: true, forcedByDebug: false) == true)
        #expect(MotionResolver.effectiveReduceMotion(system: false, forcedByDebug: false) == false)
        #expect(MotionResolver.effectiveReduceMotion(system: true, forcedByDebug: true) == true)
    }

    /// End-to-end through the resolver: forced reduce-motion disables motion and
    /// hides the beam even when the pref is on (the property the MOTION gate
    /// proves live).
    @Test func forcedReduceMotionHidesBeamEvenWithPrefOn() {
        let reduce = MotionResolver.effectiveReduceMotion(system: false, forcedByDebug: true)
        let motion = MotionResolver.motionEnabled(reduceMotion: reduce)
        #expect(motion == false)
        #expect(MotionResolver.beamVisible(showBeam: true, motionEnabled: motion) == false)
    }
}
