import SwiftUI
import SwiftTerm
import LighthouseAppCore
import LighthouseTaskEngine

struct ContentView: View {
    @Environment(AppRuntime.self) private var runtime
    /// System reduce-motion (System Settings → Accessibility → Display). SwiftUI
    /// invalidates this body when the user flips it, so the app re-resolves
    /// `motionEnabled` live.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showCreateTask = false
    @State private var showRegisterRepo = false
    @State private var taskPendingRemoval: TaskRecord?

    var body: some View {
        @Bindable var runtime = runtime
        // Reading `.resolved` here registers observation on the ThemeController,
        // so a flip re-runs this body and re-injects the new tokens app-wide.
        let theme = runtime.themeController.resolved
        // The single reduce-motion decision, injected once at the root: system
        // reduce-motion, forced on by LIGHTHOUSE_DEBUG_REDUCE_MOTION for the
        // MOTION gate. Every animation downstream keys off `\.motionEnabled`.
        let motionEnabled = MotionResolver.motionEnabled(
            reduceMotion: MotionResolver.effectiveReduceMotion(
                system: reduceMotion, forcedByDebug: MotionDebug.forceReduceMotion))
        // Two-mode shell (spec §3.4): Harbor overview ⇄ Focus (the current
        // NavigationSplitView, lightly adapted; Phase 3 reshapes it). A ZStack
        // + switch, never a Group — a Group would attach these modifiers to
        // each branch and re-fire onAppear (the REVIEWPANE model-recreation
        // scar). The terminal survives the flip because the SessionRegistry
        // owns it outside the view tree; the HARBOR gate proves this.
        ZStack {
            switch runtime.nav.view {
            case .harbor:
                HarborView(showCreateTask: $showCreateTask)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .focus:
                // Phase 3: the beacon-rail + center-column command deck. The old
                // NavigationSplitView shell (SidebarView + detail toolbar) is
                // retired — which also removes the toolbar-KVO-under-sheet
                // fragility flagged in Phase 2.
                FocusView(showCreateTask: $showCreateTask)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The custom titlebar installs itself on the host window from here; a
        // zero-size background view, so no layout is affected.
        .background(TitlebarConfigurator(controller: runtime.themeController, theme: theme))
        .environment(\.theme, theme)
        .environment(\.motionEnabled, motionEnabled)
        // THE COHERENCE FIX (2026-07-15): pin the window's appearance to the
        // theme's — Beacon dark, Native light — so Native's NSColor SEMANTIC
        // tokens (bg/panel/text/…) resolve LIGHT even under a Dark system,
        // matching its literal-light-hex tokens instead of splitting half-light.
        // This must go through SwiftUI (`.preferredColorScheme`), not a manual
        // `window.appearance` set, which SwiftUI clobbers on its next pass. It
        // cascades to the SwiftUI `Color(nsColor:)` tokens, the native controls
        // (segmented switcher, List selection), and the titlebar accessories.
        // Terminal/viewer keep their own dark colors (unaffected).
        .preferredColorScheme(theme.colorScheme)
        .sheet(isPresented: $showCreateTask) { CreateTaskSheet() }
        .sheet(isPresented: $showRegisterRepo) { RegisterRepoSheet() }
        .sheet(item: $taskPendingRemoval) { task in RemoveTaskSheet(task: task) }
        .sheet(isPresented: Binding(
            get: { runtime.setupPresented },
            set: { runtime.setupPresented = $0 })) { SetupView() }
        .overlay {
            if runtime.switcherPresented {
                SwitcherOverlay()
            }
        }
        .alert(
            "Error", isPresented: .init(
                get: { runtime.lastError != nil },
                set: { if !$0 { runtime.lastError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(runtime.lastError ?? "")
        }
        .safeAreaInset(edge: .bottom) {
            if let degraded = runtime.attentionDegraded {
                Text(degraded)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity)
                    .padding(4)
                    .background(.quaternary)
            }
        }
    }

}

/// Hosts the registry-owned terminal NSView. The terminal is created once
/// and RETAINED in the registry; this wrapper only reparents it.
///
/// Sizing scar (2026-07-12, took two attempts): SwiftUI sizes an
/// NSViewRepresentable by `sizeThatFits`, whose DEFAULT answer derives from
/// the platform view's own fitting size — measured live at a constant 181pt
/// tall at every window size — and the enclosing flexible frame then CENTERS
/// that fixed box on both axes (the user-visible bug). The first fix
/// (container + autoresizing pin) only guaranteed terminal == container; the
/// container itself was still sized 181pt by the default negotiation, which
/// unit tests could not see because only a running app performs SwiftUI
/// layout. Fix: `sizeThatFits` adopts the proposal outright — a terminal is
/// a fill-everything view. Proof lives in the scripted geometry check
/// (Scripts/smoke-run.sh, LIGHTHOUSE_DEBUG_GEOMETRY=1).
struct TerminalHostView: NSViewRepresentable {
    let terminalView: LocalProcessTerminalView

    /// Pins `terminal` to fill `container`, tracking all future resizes.
    /// Static so the geometry contract is unit-testable without SwiftUI.
    @MainActor
    static func embed(_ terminal: LocalProcessTerminalView, in container: NSView) {
        terminal.removeFromSuperview()
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        // Adopt exactly what the pane proposes; unspecified dimensions keep
        // the current size rather than inventing an "ideal" one.
        let fallback = nsView.frame.size
        return CGSize(
            width: proposal.width ?? fallback.width,
            height: proposal.height ?? fallback.height)
    }

    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainerView()
        Self.embed(terminalView, in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Selecting another task and coming back builds a fresh container;
        // re-adopt the retained terminal if it isn't ours right now.
        if terminalView.superview !== container {
            Self.embed(terminalView, in: container)
        }
    }
}
