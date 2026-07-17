import SwiftUI

/// The ambient Harbor beam (handoff "Animations": a conic-gradient wedge in
/// `--primary` rotating 360° over ~26s + a soft radial glow, top-left; purely
/// decorative, subtle). A pure BACKGROUND layer: it never affects layout and
/// never intercepts input (`allowsHitTesting(false)`), so the grid geometry and
/// the card taps are untouched. It is only ever MOUNTED when `beamVisible`
/// (showBeam pref AND motion enabled) — so the infinite rotation cannot run
/// under reduce-motion, because the view is absent, not merely paused.
struct AmbientBeam: View {
    @Environment(\.theme) private var theme
    @State private var angle: Double = 0

    var body: some View {
        GeometryReader { geo in
            let diameter = max(geo.size.width, geo.size.height) * 1.7
            ZStack(alignment: .topLeading) {
                // Soft radial glow anchored top-left.
                RadialGradient(
                    colors: [theme.primary.opacity(0.10), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height) * 0.6)

                // Rotating conic wedge: a narrow primary band on an otherwise
                // clear circle, blurred so the edge reads as a soft beam.
                AngularGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.00),
                        .init(color: theme.primary.opacity(0.05), location: 0.06),
                        .init(color: theme.primary.opacity(0.09), location: 0.11),
                        .init(color: theme.primary.opacity(0.05), location: 0.16),
                        .init(color: .clear, location: 0.22),
                        .init(color: .clear, location: 1.00),
                    ]),
                    center: .topLeading)
                    .frame(width: diameter, height: diameter)
                    .rotationEffect(.degrees(angle), anchor: .topLeading)
                    .blur(radius: 34)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .onAppear {
                MotionDebug.beamMounted = true
                MotionDebug.emit("beam-mounted=true")
                withAnimation(.linear(duration: 26).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
            .onDisappear {
                MotionDebug.beamMounted = false
                MotionDebug.emit("beam-unmounted=true")
            }
        }
        .allowsHitTesting(false)
    }
}

/// The Harbor content background: the base `--bg` fill plus the ambient beam
/// when `beamVisible`. A `.background` layer, so it never affects the grid
/// layout. Emits the MOTION-gate render facts (whether the beam actually
/// mounted, and the env-resolved motion decision the app injected) so the gate
/// proves reduce-motion kept the beam absent even with the pref on.
struct HarborBackground: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.theme) private var theme
    @Environment(\.motionEnabled) private var motionEnabled

    var body: some View {
        let beamVisible = MotionResolver.beamVisible(
            showBeam: runtime.model.showBeam, motionEnabled: motionEnabled)
        ZStack {
            theme.bg
            if beamVisible {
                AmbientBeam()
            }
        }
        .ignoresSafeArea()
        .onAppear {
            MotionDebug.emit(
                "harbor-bg-appeared=true beam-present=\(beamVisible) "
                + "env-motion-enabled=\(motionEnabled) showbeam-pref=\(runtime.model.showBeam)")
        }
    }
}
