import AppKit
import Foundation
import Observation
import SwiftUI
import LighthouseAdapter
import LighthouseAppCore
import LighthouseGit
import LighthouseTaskEngine

/// Composition root: builds the model, the attention socket, and the session
/// registry; pumps socket signals into the model; owns UI-level state that
/// isn't worth persisting (selection, switcher visibility, last error).
@MainActor @Observable
final class AppRuntime {
    let model: AppModel
    /// Per-task derived metadata for the Harbor cards / Focus footer / Summary
    /// (Phase 4). Re-derivable, not persisted; fed by the attention signal loop
    /// (baked/action/model/ctx) and Focus entry / Stop (diffStat).
    let digests = TaskDigestCache()
    let registry = SessionRegistry()
    /// Routes wheel events over terminals into mouse reports when the TUI
    /// owns the mouse (see LighthouseTerminalView).
    private let wheelMonitor = WheelReportMonitor()
    /// Single GitClient shared by the model and the review pane.
    let git = GitClient()
    private let adapter = ClaudeCodeAdapter()

    /// Owns the active theme and drives app-wide re-resolution; the resolved
    /// Theme is injected via `.environment(\.theme)`. Seeded from persisted
    /// config, and persists back through AppModel on every flip.
    let themeController: ThemeController

    var selectedTaskId: UUID?
    var switcherPresented = false
    /// Drives the ⌘P file-finder overlay (quick-open). On the runtime so the
    /// global File-menu command can toggle it; the overlay itself is mounted in
    /// Focus, where the active workbench (and thus the repo's file list) lives.
    var fileFinderPresented = false
    /// Drives the content-search overlay (git grep). Same Focus-only mounting
    /// as the file finder.
    var contentSearchPresented = false
    /// Whether the content search opens scoped to the current file (⌘F, "find in
    /// file") or repo/folder-wide (⇧⌘F, "find in files"). Set by the command
    /// before presenting; read by the overlay on appear.
    var contentSearchScopeToFile = false
    /// The task the user is confirming removal of, if any — drives the
    /// RemoveTaskSheet. On the runtime (not a view's @State) so any task
    /// surface (Harbor card, beacon-rail dot) can trigger it without threading
    /// a binding down; the old sidebar that owned this trigger was retired.
    var taskPendingRemoval: TaskRecord?
    /// Drives the "add a repo/worktree to this task" sheet. Item-based so the
    /// navigator's + button (and any future entry point) can open it for a
    /// specific task without threading a binding down.
    var taskPendingAddWorkspace: TaskRecord?
    /// Drives the Register-Repo sheet. On the runtime (like `switcherPresented`)
    /// so the File menu command AND the Harbor "Add repo" controls can all open
    /// it — the sidebar that used to own this trigger was retired.
    var registerRepoPresented = false
    /// Two-mode navigation (spec §3.4): Harbor overview ⇄ Focus. Seeded from
    /// the persisted `startView` in init; a persisted `.focus` with nothing
    /// selected falls back to Harbor. Mutating it re-renders the shell (normal
    /// @Observable propagation).
    var nav = NavigationState()
    /// Surfaced verbatim in the UI — always the full typed description.
    var lastError: String?

