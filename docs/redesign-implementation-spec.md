# Lighthouse UI Redesign — Implementation Spec

How to build the `design_handoff_lighthouse_ui` redesign natively in the existing
Swift/SwiftUI app. The handoff (`design_handoff_lighthouse_ui/README.md` +
`Lighthouse.dc.html`) is the **visual source of truth** for look, spacing, tokens,
and interactions; this document is the **engineering plan** — what we reuse, what
we build, in what order, and the one genuinely hard problem.

Status: draft for review. Nothing built yet. Current app tip: `2861765` (workbench).

---

## 1. The reframe in one paragraph

Today the app is "VSCode with a terminal in the middle": a persistent
`NavigationSplitView` — Tasks/Repos sidebar on the left, and per task a
`HSplitView` of center-stage (terminal ⇄ viewer) and a Changes/Files/History
navigator. The redesign keeps **all of that machinery** but reframes the shell
into an **agent command deck** with two top-level views:

- **Harbor** — a fleet overview ("who needs me") of task cards + repos. New.
- **Focus** — one task with the terminal as the full-bleed hero; task navigation
  demoted to a 60px "beacon rail", and the navigator + file viewer become
  on-demand overlays rather than a permanent split pane. A reorganisation of
  today's `TaskDetailView`.

Plus three cross-cutting new systems: a **runtime theme** (Beacon dark / Native
light), a **custom titlebar**, and a **Summary** digest per task. The handoff
calls itself "UI/UX only" — that is true for ~85% of it; the exception is the
per-task metadata the cards and Summary display, which needs a new (read-only)
data layer. That is section 4 and the crux of the effort.

---

## 2. What we reuse vs. build

| Redesign element | Backed by (reuse) | New work |
|---|---|---|
| Focus terminal pane | `CenterStageView.terminalStage`, SwiftTerm, `SessionRegistry` (retained NSView) | reparent into the new center column; keep alive across Harbor↔Focus |
| File viewer (center overlay) | `ContentViewerModel` + `DiffPageBuilder`/`FilePageBuilder` (WKWebView) | restyle; make it an overlay that wins over terminal/summary |
| Navigator (Changes/Files/History) | `NavigatorView`, `WorkbenchModel` surfaces, `GitClient.commitLog/listFiles/fileContents`, `LiveDiffService` | convert from HSplit pane → 340px slide-in overlay; restyle |
| Task/repo lists, status | `AppModel.tasks/repos`, `attentionState` (working/needsInput/done/dirty) | Harbor cards/rows; status→accent mapping |
| ⌘K palette | `SwitcherOverlay`, `FuzzyMatcher`, `InboxOrder` | restyle to the palette panel; already sorts needs-first |
| New task / register repo / setup | `Sheets.swift`, `SetupView`, `AppModel.createTask/registerRepo` | reach from Harbor "New task" + menu |
| Merge to base | `MergeWalkController`, `ConflictPaneView` | wire the promoted button; conflict flow unchanged |
| Attention → status signal | `AttentionSocketListener`, hooks, `AttentionStateMachine` | surface extra hook payload fields (section 4) |
| **Theme tokens** | — | **new** `Theme` system (section 3.1) |
| **Custom titlebar** | — | **new** (section 3.3) |
| **Two-mode nav shell** | `AppRuntime` (partial: `selectedTaskId`, `switcherPresented`) | **new** navigation state (section 3.4) |
| **Harbor view** | — | **new** (section 5.1) |
| **Summary digest** | — | **new** UI + data (sections 4, 5.3) |
| **Per-task metadata** (model, ctx%, add/del, action, baked, steps, next) | `transcript_path` from hooks, `git diff --numstat` | **new data layer** (section 4) |
| Animations (pulse/beam/blink/slide/pop/fadeup) | — | **new**, Core Animation + reduce-motion |
| Preferences (theme / start view / beam) | `ConfigStore` (schema bump) | **new** |