    /// LIGHTHOUSE_CONFIG_DIR overrides the config+socket location — used by
    /// scripted checks so they never touch the real config or unlink a live
    /// instance's socket.
    static func defaultConfigDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["LIGHTHOUSE_CONFIG_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lighthouse", isDirectory: true)
    }

    init(configDirectory: URL = AppRuntime.defaultConfigDirectory()) {
        model = AppModel(
            store: ConfigStore(directory: configDirectory),
            adapter: adapter,
            git: git)
        do {
            try model.load()
        } catch {
            lastError = "Could not load config: \(error)"
        }
        // Seed the terminal font size from persisted config so the first session
        // opens at the chosen size (subsequent changes go through
        // setTerminalFontSize, which also re-fonts live terminals).
        registry.applyFontSize(CGFloat(model.terminalFontSize))
        // Seed the theme from persisted config (unknown value fails safe to
        // Beacon); each flip persists back through AppModel.
        let loadedModel = model
        themeController = ThemeController(
            initial: LighthouseTheme.from(rawValue: model.theme),
            onChange: { newTheme in loadedModel.setTheme(newTheme.rawValue) })
        // Land on the persisted start view (default Harbor). A persisted
        // `.focus` with no selection (always true at cold start — selection is
        // session-only) falls back to Harbor rather than a blank detail pane.
        let startView: NavView = model.startView == "focus" ? .focus : .harbor
        nav = NavigationState(view: startView == .focus && selectedTaskId == nil ? .harbor : startView)
        // First-run setup auto-opens when there are no repos and setup was
        // never completed; always re-runnable from Help.
        setupPresented = model.repos.isEmpty && !model.hasCompletedSetup
        setUpGeometryProbeIfRequested()
        runDiffRenderCheckIfRequested()
        runFileRenderCheckIfRequested()
        runNavigatorCheckIfRequested()
        runThemeCheckIfRequested()
        runHarborCheckIfRequested()
        runFocusCheckIfRequested()
        runDigestCheckIfRequested()
        runMotionCheckIfRequested()
    }

    /// LIGHTHOUSE_DEBUG_MOTION=1: proves the Phase-5 reduce-motion contract in
    /// the REAL app. The pure decisions (MotionResolver) are unit-tested; this
    /// gate proves the wiring the unit tests cannot — that the ambient beam, a
    /// LIVE SwiftUI layer, is genuinely ABSENT under reduce-motion even with the
    /// `showBeam` pref ON (reduce-motion wins), and that the env-injected
    /// `motionEnabled` the app resolved is false. Run WITH
    /// LIGHTHOUSE_DEBUG_REDUCE_MOTION=1 to force reduce-motion in a headless
    /// context; the beam's own render fact (from HarborBackground) is the
    /// fail-before target — a beam that ignored reduce-motion would flip
    /// `beam-present` to true here.
    private func runMotionCheckIfRequested() {
        guard MotionDebug.enabled else { return }
        // Keep the first-run setup sheet down (empty isolated config), matching
        // the other launched-directly gates.
        setupPresented = false
        Task { @MainActor in
            func log(_ m: String) {
                FileHandle.standardOutput.write(Data("MOTION-STAGE \(m)\n".utf8))
            }
            let forced = MotionDebug.forceReduceMotion
            let system = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let effReduce = MotionResolver.effectiveReduceMotion(
                system: system, forcedByDebug: forced)
            let motionEnabled = MotionResolver.motionEnabled(reduceMotion: effReduce)
            log("forced-reduce=\(forced) system-reduce=\(system) motion-enabled=\(motionEnabled)")

            // beamVisible tracks `showBeam && motionEnabled` EXACTLY — the full
            // matrix, so both the true and the false cases are asserted (the env
            // is immutable for the run, so the positive case is proven here via
            // the resolver rather than by flipping the override at runtime).
            log("beamvis-motion-on-beam-on="
                + "\(MotionResolver.beamVisible(showBeam: true, motionEnabled: true))")
            log("beamvis-motion-on-beam-off="
                + "\(MotionResolver.beamVisible(showBeam: false, motionEnabled: true))")
            log("beamvis-motion-off-beam-on="
                + "\(MotionResolver.beamVisible(showBeam: true, motionEnabled: false))")

            // The pref is ON by default (empty config) — so a live beam under
            // forced reduce-motion must be ABSENT. Let Harbor settle, then
            // report whether the beam layer actually mounted.
            log("showbeam-pref=\(model.showBeam)")
            try? await Task.sleep(for: .milliseconds(900))
            log("beam-when-reduced=\(MotionDebug.beamMounted ? "present" : "absent")")
            log("done")
        }
    }

    /// LIGHTHOUSE_DEBUG_DIGEST=1: proves the Phase-4 per-task digest in the REAL
    /// app. The pure pieces (DiffStat.parse, TranscriptReader, TaskDigestCache,
    /// baked timing) are unit-tested; this gate proves the wiring end-to-end —
    /// the DETERMINISTIC diff counts are EXACT for a seeded task against a real
    /// temp git fixture with a known add/del/files; the Summary renders and
    /// DEGRADES GRACEFULLY with no transcript/recap (model/ctx stay blank, NOT
    /// zeros); and a hostile `action` (script/markup) is stored VERBATIM and
    /// rendered inert (SwiftUI `Text`, which never interprets markup).
    ///
    /// Builds the fixture synchronously, seeds an ephemeral repo+task over it,
    /// then drives + asserts in a Task. Emits `DIGEST-STAGE …` facts; the
    /// smoke-run block asserts on them (with fail-before evidence).
    private func runDigestCheckIfRequested() {
        guard ProcessInfo.processInfo.environment["LIGHTHOUSE_DEBUG_DIGEST"] == "1" else { return }
        setupPresented = false

        func log(_ m: String) {
            FileHandle.standardOutput.write(Data("DIGEST-STAGE \(m)\n".utf8))
        }

        // A real git fixture with a KNOWN diff vs base "main":
        //   a.txt: append 2 lines            → +2 / -0   (unstaged)
        //   c.txt: remove 1 line             → +0 / -1   (unstaged)
        //   b.txt: new 1-line file, staged   → +1 / -0
        // Expected total: files=3, added=3, deleted=1 (append & pure-delete are
        // unambiguous in git numstat, so the target is deterministic).
        guard let fixture = Self.buildDigestFixture() else {
            log("fixture-failed"); log("done"); return
        }

        let repo = RepoConfig(path: fixture.path, baseBranch: "main")
        model.insertEphemeralRepo(repo)
        let workspace = Workspace(
            repoId: repo.id, worktreePath: fixture.path, mergeState: .unmerged)
        let task = TaskRecord(
            name: "digest-probe", branch: "task/digest", adapterKind: "debug",
            sessionRef: nil, workspaces: [workspace])
        model.insertEphemeralTask(task)

        // A hostile last-assistant-message: markup + script + markdown. Stored
        // verbatim, rendered via `Text` (inert). Also proves baked timing when
        // fed through the cache's real recordStop path with explicit clocks.
        let hostile = "<script>alert('x')</script> **bold** [link](javascript:void) </div>"

        Task { @MainActor in
            // 1. Deterministic diffStat, EXACT against the fixture.
            await refreshDiffDigest(for: task)
            let stat = digests.digest(for: task.id).diffStat
            let files = stat?.filesChanged ?? -1
            let add = stat?.added ?? -1
            let del = stat?.deleted ?? -1
            log("diffstat=files=\(files),add=\(add),del=\(del)")
            log("diffstat-exact=\(files == 3 && add == 3 && del == 1)")

            // 2. baked timing (explicit clocks: 2.0s turn) + hostile action.
            let t0 = Date()
            digests.noteWorkStarted(taskId: task.id, at: t0)
            digests.recordStop(taskId: task.id, action: hostile, at: t0.addingTimeInterval(2))
            let d = digests.digest(for: task.id)
            log("baked=\(d.baked ?? -1)")

            // 3. Graceful degradation: NO transcript was read, so model/ctx are
            //    blank (nil) — NOT zeros — while the deterministic diff stands.
            log("degrade-model-blank=\(d.model == nil) degrade-ctx-blank=\(d.context == nil) "
                + "degrade-diff-known=\(d.diffStat != nil)")

            // 4. Hostile action stored VERBATIM (not stripped/interpreted); the
            //    Summary renders it through SwiftUI `Text` (inert by type).
            log("action-verbatim=\(d.action == hostile)")

            // 5. Summary renders without crashing: enter Focus + Summary mode
            //    and settle. Reaching `done` after this is the no-crash proof.
            open(task.id)
            try? await Task.sleep(for: .milliseconds(300))
            FocusDebug.currentWorkbench?.setBodyMode(.summary)
            try? await Task.sleep(for: .milliseconds(500))
            log("summary-rendered=true")
            backToHarbor()
            log("done")
        }
    }

    /// Builds a throwaway git repo on branch `main` with a deterministic known
    /// diff (see the gate). Returns its URL, or nil on any git failure. Uses
    /// /usr/bin/git directly with an argument array (no shell).
    private static func buildDigestFixture() -> URL? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lighthouse-digest-\(UUID().uuidString)", isDirectory: true)

        func git(_ args: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = root
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        func write(_ name: String, _ contents: String) -> Bool {
            (try? contents.write(
                to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)) != nil
        }

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch { return nil }

        guard git(["init", "-b", "main"]),
              write("a.txt", "a\nb\nc\n"),
              write("c.txt", "x\ny\nz\n"),
              git(["add", "a.txt", "c.txt"]),
              git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "base"]),
              // Working changes vs the base commit (== merge base of main/HEAD):
              write("a.txt", "a\nb\nc\nd\ne\n"),   // +2
              write("c.txt", "x\ny\n"),            // -1
              write("b.txt", "hello\n"),           // new
              git(["add", "b.txt"])                // stage the new file so it appears
        else { return nil }
        return root
    }

    /// LIGHTHOUSE_DEBUG_FOCUS=1: proves the Phase-3 Focus reshape in the REAL
    /// app. The §3.4 body-state rules are unit-tested headlessly (FocusBodyState)
    /// and the beacon-rail/header/footer/overlay geometry is not headlessly
    /// testable (the scar); this gate proves the wiring the unit tests cannot —
    /// the rail renders a dot per task and a dot drives `open(id)`; the task
    /// header + footer render; the navigator is a REAL slide-in overlay driven by
    /// `navigatorVisible` (mounts/unmounts, not a split column); the viewer
    /// overlay WINS over terminal/summary and a mode switch clears it (asserted
    /// on the LIVE mounted workbench); and — the two highest-value invariants —
    /// the registry-owned terminal survives a full mode swap AND a nav toggle
    /// (never tied to the view lifecycle), and it FILLS the center column's body
    /// (not centered/collapsed — the sizing scar).
    ///
    /// Seeds ephemeral tasks + a live /bin/cat agent pty synchronously, then
    /// drives + asserts in a Task. The reshaped views emit their own render
    /// facts (rail dots, header/footer present, terminal frames); this driver
    /// emits the interaction facts.
    private func runFocusCheckIfRequested() {
        guard FocusDebug.enabled else { return }
        setupPresented = false
        // An ephemeral repo so New task enables and repo names render.
        let repo = RepoConfig(
            path: FileManager.default.temporaryDirectory.path, baseBranch: "main")
        model.insertEphemeralRepo(repo)
        // Three tasks so the rail shows a non-trivial dot count.
        var seeded: [TaskRecord] = []
        for name in ["focus-probe", "focus-two", "focus-three"] {
            let task = TaskRecord(
                name: name, branch: "task/\(name)", adapterKind: "debug",
                sessionRef: nil, workspaces: [])
            model.insertEphemeralTask(task)
            seeded.append(task)
        }
        // The probe carries a live /bin/cat pty + tabs so entering Focus renders
        // a real, running terminal (the terminal-alive + terminal-fills probes).
        let probe = seeded[0]
        let plan = LaunchPlan(
            executable: "/bin/cat", arguments: [], environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory,
            sessionRef: "focus-probe")
        registry.open(taskId: probe.id, tabId: TabID.agent, plan: plan) { _, _ in }
        tabs[probe.id] = [TerminalTab(id: TabID.agent, title: "Agent", isAgent: true)]
        focusedTab[probe.id] = TabID.agent

        Task { @MainActor in
            func log(_ m: String) {
                FileHandle.standardOutput.write(Data("FOCUS-STAGE \(m)\n".utf8))
            }

            // Enter Focus on the probe — the reshaped view mounts + renders a
            // real terminal; the rail/header/footer emit their own facts.
            open(probe.id)
            try? await Task.sleep(for: .milliseconds(900))

            guard let wb = FocusDebug.currentWorkbench else {
                log("no-workbench"); log("done"); return
            }

            // §3.4 viewer precedence, on the LIVE mounted model. A selection (via
            // activateViewer) WINS over the active mode without changing it; the
            // segmented control (setBodyMode) CLEARS the viewer.
            wb.setBodyMode(.terminal)
            wb.bodyState.activateViewer()
            log("viewer-wins-over-terminal="
                + "\(wb.effectiveBody == .viewer && wb.bodyState.mode == .terminal)")
            wb.setBodyMode(.summary)
            log("setmode-clears-viewer="
                + "\(wb.effectiveBody == .summary && !wb.bodyState.viewerActive)")
            wb.bodyState.activateViewer()
            log("viewer-wins-over-summary="
                + "\(wb.effectiveBody == .viewer && wb.bodyState.mode == .summary)")
            wb.showTerminal() // ⌘J: close the viewer → back to the active mode
            log("closeviewer-returns-to-mode=\(wb.effectiveBody == .summary)")
            wb.setBodyMode(.terminal)

            // ★ Terminal-alive across a full mode swap (terminal→summary→viewer
            // →terminal) AND a nav toggle — the SAME running registry controller.
            let before = registry.agentController(taskId: probe.id)
            let beforeId = before.map(ObjectIdentifier.init)
            let beforeRunning = before?.isRunning ?? false
            wb.setBodyMode(.summary); try? await Task.sleep(for: .milliseconds(150))
            wb.bodyState.activateViewer(); try? await Task.sleep(for: .milliseconds(150))
            wb.showTerminal(); wb.setBodyMode(.terminal)
            try? await Task.sleep(for: .milliseconds(150))
            wb.navigatorVisible = true; try? await Task.sleep(for: .milliseconds(300))
            wb.navigatorVisible = false; try? await Task.sleep(for: .milliseconds(300))
            let after = registry.agentController(taskId: probe.id)
            let afterId = after.map(ObjectIdentifier.init)
            let alive = beforeId != nil && beforeId == afterId
                && beforeRunning && (after?.isRunning ?? false)
            log("terminal-alive=\(alive)")

            // The navigator is a REAL mounted overlay driven by navigatorVisible
            // (not an always-present, always-hidden view, and not a split column).
            wb.navigatorVisible = true; try? await Task.sleep(for: .milliseconds(450))
            let mountedWhenOpen = FocusDebug.navigatorMounted
            wb.navigatorVisible = false; try? await Task.sleep(for: .milliseconds(450))
            let unmountedWhenClosed = !FocusDebug.navigatorMounted
            log("nav-open-mounted=\(mountedWhenOpen) nav-closed-unmounted=\(unmountedWhenClosed)")

            // A rail dot drives open(id): selecting the 'working' task.
            open(seeded[1].id)
            log("rail-dot-view=\(nav.view.rawValue) "
                + "rail-dot-selected=\(selectedTaskId == seeded[1].id)")

            // Back to Harbor so the probe terminal doesn't hold the view at exit.
            backToHarbor()
            log("done")
        }
    }

    /// LIGHTHOUSE_DEBUG_HARBOR=1: proves the Phase-2 two-mode shell in the REAL
    /// app. The pure sort/filter/nav-transition logic is unit-tested headlessly
    /// (LighthouseAppCore); this gate proves the wiring the unit tests cannot —
    /// the live Harbor grid renders the seeded cards, `HarborOrder` + the filter
    /// chips are correct over real seeded state, card→Focus and ⌘K→Focus flip
    /// the runtime, and — the highest-value invariant — the registry-owned
    /// terminal survives an actual Harbor↔Focus view flip (the pty is never
    /// tied to the Focus view's appearance; the scar).
    ///
    /// Seeds ephemeral tasks synchronously (so the window's first Harbor render
    /// shows them), then drives + asserts in a Task. `HarborView` emits its own
    /// `rendered-cards=` line from the live render; this driver emits the rest.
    private func runHarborCheckIfRequested() {
        guard HarborDebug.enabled else { return }
        // Suppress the first-run setup sheet: with an isolated empty config it
        // auto-opens, and toggling Harbor⇄Focus adds/removes the split view's
        // NSToolbar under that sheet, which crashes SwiftUI's toolbar KVO
        // (NSSheetEffectDimmingView). Not a real-app path (empty config = no
        // tasks to open), but the gate drives the flip, so keep the sheet down.
        setupPresented = false
        // An ephemeral repo so the Repos section renders (and New task enables).
        let repo = RepoConfig(
            path: FileManager.default.temporaryDirectory.path, baseBranch: "main")
        model.insertEphemeralRepo(repo)
        // Seed one task per state — two needsInput so the group order and the
        // Five tasks so the grid renders a non-trivial card count.
        var seeded: [TaskRecord] = []
        for name in ["harbor-a", "harbor-b", "harbor-c", "harbor-d", "harbor-e"] {
            let task = TaskRecord(
                name: name, branch: "task/\(name)", adapterKind: "debug",
                sessionRef: nil, workspaces: [])
            model.insertEphemeralTask(task)
            seeded.append(task)
        }
        // The first task doubles as the terminal-survival probe: a live /bin/cat
        // pty + tabs so entering Focus renders a real, running terminal.
        let probe = seeded[0]
        let plan = LaunchPlan(
            executable: "/bin/cat", arguments: [], environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory,
            sessionRef: "harbor-probe")
        registry.open(taskId: probe.id, tabId: TabID.agent, plan: plan) { _, _ in }
        tabs[probe.id] = [TerminalTab(id: TabID.agent, title: "Agent", isAgent: true)]
        focusedTab[probe.id] = TabID.agent

        let seededIds = Set(seeded.map(\.id))
        Task { @MainActor in
            func log(_ m: String) {
                FileHandle.standardOutput.write(Data("HARBOR-STAGE \(m)\n".utf8))
            }

            // Order: the standard task order includes every seeded task.
            let ordered = model.orderedTasks().filter { seededIds.contains($0.id) }
            log("ordered-count=\(ordered.count)")

            // card → Focus: driving `open(id)` (what a card tap calls) sets
            // view=.focus AND the selection.
            open(seeded[2].id) // the working task
            log("card-open-view=\(nav.view.rawValue) "
                + "card-open-selected=\(selectedTaskId == seeded[2].id)")
            backToHarbor()
            log("back-view=\(nav.view.rawValue)")

            // ⌘K → Focus: the SwitcherOverlay's select calls this same `open`.
            open(seeded[3].id) // the idle task
            log("switcher-open-view=\(nav.view.rawValue)")
            backToHarbor()

            // Terminal-alive across a LIVE Harbor↔Focus flip. Drive the real
            // view tree: open the probe (Focus mounts + renders its terminal),
            // let SwiftUI settle, flip to Harbor (Focus TEARS DOWN — the pty
            // must not die with it), open again, settle. The registry must hand
            // back the SAME controller instance, still running.
            open(probe.id)
            try? await Task.sleep(for: .milliseconds(700))
            let before = registry.agentController(taskId: probe.id)
            let beforeId = before.map(ObjectIdentifier.init)
            let beforeRunning = before?.isRunning ?? false
            backToHarbor()
            try? await Task.sleep(for: .milliseconds(500))
            open(probe.id)
            try? await Task.sleep(for: .milliseconds(700))
            let after = registry.agentController(taskId: probe.id)
            let afterId = after.map(ObjectIdentifier.init)
            let alive = beforeId != nil && beforeId == afterId
                && beforeRunning && (after?.isRunning ?? false)
            log("terminal-alive=\(alive)")

            // Return to Harbor so the terminal probe doesn't hold the view.
            backToHarbor()
            log("done")
        }
    }

    /// LIGHTHOUSE_DEBUG_THEME=1: proves the theme foundation in the REAL app —
    /// both palettes resolve and DIFFER, `termbg` stays dark across the flip
    /// (the "viewer stays dark" rule), and the custom titlebar came up with its
    /// trailing accessory + theme switcher + centered wordmark. Logs stage
    /// markers for Scripts/smoke-run.sh to assert. Follows the existing
    /// LIGHTHOUSE_DEBUG_* stdout stage-logging pattern; launched directly like
    /// the GEOMETRY gate (a window is created, which the titlebar needs).
    private func runThemeCheckIfRequested() {
        guard ProcessInfo.processInfo.environment["LIGHTHOUSE_DEBUG_THEME"] == "1" else { return }
        Task { @MainActor in
            func log(_ m: String) {
                FileHandle.standardOutput.write(Data("THEME-STAGE \(m)\n".utf8))
            }
            let beacon = Theme.beacon
            let native = Theme.native

            // Every token resolves to a real sRGB color in BOTH themes (a nil
            // means a token that could not resolve — a real failure).
            let beaconResolves = Self.allTokensResolve(beacon)
            let nativeResolves = Self.allTokensResolve(native)
            log("beacon-all-resolve=\(beaconResolves) native-all-resolve=\(nativeResolves)")

            // Representative tokens, with Beacon's exact documented hex.
            // Theme-prefixed keys so the two lines don't collide when parsed.
            log("beacon-bg=\(beacon.bg.srgbHex ?? "nil") beacon-chrome=\(beacon.chrome.srgbHex ?? "nil") beacon-primary=\(beacon.primary.srgbHex ?? "nil") beacon-termbg=\(beacon.termbg.srgbHex ?? "nil")")
            log("native-bg=\(native.bg.srgbHex ?? "nil") native-chrome=\(native.chrome.srgbHex ?? "nil") native-primary=\(native.primary.srgbHex ?? "nil") native-termbg=\(native.termbg.srgbHex ?? "nil")")

            // Flipping visibly changes chrome.
            log("differ=\((beacon.bg.srgbHex ?? "a") != (native.bg.srgbHex ?? "b"))")

            // termbg near-black in BOTH themes (guards the stay-dark rule).
            let bDark = (beacon.termbg.srgbLuminance ?? 1) < 0.15
            let nDark = (native.termbg.srgbLuminance ?? 1) < 0.15
            log("termbg-dark-beacon=\(bDark) termbg-dark-native=\(nDark)")

            // Actually flip the live controller and confirm termbg stays dark.
            themeController.set(.native)
            let afterFlipDark = (themeController.resolved.termbg.srgbLuminance ?? 1) < 0.15
            log("flip=beacon->native termbg-still-dark=\(afterFlipDark)")
            themeController.set(.beacon)

            // Poll for the custom titlebar to finish installing on the window.
            var titlebar: LighthouseTitlebar?
            for _ in 0..<100 {
                if let current = LighthouseTitlebar.current, current.hasTrailingAccessory {
                    titlebar = current
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            log("titlebar-accessory=\(titlebar?.hasTrailingAccessory ?? false) switcher=\(titlebar?.hasSwitcher ?? false) wordmark=\(titlebar?.hasWordmark ?? false)")

            // COHERENCE (the 2026-07-15 half-light bug): for each theme, pin the
            // live window appearance, then resolve tokens WITHIN THAT WINDOW
            // APPEARANCE — mirroring exactly what the user sees. This depends on
            // the app actually pinning the window (without the pin, the window
            // stays in the process/system appearance and Native's semantic bg
            // resolves DARK under a dark process → the native-bg-light assertion
            // FAILS). Independent of the process/system Light/Dark setting.
            for kind in [LighthouseTheme.beacon, LighthouseTheme.native] {
                themeController.set(kind)
                let expected = kind.nsAppearanceName
                var appearance: NSAppearance?
                // Re-fetch the live titlebar each iteration (not a captured ref)
                // so a slow first install can't produce a flaky nil, and wait
                // for the window's effective appearance to settle on the flip.
                for _ in 0..<50 {
                    if let ea = LighthouseTitlebar.current?.windowEffectiveAppearance,
                       ea.bestMatch(from: [.aqua, .darkAqua]) == expected {
                        appearance = ea
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let theme = Theme.forKind(kind)
                let ea = appearance ?? LighthouseTitlebar.current?.windowEffectiveAppearance
                let matched = ea?.bestMatch(from: [.aqua, .darkAqua]) == expected
                let bgLum = ea.flatMap { theme.bg.srgbLuminance(in: $0) } ?? -1
                let textLum = ea.flatMap { theme.text.srgbLuminance(in: $0) } ?? -1
                let name = kind == .beacon ? "beacon" : "native"
                log("\(name)-window-pinned=\(matched) \(name)-bg-lum=\(String(format: "%.3f", bgLum)) \(name)-text-lum=\(String(format: "%.3f", textLum))")
                if kind == .beacon {
                    log("beacon-bg-dark=\(bgLum >= 0 && bgLum < 0.15) beacon-text-light=\(textLum > 0.6)")
                } else {
                    log("native-bg-light=\(bgLum > 0.7) native-text-dark=\(textLum >= 0 && textLum < 0.3)")
                }
            }
            themeController.set(.beacon)
            log("done")
        }
    }

    /// Every SwiftUI Color token in a theme resolves to a real sRGB triple.
    private static func allTokensResolve(_ t: Theme) -> Bool {
        let tokens: [Color] = [
            t.bg, t.chrome, t.panel, t.panel2, t.panel3, t.elev,
            t.border, t.border2, t.borderSoft,
            t.text, t.dim, t.faint, t.faint2, t.termbg,
            t.primary, t.primaryText, t.sb,
            t.working, t.needs, t.idle, t.stale,
            t.addedTextChrome, t.addedTextTerminal, t.removedTextChrome, t.removedTextTerminal,
            t.modelDot, t.contextMeterStart, t.contextMeterEnd, t.diffVsBase,
            t.badgeAdded, t.badgeModified, t.badgeDeleted,
        ]
        return tokens.allSatisfy { $0.srgbHex != nil }
    }

    /// Whether the first-run setup sheet is showing.
    var setupPresented = false
    private let loginShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

    // MARK: - Two-mode navigation (spec §3.4)

    /// Open a task in Focus — the card / ⌘K-result / beacon-dot action. Applies
    /// the selection, closes ⌘K, and flips the view to Focus (matching the
    /// prototype's `open(id)`). The terminal is untouched: the SessionRegistry
    /// owns it, so entering Focus only reparents the retained NSView.
    func open(_ id: UUID) {
        selectedTaskId = id
        switcherPresented = false
        nav.open()
        // Focus entry is a digest refresh trigger (spec §4): recompute the
        // deterministic diff counts for the task now being viewed.
        if let task = model.tasks.first(where: { $0.id == id }) {
            Task { await refreshDiffDigest(for: task) }
        }
    }

    /// Back to the Harbor overview (the Focus toolbar ◱ button / `backToHarbor`).
    func backToHarbor() { nav.backToHarbor() }

    /// A SetupModel wired to this runtime's services. Fresh each time the
    /// sheet opens so checks re-run cleanly.
    func makeSetupModel() -> SetupModel {
        SetupModel(git: git, loginShell: loginShell)
    }

    func finishSetup() {
        model.markSetupCompleted()
        setupPresented = false
    }

    /// Help → Run Setup Checks (re-runnable any time).
    func openSetup() { setupPresented = true }

    /// LIGHTHOUSE_DEBUG_DIFFRENDER=1: renders the hostile fixture diff
    /// through the REAL pipeline (page builder → vendored assets → locked
    /// WKWebView) and logs the page's own DOM assertions — the offscreen
    /// web process runs without a visible window. Scripts/smoke-run.sh
    /// asserts the results (the escape proof no unit test can give).
    private var diffRenderKeepAlive: [AnyObject] = []
    private func runDiffRenderCheckIfRequested() {
        guard ProcessInfo.processInfo.environment["LIGHTHOUSE_DEBUG_DIFFRENDER"] == "1" else { return }
        do {
            let directory = try DiffWebViewFactory.makeRenderDirectory()
            let gate = LocalOnlyNavigationDelegate(allowedRoot: directory) { message in
                FileHandle.standardOutput.write(Data("DIFFRENDER result \(message)\n".utf8))
            }
            let webView = DiffWebViewFactory.makeWebView(
                renderDirectory: directory, navigationGate: gate)
            diffRenderKeepAlive = [webView, gate]
            let page = DiffPageBuilder.page(
                diff: DiffPageBuilder.hostileFixtureDiff, debugChecks: true)
            try DiffWebViewFactory.load(page: page, into: webView, renderDirectory: directory)
            FileHandle.standardOutput.write(Data("DIFFRENDER-STAGE loaded\n".utf8))
        } catch {
            FileHandle.standardOutput.write(Data("DIFFRENDER-STAGE failed \(error)\n".utf8))
        }
    }

    /// LIGHTHOUSE_DEBUG_FILERENDER=1: renders the hostile FILE fixture through
    /// the REAL content-viewer pipeline (FilePageBuilder → locked WKWebView) and
    /// logs the page's own DOM assertions. Repo file content is untrusted input
    /// rendered into HTML (spec §8); this is the escape proof for the file
    /// viewer that no unit test can give. Mirrors the DIFFRENDER check for the
    /// diff path — both must stay green.
    private var fileRenderKeepAlive: [AnyObject] = []
    private func runFileRenderCheckIfRequested() {
        guard ProcessInfo.processInfo.environment["LIGHTHOUSE_DEBUG_FILERENDER"] == "1" else { return }
        do {
            let directory = try DiffWebViewFactory.makeRenderDirectory()
            let gate = LocalOnlyNavigationDelegate(allowedRoot: directory) { message in
                FileHandle.standardOutput.write(Data("FILERENDER result \(message)\n".utf8))
            }
            let webView = DiffWebViewFactory.makeWebView(
                renderDirectory: directory, navigationGate: gate)
            fileRenderKeepAlive = [webView, gate]
            let page = FilePageBuilder.page(
                content: FilePageBuilder.hostileContent, filename: "evil.txt", debugChecks: true)
            try DiffWebViewFactory.load(page: page, into: webView, renderDirectory: directory)
            FileHandle.standardOutput.write(Data("FILERENDER-STAGE loaded\n".utf8))
        } catch {
            FileHandle.standardOutput.write(Data("FILERENDER-STAGE failed \(error)\n".utf8))
        }
    }

    /// LIGHTHOUSE_DEBUG_NAVIGATOR=<repo path>: drives the real WorkbenchModel
    /// over a fixture repo (created outside on branch "task", base "main") and
    /// logs every navigator + center-stage assertion for Scripts/smoke-run.sh:
    /// the three surfaces populate (changes/files/history counts), mode
    /// switching works, the center stage defaults to the terminal, a selection
    /// swaps it to the viewer, a toggle returns it to the terminal, and the
    /// terminal controller is the SAME running instance across the swap (never
    /// recreated). A live /bin/cat pty backs the terminal so that last check is
    /// real, not asserted against nothing.
    private var navigatorKeepAlive: WorkbenchModel?
    private func runNavigatorCheckIfRequested() {
        guard let repoPath = ProcessInfo.processInfo.environment["LIGHTHOUSE_DEBUG_NAVIGATOR"],
              !repoPath.isEmpty else { return }
        Task { @MainActor in
            func log(_ m: String) {
                FileHandle.standardOutput.write(Data("NAVIGATOR-STAGE \(m)\n".utf8))
            }
            func mode(_ b: FocusBody) -> String { b.rawValue }
            let repo = RepoConfig(path: repoPath, baseBranch: "main")
            let task = TaskRecord(
                name: "navigator-probe", branch: "task", adapterKind: "debug",
                sessionRef: nil,
                workspaces: [Workspace(repoId: repo.id, worktreePath: repoPath, mergeState: .unmerged)])
            // A live terminal so "still running after the swap" is a real check.
            let plan = LaunchPlan(
                executable: "/bin/cat", arguments: [], environment: [:],
                workingDirectory: FileManager.default.temporaryDirectory,
                sessionRef: "navigator-probe")
            registry.open(taskId: task.id, tabId: TabID.agent, plan: plan) { _, _ in }
            let workbench = WorkbenchModel(task: task, repos: [repo], git: git)
            navigatorKeepAlive = workbench
            workbench.start()

            await workbench.review.awaitRefresh()
            log("changes=\(workbench.review.changedFileCount)")
            await workbench.loadFiles()
            log("files=\(workbench.files.count)")
            await workbench.loadHistory()
            log("history=\(workbench.commits.count)")

            // Mode switching.
            log("mode=\(workbench.navigatorMode.rawValue)")
            workbench.navigatorMode = .files
            log("mode=\(workbench.navigatorMode.rawValue)")
            workbench.navigatorMode = .history
            log("mode=\(workbench.navigatorMode.rawValue)")

            // Center-body default + swap + terminal survival.
            log("center-default=\(mode(workbench.effectiveBody))")
            let before = registry.controller(taskId: task.id, tabId: TabID.agent)
            let beforeId = before.map(ObjectIdentifier.init)
            let beforeRunning = before?.isRunning ?? false
            if let changed = Self.firstFilePath(in: workbench.review.tree) {
                await workbench.selectChangedFile(changed)
            }
            log("center-after-select=\(mode(workbench.effectiveBody))")
            log("viewer-has-content=\(workbench.viewer.hasContent)")
            workbench.showTerminal() // ⌘J: close the viewer, back to the mode
            log("center-after-toggle=\(mode(workbench.effectiveBody))")
            let after = registry.controller(taskId: task.id, tabId: TabID.agent)
            let afterId = after.map(ObjectIdentifier.init)
            let alive = beforeId != nil && beforeId == afterId
                && beforeRunning && (after?.isRunning ?? false)
            log("terminal-alive=\(alive)")

            // File + commit selections render pages through the center viewer.
            if let browseFile = Self.firstFilePath(in: workbench.files) {
                await workbench.selectFile(browseFile)
                log("file-page=\(workbench.viewer.hasContent)")
            }
            if let commit = workbench.commits.first {
                await workbench.selectCommit(commit)
                log("commit-page=\(workbench.viewer.hasContent)")
            }
            log("done")
        }
    }

    /// First file (depth-first) in a navigator tree, or nil if none.
    private static func firstFilePath(in nodes: [FileTreeNode]) -> String? {
        for node in nodes {
            if node.isFile { return node.id }
            if let children = node.children, let found = firstFilePath(in: children) { return found }
        }
        return nil
    }

    /// LIGHTHOUSE_DEBUG_GEOMETRY=1: select an ephemeral probe task running a
    /// harmless /bin/cat pty so the terminal pane renders without any agent,
    /// then resize the window once so the geometry check observes two sizes.
    /// The probe never persists and never marks the session "working", so
    /// quit stays unconfirmed and the user's config is untouched.
    private func setUpGeometryProbeIfRequested() {
        guard GeometryDebug.enabled else { return }
        // LIGHTHOUSE_DEBUG_REVIEWPANE=<repo path> gives the probe task a real
        // workspace (an outside-created fixture repo on branch "task",
        // base "main") so the review pane renders populated in the gate.
        var workspaces: [Workspace] = []
        if let repoPath = ProcessInfo.processInfo.environment["LIGHTHOUSE_DEBUG_REVIEWPANE"] {
            let repo = RepoConfig(path: repoPath, baseBranch: "main")
            model.insertEphemeralRepo(repo)
            workspaces = [Workspace(
                repoId: repo.id, worktreePath: repoPath, mergeState: .unmerged)]
        }
        let probe = TaskRecord(
            name: "geometry-probe", branch: "debug/geometry-probe",
            adapterKind: "debug", sessionRef: nil, workspaces: workspaces)
        model.insertEphemeralTask(probe)
        let plan = LaunchPlan(
            executable: "/bin/cat", arguments: [], environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory,
            sessionRef: "geometry-probe")
        registry.open(taskId: probe.id, tabId: TabID.agent, plan: plan) { _, _ in }
        tabs[probe.id] = [TerminalTab(id: TabID.agent, title: "Agent", isAgent: true)]
        focusedTab[probe.id] = TabID.agent
        selectedTaskId = probe.id
        // The two-mode shell defaults to Harbor; force Focus so the terminal
        // pane renders for the geometry/layout assertions.
        nav.open()
        // The scripted resize is event-driven from the first real layout
        // pass (GeometryResizeDriver) — a wall-clock timer here raced window
        // creation in other launch contexts and silently no-opped.
    }

    /// Recomputes the deterministic diff counts for a task by summing
    /// `git diff --numstat --merge-base <base>` across its worktrees (each vs
    /// its repo's base). A per-worktree failure leaves that worktree out rather
    /// than fabricating a number; if EVERY worktree fails the stat is marked
    /// unknown (nil → blank), distinct from a real all-zero reading.
    func refreshDiffDigest(for task: TaskRecord) async {
        var total: DiffStat?
        for workspace in task.workspaces {
            guard let repo = model.repos.first(where: { $0.id == workspace.repoId }) else { continue }
            // The CHANGES card must use the SAME base the review pane shows — the
            // per-task override if set, else the repo default — not the repo
            // default unconditionally (2026-08-03: the card was ignoring the
            // chosen base and disagreeing with the "Compare vs" branch).
            let base = workspace.baseOverride ?? repo.baseBranch
            guard let stat = try? await git.diffStat(
                worktree: workspace.worktreeURL, base: base) else { continue }
            total = (total ?? .zero).adding(stat)
        }
        digests.setDiffStat(taskId: task.id, total)
    }

    // MARK: - Terminal tabs (UI-only, not persisted; die with the app)

    /// Ordered terminal tabs per task; the first is always the agent tab.
    var tabs: [UUID: [TerminalTab]] = [:]
    /// Focused tab per task.
    var focusedTab: [UUID: UUID] = [:]

    private func loginShellURL(for task: TaskRecord) -> URL? {
        guard let workspace = task.workspaces.first else { return nil }
        return workspace.worktreeURL
    }

    // MARK: - Task + session flows

    /// `inPlace == false` (default) creates a worktree + branch per repo;
    /// `inPlace == true` runs the session in each repo's own checkout, with no
    /// worktree or branch, for investigation. `branch` is ignored when in-place.
    func createTaskAndStartSession(
        name: String, branch: String, repoIds: [UUID], inPlace: Bool = false
    ) async {
        do {
            let (task, plan) = inPlace
                ? try await model.createInPlaceTask(name: name, repoIds: repoIds)
                : try await model.createTask(name: name, branch: branch, repoIds: repoIds)
            startAgentSession(taskId: task.id, plan: plan)
            selectedTaskId = task.id
        } catch let failure as TaskCreationFailure {
            lastError = FailureDescriber.describe(failure)
        } catch let error as TaskEngineError {
            lastError = FailureDescriber.describe(error)
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Creates a task from a GitHub PR (`reference` = number or URL) in `repoId`
    /// and starts its session. `name` empty → the PR title.
    func createTaskFromPRAndStartSession(
        reference: String, repoId: UUID, name: String
    ) async {
        do {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let (task, plan) = try await model.createTaskFromPR(
                reference: reference, repoId: repoId,
                name: trimmedName.isEmpty ? nil : trimmedName)
            startAgentSession(taskId: task.id, plan: plan)
            selectedTaskId = task.id
        } catch let error as PullRequestCheckoutError {
            lastError = Self.describePRCheckout(error)
        } catch let error as TaskEngineError {
            lastError = FailureDescriber.describe(error)
        } catch {
            lastError = String(describing: error)
        }
    }

    private static func describePRCheckout(_ error: PullRequestCheckoutError) -> String {
        switch error {
        case .ghNotAvailable:
            return "The GitHub CLI (gh) was not found. Install it and run `gh auth login` to create tasks from PRs."
        case .invalidReference(let ref):
            return "'\(ref)' is not a PR number or URL."
        case .resolveFailed(let stderr):
            return "Could not find that PR (is it in the selected repo, and are you signed in?):\n\(stderr)"
        case .checkoutFailed(let stderr):
            return "PR checkout failed:\n\(stderr)"
        case .launchFailed(let reason):
            return "Could not launch gh: \(reason)"
        }
    }

    /// Resume `claude --resume <id>`. If the agent shell is still alive (Claude
    /// exited to the prompt), the command is TYPED into it; otherwise a fresh
    /// agent shell tab is opened and the command typed there. A dead/unknown
    /// id fails visibly inside the terminal ("No conversation found…") — the
    /// shell survives, so the user is not trapped.
    func resumeSession(for task: TaskRecord) {
        do {
            guard let plan = try model.resumePlan(for: task) else {
                lastError = "\(task.name) has no stored session to resume."
                return
            }
            if let controller = registry.agentController(taskId: task.id), controller.isRunning,
               let command = plan.typedCommand {
                registry.runCommand(taskId: task.id, tabId: TabID.agent, command: command)
                model.noteSessionStarted(taskId: task.id)
            } else {
                startAgentSession(taskId: task.id, plan: plan) // calls noteSessionStarted
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Preferences → terminal font size: persist it AND re-font every live
    /// terminal immediately (the model clamps to its allowed range).
    func setTerminalFontSize(_ size: Double) {
        model.setTerminalFontSize(size)
        registry.applyFontSize(CGFloat(model.terminalFontSize))
    }

    private func startAgentSession(taskId: UUID, plan: LaunchPlan) {
        registry.open(taskId: taskId, tabId: TabID.agent, plan: plan) { [weak self] key, _ in
            // The agent SHELL exited (user typed `exit`) — the tab is gone.
            // Not the agent-end signal (that is the SessionEnd hook); this
            // keeps liveSessions accurate and removes the tab.
            self?.handleTerminalExit(key)
        }
        tabs[taskId, default: []].removeAll { $0.id == TabID.agent }
        tabs[taskId, default: []].insert(TerminalTab(id: TabID.agent, title: "Agent", isAgent: true), at: 0)
        focusedTab[taskId] = TabID.agent
        model.noteSessionStarted(taskId: taskId)
    }

    /// Cmd+T: a plain persistent login shell in the task's primary worktree —
    /// no hooks, no session, no attention effect; dies with the app.
    func openShellTab(for task: TaskRecord) {
        guard let cwd = loginShellURL(for: task) else { return }
        let tabId = UUID()
        let plan = LaunchPlan(
            executable: loginShell, arguments: ["-l", "-i"], environment: [:],
            workingDirectory: cwd, sessionRef: "", typedCommand: nil)
        registry.open(taskId: task.id, tabId: tabId, plan: plan) { [weak self] key, _ in
            self?.handleTerminalExit(key)
        }
        let existing = tabs[task.id]?.filter { !$0.isAgent }.count ?? 0
        tabs[task.id, default: []].append(
            TerminalTab(id: tabId, title: "shell \(existing + 1)", isAgent: false))
        focusedTab[task.id] = tabId
    }

    // MARK: - Scratch terminal (repo-less)

    /// Prompts for a directory (default $HOME) and opens a plain scratch
    /// terminal there — see `openScratchTerminal`. Shared by the Harbor button
    /// and the ⌘⌥T menu command so the picker lives in one place.
    func promptAndOpenScratchTerminal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Open Terminal"
        panel.message = "Choose a directory for the scratch terminal"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openScratchTerminal(directory: url)
    }

    /// Opens a repo-less scratch terminal: a plain login shell at `directory`,
    /// no agent, no hooks, no review pane (the task has no workspaces). The task
    /// is ephemeral — it vanishes when its shell exits, when closed, or on quit.
    func openScratchTerminal(directory: URL) {
        let task = model.createScratchTask(directory: directory)
        open(task.id)
        let tabId = UUID()
        let plan = LaunchPlan(
            executable: loginShell, arguments: ["-l", "-i"], environment: [:],
            workingDirectory: directory, sessionRef: "", typedCommand: nil)
        registry.open(taskId: task.id, tabId: tabId, plan: plan) { [weak self] key, _ in
            self?.handleTerminalExit(key)
        }
        tabs[task.id] = [TerminalTab(id: tabId, title: "shell", isAgent: false)]
        focusedTab[task.id] = tabId
    }

    /// Closes a scratch terminal task: tears down its terminals and drops the
    /// ephemeral task. No engine / worktree cleanup — it owns nothing on disk.
    func closeScratchTask(_ task: TaskRecord) {
        let wasViewing = selectedTaskId == task.id
        registry.discardTask(taskId: task.id)
        tabs[task.id] = nil
        focusedTab[task.id] = nil
        digests.remove(taskId: task.id)
        if wasViewing { selectedTaskId = nil }
        model.removeScratchTask(task.id)
        if wasViewing { backToHarbor() }
    }

    /// Cmd+W: close the focused non-agent tab (the agent tab is closed only
    /// via task removal / explicit confirmation elsewhere).
    func closeFocusedTab(for taskId: UUID) {
        guard let focused = focusedTab[taskId], focused != TabID.agent else { return }
        closeTab(taskId: taskId, tabId: focused)
    }

    func closeTab(taskId: UUID, tabId: UUID) {
        registry.closeTab(taskId: taskId, tabId: tabId)
        tabs[taskId]?.removeAll { $0.id == tabId }
        if focusedTab[taskId] == tabId {
            focusedTab[taskId] = tabs[taskId]?.first?.id
        }
    }

    private func handleTerminalExit(_ key: TabKey) {
        if key.tabId == TabID.agent {
            model.noteSessionEnded(taskId: key.taskId)
        }
        tabs[key.taskId]?.removeAll { $0.id == key.tabId }
        if focusedTab[key.taskId] == key.tabId {
            focusedTab[key.taskId] = tabs[key.taskId]?.first?.id
        }
        // A scratch terminal IS its shell: when that shell exits and no tabs
        // remain, the repo-less task has nothing left, so retire it entirely.
        if let task = model.tasks.first(where: { $0.id == key.taskId }),
           task.workspaces.isEmpty, (tabs[key.taskId] ?? []).isEmpty {
            closeScratchTask(task)
        }
    }

    func removeTask(_ task: TaskRecord, mode: TaskRemovalMode) async -> Bool {
        do {
            // Engine removal FIRST: it can refuse (a dirty/unmerged worktree
            // with no matching confirmation) and throw. Only once the engine
            // has committed to removal do we tear down the local session/tabs/
            // digests — a failed removal must leave the task fully intact
            // (session alive, still listed) so the user can retry or cancel.
            _ = try await model.removeTask(task, mode: mode)
            registry.discardTask(taskId: task.id)
            tabs[task.id] = nil
            focusedTab[task.id] = nil
            digests.remove(taskId: task.id)
            if selectedTaskId == task.id { selectedTaskId = nil }
            return true
        } catch let error as TaskEngineError {
            lastError = FailureDescriber.describe(error)
            return false
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    /// Called on the way out (applicationWillTerminate): tear down the wheel
    /// monitor. Ptys die with the app; conversation context survives via
    /// --resume.
    func shutdown() {
        wheelMonitor.stop()
    }
}