**Status mapping (clean, no new state machine):**
`working → working`, `needsInput → needs`, `done → idle`, `dirty → stale`.
The four redesign statuses are exactly today's four attention states.

---

## 3. Foundation systems (build first — everything else sits on these)

### 3.1 Theme / design tokens

The whole redesign is token-driven; this is the keystone.

- A value type `Theme` exposing every token from the handoff's table as
  `Color`/`Font`/metrics: `bg, chrome, panel, panel2, panel3, elev, border,
  border2, borderSoft, text, dim, faint, faint2, termbg, primary, primaryText,
  sb`, the four **status accents**, and the diff/semantic colors.
- Two concrete instances: `.beacon` (custom hex, dark) and `.native` (light).
  Per the handoff's "Native mapping tip", Native binds to **NSColor semantic
  colors** where specified (`windowBackgroundColor`, `controlAccentColor`,
  `labelColor`, `separatorColor`, …) so accent + accessibility settings are
  respected; the hex values are the fallback. Beacon uses the literal hex.
- Delivery: `@Observable ThemeController` (holds current `LighthouseTheme` enum)
  on `AppRuntime`; the resolved `Theme` injected via `.environment(\.theme)`.
  Flipping the enum re-resolves colors app-wide (SwiftUI observation handles the
  invalidation). Persist the choice in config (schema bump, §7).
- **`termbg` and the viewer stay dark in both themes** (handoff rule). The
  WKWebView pages already control their own colors — the page builders get a
  `dark` styling regardless of app theme; only chrome around them themes.

Why a struct-of-tokens over an Asset Catalog: the Beacon palette is a *custom*
dark that is not the system dark appearance, so `.darkAqua` is wrong; and runtime
switching independent of system appearance is required. A `Theme` struct is the
least-magic way to get both. (Asset-catalog color sets remain an option for the
Native half if we want free light/dark auto-resolution, but mixing the two is
more confusing than one code path.)

### 3.2 Typography

**Decided: SF Pro (UI) + SF Mono (mono)** — stock, zero supply-chain surface,
respects accessibility. The handoff sanctions this substitute for its Space
Grotesk / JetBrains Mono. A `LHFont` helper centralises the scale
(23/20/15/14.5/13/12.5/11/10.5) and weights; swapping to the branded families
later is a one-line change behind that helper.

### 3.3 Custom titlebar (38px, persistent)

- Transparent titlebar (`window.titlebarAppearsTransparent = true`,
  `titleVisibility = .hidden`, full-size content view) with the **real traffic
  lights** left as-is.
- Centered, non-interactive beacon dot + "Lighthouse" wordmark — via an
  `NSTitlebarAccessoryViewController` (or a top overlay strip in SwiftUI aligned
  to the 38px band). The beacon amber is identical in both themes (brand).
- Right side: the **theme switcher** segmented control + account string, as a
  trailing titlebar accessory.
- Scar risk: traffic-light layout + accessory positioning is fiddly; a small
  AppKit `NSHostingView` accessory is more reliable than trying to fake the band
  purely in SwiftUI. Gate it (§8).

### 3.4 Two-mode navigation shell

New UI state (extend `AppRuntime`, or a dedicated `@Observable NavigationModel`):

```
view: .harbor | .focus          selectedId: UUID?        (exists as selectedTaskId)
navOpen: Bool                    navTab: .changes|.files|.history  (exists on WorkbenchModel)
termMode: .terminal | .summary   viewerId: String?        (selected file path; viewer wins)
filter: .all|.needs|.working|.idle|.stale                  cmdkOpen: Bool  (≈ switcherPresented)
theme: .beacon|.native           startView / showBeam (prefs)
```

Interaction rules (verified against the prototype's `support.js`; these are exact
and worth honouring):

- `open(id)` → `view=.focus, selectedId=id, cmdkOpen=false, viewerId=nil`.
- `backToHarbor` → `view=.harbor, viewerId=nil`; **keeps** `termMode/navTab/navOpen`.
- `setTerminal`/`setSummary` → both **clear** `viewerId` (mode switch exits viewer).
- selecting a file → sets `viewerId`, does **not** change `termMode` (closing the
  viewer returns to whichever mode was active).
- **viewer precedence:** when `viewerId != nil` the file viewer is shown over both
  terminal and summary.
- ⌘K toggles palette (any view); ⌘J closes the viewer **only in Focus**; ⌘\
  toggles `navOpen`; Esc closes the palette only.
- ⌘K list is **not** filtered by the Harbor `filter` chip (always full list);
  both Harbor grid and ⌘K use the fixed sort `needs→working→idle→stale`.

The terminal NSView must survive `view` flips (Harbor↔Focus) as well as mode
swaps — keep it mounted/retained in the `SessionRegistry` and only reparent,
exactly as the tab ZStack does today. Do **not** tie its lifetime to the Focus
view's appearance.

---

## 4. The data layer — per-task metadata & Summary (the hard part)

The cards, the Focus footer, and the Summary all show data the app does **not**
currently compute. Feasibility verified against `docs/claude-code-contract.md`:

| Field | Source | Confidence |
|---|---|---|
| `status` | `attentionState` | ✅ have it |
| `files` count | `LiveDiffService` (`changedFileCount`) | ✅ have it |
| `add` / `del` | **new** `GitClient.diffStat` → `git diff --numstat --merge-base <base> --`, summed | ✅ straightforward |
| `time` (relative) | `attentionSince` + `CommitDateFormatter.relativeString` | ✅ have it |
| `action` (last message) | `Stop` hook `last_assistant_message` (in the payload today, currently ignored) | ✅ available — must surface it |
| `model` | transcript JSONL (and `SessionStart.model`, not currently installed) | ✅ from transcript |
| `steps[]`, `summaryHead`, `next` | **transcript JSONL** parse: tool-call log → steps; final recap → head/next | ⚠️ derivable, best-effort (stochastic text) |
| `baked` (turn duration) | timestamps between `UserPromptSubmit` and `Stop` | ✅ compute from hook timing |
| `account` | active `CLAUDE_CONFIG_DIR` / Claude config | ⚠️ needs verification of exact source |
| `ctx%` | **no hook field, no documented transcript field** | ❌ needs verification; may be estimable from transcript token counts, else omit |

**The enabler:** every hook payload carries `transcript_path` — the session's
JSONL at `~/.claude[-enterprise]/projects/…/<session-id>.jsonl`. Because we
pre-assign the session id, we know this path already. A **read-only transcript
reader** yields model, tool-call log (steps), and assistant messages (action /
recap). This is a new capability but well-founded and low-risk (parse a file we
own).

**Design principles for this layer (deterministic/stochastic bright line):**
- `add/del/files/status/time/baked` are **deterministic** — git + timing, must be
  correct.
- `action/steps/summaryHead/next` are a **best-effort projection** of stochastic
  model output. The Summary is explicitly a "derived projection of terminal
  state, refreshed when the agent yields" (handoff). It must **degrade
  gracefully** (missing recap → show the tool-call steps + last message; never
  fabricate) and must never be treated as authoritative. All transcript text is
  untrusted content → it renders through the same escaped WKWebView channel the
  file/diff viewers use, or as SwiftUI `Text` (which does not interpret markup).
- **`ctx%` must not be invented.** Options, in order of preference: (a) verify the
  transcript records cumulative token usage and compute an honest estimate,
  clearly framed; (b) omit the context meter until a real source exists. We will
  **verify (a) before building the meter**; if unavailable, ship without it
  rather than show a fabricated number.

**Shape:** a `TaskDigest` value per task (`@Observable` cache keyed by task id),
refreshed on: `Stop`/attention transitions (via the socket listener), the live
diff watcher firing (add/del/files), and Focus entry. Harbor reads the cache;
absent fields render as graceful blanks. This layer is deliberately **deferred to
its own phase** (§6 Phase 4) so the visual shell can land first with the data we
already have.

---

## 5. View build-out

### 5.1 Harbor (new)

Vertical stack inside the window content: header row (title + subtitle
`"{N} tasks across {M} repos · {K} need you"` + ⌘K search button + New task) →
filter chips (All/Needs you/Working/Idle/Unaccounted, status-dot + count,
active = tinted) → scroll region (task-card grid `minmax(330,1fr)` sorted
needs→working→idle→stale, then the REPOS grid).

- **Task card**: `--panel` bg, 3px left border in status accent, needs-you cards
  get the amber glow shadow; head row (status dot · title/meta · status pill),
  action line (2-line clamp), footer (model chip · +add/−del · files · time).
  `fadeup` entry, hover lift.
- **Repo row**: avatar (initial) · name/path · branch + task count.
- Cards/chips are SwiftUI `List`/`LazyVGrid`. Data from `AppModel` + `TaskDigest`
  cache (graceful blanks pre-Phase-4). Filter + sort are pure functions
  (unit-testable; reuse `InboxOrder`'s ordering).

### 5.2 Focus (reshape of `TaskDetailView`)

Horizontal: **beacon rail (60px)** · **center column (flex)** · **navigator
overlay (340px, toggle)**.

- **Beacon rail**: Harbor button (◱ / `square.grid.2x2`) · divider · scroll of
  task dots (40px each, selected highlighted, status dot inside, tooltip = title)
  · New-task (+). Replaces the old sidebar's task list.
- **Center column** (vertical): task header (status · title/meta · spacer ·
  Terminal/Summary segmented · context meter · navigator-toggle ◨ · Merge to
  base) → shell-tabs bar (Agent + zsh + `+`, ⌘T — reuse `TerminalTabBar`) → body
  (exactly one of Terminal / Summary / File viewer per §3.4 precedence) → footer
  status line (account · repo · model · ctx · accept-edits · N agents).
- **Terminal** body = today's `terminalStage` (SwiftTerm, retained NSView).
- **File viewer** body = today's `ContentViewerModel` viewer, restyled with the
  handoff header (status badge · path · +add/−del · read-only · ⌘J Terminal).
- Merge button promoted (green) only when status == idle; wires
  `startMergeWalk`; conflict flow unchanged (`ConflictPaneView` still overrides).

### 5.3 Summary (new)

Center pane, `--bg`, max-width 720 centered: status + "baked for {baked}" →
`summaryHead` → two stat cards (Changes: +add/−del, files; Context: ctx%, model ·
1M) → "What the agent did" (✓ per `steps[]`) → amber "Next step" callout (`next`
text + Open terminal / Review diff buttons). Pure presentation over `TaskDigest`;
buttons drive `setTerminal` / `toggleNav`. Ships in Phase 4 with its data.

### 5.4 ⌘K palette (restyle of `SwitcherOverlay`)

Scrim + blur (`NSVisualEffectView`), 620px panel, search field (autofocus, esc
keycap), "NEEDS YOU FIRST" section, task rows (dot · title/repo · pill) sorted
needs-first, click → `open(id)`. Logic already exists (`FuzzyMatcher`,
`InboxOrder`); this is a visual + behavior alignment (full list, ignores Harbor
filter).

---

## 6. Phased plan (each phase keeps the app runnable and is gated)

**Phase 1 — Theme foundation + titlebar.** `Theme` tokens (both themes),
`ThemeController` + environment injection, typography helper, custom titlebar
with centered wordmark + theme switcher, persisted theme (schema bump). Apply
tokens to the *existing* views so the switch is real and visible. No layout
reframe yet. *Gate:* THEME (both palettes resolve; switch flips app-wide;
terminal/viewer stay dark).

**Phase 2 — Two-mode shell + Harbor.** Navigation state (§3.4), Harbor view
(cards/repos/chips/search) over existing data with graceful-blank metadata, ⌘K
palette restyle, Harbor↔Focus switching (Focus = lightly-adapted current
`TaskDetailView` for now). Terminal survives the view flip. *Gate:* HARBOR (grid
renders, sort+filter correct, card→Focus, ⌘K→Focus, terminal-alive across flip).

**Phase 3 — Focus reshape.** Beacon rail, task header, footer status line,
navigator converted from HSplit pane → 340px slide-in overlay, file viewer as
center overlay with the new header. Retire the old `NavigationSplitView`
sidebar/`ContentView` split. *Gate:* update GEOMETRY/LAYOUT/NAVIGATOR; add FOCUS
(rail dots, header/footer present, nav overlay slides, viewer overlay wins,
terminal-alive across mode swap + nav toggle).

**Phase 4 — Metadata (lean-first) + Summary.** `GitClient.diffStat`; surface
`last_assistant_message` + `baked` timing from the listener; `TaskDigest` cache
with the **deterministic fields** (add/del/files, status, time, baked, model) +
the action line; wire cards + footer. **Verify ctx% source first**; build the
meter only if honest, else omit. The **rich transcript-derived Summary**
(steps/summaryHead/next) is deferred to **Phase 4b** once the shell is proven —
until then the Summary pane shows the deterministic stat cards + the action line,
degrading gracefully. *Gate:* DIGEST (deterministic fields exact on a fixture;
Summary degrades gracefully with no recap; hostile transcript text rendered
inert).

**Phase 5 — Motion + preferences + polish.** Pulse/beam/blink/slide/pop/fadeup
via Core Animation, all gated behind `accessibilityDisplayShouldReduceMotion`;
preferences (default theme, start view, ambient beam on/off). *Gate:* MOTION
(reduce-motion disables animations; beam honors the pref).

Each phase: failure-first unit tests for the pure logic (theme resolution,
filter/sort, digest math, state-transition rules), runtime gates for the
SwiftUI/geometry pieces (which are not headlessly testable — the established
scar), full `swift test` + `smoke-run.sh` 3×, rebuild + stamp, independent
verification by the main session, then a user-gated commit.

---

## 7. Config / persistence

Schema bump (v3 → v4) adding `theme`, `startView`, `showBeam`, with a v3→v4
migration defaulting them (`beacon` / `harbor` / `true`). `TaskDigest` is a
runtime cache, **not** persisted (it is re-derivable and partly stochastic).

---

## 8. Risks & scars to respect

- **SwiftUI layout scars (documented):** `HSplitView`/splits collapse to children'
  IDEAL height → force `maxWidth/maxHeight: .infinity`; `NSViewRepresentable`
  sizing is not headlessly testable → runtime GEOMETRY gates with two window
  sizes and the min-width clamp baseline; use `ZStack` not `Group` to avoid the
  onAppear re-fire loop.
- **Retained terminal NSView** must survive Harbor↔Focus, mode swaps, and nav
  toggles. Never rebuild it from view lifecycle. This is the highest-value
  invariant — every Focus gate asserts `terminal-alive`.
- **Custom titlebar + traffic lights**: fiddly; prefer AppKit accessory views;
  gate positioning.
- **WKWebView dark-in-both-themes**: the page builders own their colors; ensure
  they don't inherit app theme.
- **Transcript parsing is stochastic**: defensive, best-effort, graceful
  degradation, untrusted-content escaping. Never authoritative. `ctx%` never
  fabricated.
- **Scope**: this is a multi-week, whole-shell change on a freshly-shipped app.
  Incremental phasing (above) keeps it runnable and reviewable throughout;
  resist a big-bang rewrite.

---

## 9. Decisions

1. **Fonts — DECIDED: SF Pro / SF Mono** (stock; swappable to the branded
   families later behind `LHFont`). See §3.2.
2. **Summary/metadata depth — DECIDED: lean-first.** Deterministic fields +
   action line in Phase 4; rich transcript-derived Summary (steps/recap/next)
   deferred to Phase 4b. See §6.
3. **`ctx%` meter — verify source first, omit if not honest** (no fabricated
   number). To resolve at the start of Phase 4.
4. **Rollout — incremental, foundation-first** per §6.
