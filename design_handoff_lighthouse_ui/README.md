# Handoff: Lighthouse UI Redesign

## Overview
Lighthouse is a personal macOS home for day-to-day agentic development. Each **task** owns its own git worktree (branched from a registered repo) and its own Claude Code session, so several agents run in parallel. This handoff covers a redesign of the **entire app shell** — a reframing away from the "VSCode with a terminal in the middle" layout toward an **agent command deck** with two modes:

- **Harbor** — a fleet overview that answers *who needs me* across all running agents.
- **Focus** — a single task where the **terminal is the full-bleed hero**, with task navigation demoted to an ambient rail and the repo navigator/file viewer as on-demand overlays.

The design ships with **two themes** — **Beacon** (custom dark "night-watch") and **Native** (light macOS) — switchable at runtime, plus a lighthouse/beacon visual identity (amber = "needs you").

The existing app already has the functional plumbing (PTY, SwiftTerm, git client, worktrees, Claude Code session management). **This handoff is UI/UX only** — it describes how to build the presentation layer on top of that machinery.

---

## About the Design Files
The file in this bundle — `Lighthouse.dc.html` — is a **design reference created in HTML/JS**. It is an interactive prototype showing intended look, layout, and behavior. **It is not production code to copy.** The task is to **recreate these designs natively in the existing Swift/AppKit + SwiftUI app**, using the codebase's established patterns, wiring the visuals to the real PTY/git/session backend already in place.

Everything in the prototype maps to stock macOS controls; see **AppKit / SwiftUI Mapping** at the end. The only non-stock component (the terminal) is already solved in the app via SwiftTerm.

## Fidelity
**High-fidelity.** Final colors, typography, spacing, radii, and interactions are specified below with exact values for both themes. Recreate pixel-accurately, but prefer **system semantic colors** in Native mode (see Design Tokens) so the app respects the user's accent color and accessibility settings.

---

## Screens / Views

The app is a single window with a custom titlebar and two primary views (Harbor / Focus), plus a command palette overlay. The window content area is a vertical stack: **Titlebar (38px)** on top, then the active view fills the rest.

### 0. Titlebar (persistent, all views)
- **Height:** 38px. Background `--chrome`. Bottom border 1px `--borderSoft`.
- **Left:** standard macOS traffic lights (use the real window controls; do not draw them).
- **Center (absolutely centered, non-interactive):** a 13px beacon dot — radial gradient `#f0b45e → #b97a26`, glow `0 0 10px rgba(240,180,94,.6)` — followed by wordmark "Lighthouse" (12.5px / 600 / `--dim`). The beacon amber stays identical in **both** themes (brand identity).
- **Right:** a **theme switcher** segmented control (`Beacon` / `Native`, pill container `--panel2` bg + `--border2`, active segment `--panel3` bg + `--text`), then the account string in mono 11px `--faint2`.

### 1. Harbor (overview / home)
Purpose: see every agent at a glance and jump into whichever needs attention. Default landing view.

**Layout (top → bottom, all inside a vertical stack):**
1. **Header row** — padding `18px 30px 6px`. Left: title "Harbor" (23px / 700 / -.01em) + subtitle (12.5px `--dim`): `"{N} tasks across {M} repos · {K} need you"`. Right (pushed with spacer): a **search button** (min-width 280px, 38px tall, `--panel2` bg, `--border2` border, radius 10px) showing `⌕ Search tasks & repos…` and a `⌘K` keycap on the right; then the **New task** primary button.
2. **Filter chips row** — padding `14px 30px 16px`, 9px gap, wraps. Chips: `All`, `Needs you`, `Working`, `Idle`, `Unaccounted`, each with a status-colored 7px dot (except All) + count. Active chip = status-color tint bg + border + colored text; inactive = `--panel2` bg, `--border2` border, `--dim` text. 32px tall, radius 9px.
3. **Scroll region** — padding `0 30px 34px`, vertical scroll.
   - **Task grid:** CSS grid, `repeat(auto-fill, minmax(330px, 1fr))`, 16px gap. Sorted **needs → working → idle → stale**.
   - **Repos section:** uppercase label "REPOS" (13px / 600 / `--dim` / .04em), then a grid `minmax(340px,1fr)` of repo rows.

**Task card component:**
- Container: `--panel` bg, 1px `--border`, **3px left border in the status accent color**, radius 14px, padding `16px 17px 14px`. Shadow: needs-you cards get `0 0 26px -8px {accent}` glow + `0 1px 3px rgba(0,0,0,.22)`; others just `0 1px 3px rgba(0,0,0,.16)`. Hover: `translateY(-2px)`, border → `--border`. Entry animation `fadeup .4s`.
- **Head row (10px gap):** status dot (9px; see Status states) · title block (15px / 600 title, ellipsized; meta line mono 11px `--faint`: `repo · branchShort`) · status **pill** (right, 10.5px / 600, `{accent}22` bg, `{accent}55` border, `{accent}` text, radius 20px, padding `3px 9px`).
- **Action line:** margin-top 12px, 12.5px / 1.45, `--text` at 82% opacity, clamped to 2 lines, min-height 36px. This is the agent's last message / what it's waiting on.
- **Footer:** margin-top 13px, 12px top padding, 1px `--borderSoft` top border. Mono 11px. Left→right: model chip (6px blue `#3f6cd6` dot + model name) · `+{add}` green `#4fb07a` · `−{del}` red `#d46b64` · `{files} files` · (spacer) · relative time.

**Repo row component:**
- Flex row, 14px gap, `--panel2` bg, 1px `--borderSoft`, radius 12px, padding `14px 16px`.
- 38px rounded-square avatar (`--panel3` bg, `--border`, mono 15px `--primary` initial) · name (14px / 600) + path (mono 11px `--faint`, ellipsized) · right column: branch (mono 11px `--dim`) + `{count} tasks` (11.5px `--faint`).

### 2. Focus (single task, terminal hero)
Purpose: work in one task's terminal with everything else ambient. Entered by clicking a card or a ⌘K result.

**Layout:** horizontal — **Beacon rail (60px)** · **center column (flex)** · **navigator overlay (340px, toggleable)**.

**Beacon rail (60px, `--chrome` bg, right border `--borderSoft`):**
- Top: **Harbor button** (40px, radius 11px, `--panel3` bg, `◱` glyph) → back to overview. Hover text → `--primary`.
- Divider (24px × 1px `--border`).
- Scrollable column of **task dots** — one 40px button per task; selected has `--panel3` bg + `--border2`, others transparent; each contains the status dot; `title` tooltip = task title.
- Bottom: dashed **New task** button (`+`).

**Center column (vertical):**
1. **Task header (52px, `--chrome` bg, bottom `--borderSoft`):** status dot · title (14.5px / 600) + meta (mono 10.5px `--faint`: `repo · branchShort`) · **(spacer)** · **Terminal/Summary segmented toggle** (`--panel2` container) · **context meter** (74px track `--panel3`, fill gradient `#5ec8e0 → #4a9fd6`, width = ctx%, + `{ctx}%` mono label) · **navigator toggle button** (`◨`, 34px; open state = `--border2` bg + `--primary` icon) · **Merge to base** button (green gradient when task is idle/clean, else neutral `--panel3`).
2. **Shell-tabs bar (34px, `--chrome` bg):** an active "✦ Agent" tab (dark `--termbg` bg, rounded top, sits flush over the terminal like a terminal tab), a "zsh" tab, and a `+` (new shell tab, ⌘T). Represents multiple shells against the same worktree.
3. **Body (fills; `--bg` bg, position:relative):** shows exactly one of three panes:
   - **Terminal** (default): dark `--termbg`, mono 12.5px / 1.6, `#c8cfdd` base text. This is the live SwiftTerm view. Prototype shows representative Claude Code output (session header, `Update(path)` tool blocks with red/green diff lines, `● / ✳` status markers, "Baked for…", a `recap:` line, and a blinking amber block cursor at the prompt). **In the real app this is the PTY, not static markup.**
   - **Summary** (toggle): a **friendly digest** over `--bg`, max-width 720px centered, 16px gap. Contains: status label + "baked for" time; a headline (20px / 600); two stat cards (`--panel2`) for **Changes** (`+add −del`, files touched) and **Context** (`ctx%`, model · 1M window); a **"What the agent did"** card listing check-marked steps; and a **"Next step"** callout (amber-tinted, `color-mix(--primary 9%, --bg)` bg + `--primary 32%` border) with **Open terminal** (primary) and **Review diff** buttons. See "Summary data source" below.
   - **File viewer** (when a file is selected in the navigator): dark `--termbg`, animation `pop .18s`. Header (40px, `rgba(0,0,0,.28)`): status badge (A/M/D) · file path (mono 12px) · `+add` `−del` · "read-only" · **⌘J Terminal** button (closes viewer). Body: line-numbered diff, added lines `rgba(111,211,154,.10)` bg + green text, removed lines `rgba(224,115,109,.10)` bg + red text, syntax colors listed in tokens. Read-only.
4. **Footer status line (30px, `--chrome` bg, top `--borderSoft`):** mono 11px `--faint`. `● {account}` (amber dot) · `⌥ {repo}` · `{model} (1M context)` · `ctx: {ctx}% used` · (spacer) · green `▶▶ accept edits on` · `← {N} agents`.

**Navigator overlay (340px, `--chrome` bg, left `--borderSoft`, slide-in `.2s`):**
- **Header (52px):** "REPO" label + repo selector chip (`--panel2`) + mono `diff vs base` (blue `#4a9fd6`) + close `×`.
- **Tabs:** `Changes` / `Files` / `History` (equal-width segmented, active = `--elev` bg + `--border`).
- **Changes tab:** a folder header (`▾ src/features/settings`), then file rows. Each row: A/M/D status badge (green/amber/red `{col}33` bg) · filename (mono 12.5px, ellipsized) · `+add` `−del`. Selected row = `--elev` bg + `--border`. Clicking a row opens the **File viewer** in the center. Footer: `{files} files · +add −del`.
- **Files tab:** repo file browser (placeholder copy in prototype; wire to real tree). Clicking a file opens the viewer.
- **History tab:** commit list — mono sha (`--primary`) · message (12.5px, ellipsized) + `author · relative time`, rows divided by `--borderSoft`.

### 3. ⌘K Command Palette (overlay, any view)
- Full-screen scrim `rgba(6,8,13,.5)` + `backdrop-filter: blur(3px)`, content pinned 11vh from top.
- Panel: 620px (max 92vw), `--panel` bg, 1px `--border`, radius 16px, shadow `0 30px 80px rgba(0,0,0,.5)`, `pop .16s`.
- **Search field:** `⌕` icon + autofocus text input (15px) + `esc` keycap.
- **Results:** section label "NEEDS YOU FIRST", then task rows **sorted needs → working → idle → stale**: status dot · title (13.5px / 500) + repo (mono 10.5px `--faint`) · status pill. Hover row = `--elev`. Clicking opens that task in Focus. (Also serves as the "New task" entry point in the prototype.)

---

## Interactions & Behavior
- **Card / dot / palette-row click → Focus** on that task (`view=focus`, `selectedId`, clears any open file viewer, closes palette).
- **Harbor button (◱) → Harbor** (`view=harbor`, clears viewer).
- **Terminal ↔ Summary** toggle switches the center pane; both clear the file viewer.
- **Navigator toggle (◨) / ⌘\\** shows/hides the 340px overlay.
- **File row click → File viewer** replaces the center pane. **⌘J** (or the viewer's ⌘J button / close) returns to the terminal (viewer never destroys the running PTY — it's an overlay on top).
- **⌘K** toggles the command palette; **Esc** closes it. Clicking the scrim closes it; clicks inside the panel are stopped from propagating.
- **Theme switcher** flips all `--*` tokens at runtime (see Themes). Terminal/viewer stay dark in both themes.
- **Merge to base** is the primary action; it's visually promoted (green) only when the selected task's status is `idle` (clean/ready). In the real app this triggers the merge-with-conflict-resolution flow.
- **Filter chips** filter the Harbor grid by status.
- **Attention sort** (needs → working → idle → stale) is applied in both the Harbor grid and the ⌘K list.

**Animations (Core Animation equivalents):**
- Working status dot: **pulse** — expanding box-shadow ring in the accent color, 1.6s infinite.
- Ambient **beam** (Harbor bg, optional/toggleable): a conic-gradient wedge in `--primary` rotating 360° over 26s + a soft radial glow, top-left. Purely decorative; keep subtle. Honor "reduce motion".
- Cursor **blink**: amber block, 1.1s step.
- **slidein** (navigator, .2s), **pop** (palette + viewer, .16–.18s), **fadeup** (cards, .4s).

## State Management
Runtime UI state (the rest comes from the backend):
- `view`: `harbor | focus`
- `selectedId`: current task id
- `navOpen`: bool (navigator overlay)
- `navTab`: `changes | files | history`
- `termMode`: `terminal | summary`
- `viewerId`: selected file path or nil (when set, center shows viewer)
- `filter`: `all | needs | working | idle | stale` (Harbor)
- `cmdkOpen`: bool
- `theme`: `beacon | native`

**Backend-derived data per task:** `title`, `repo`, `branch`, `status` (working/needs/idle/stale), `model`, `ctx%`, diff `add`/`del`/`files`, relative `time`, `account`, last `action` line, and the Summary fields (`summaryHead`, `steps[]`, `next`, `baked`).

### Task status → visual (the core signal)
| status | meaning | dot behavior |
|---|---|---|
| `working` | agent running | pulsing dot, accent = working color |
| `needs` | needs your input | steady dot + glow, accent = beacon amber, card gets amber glow shadow, sorts first |
| `idle` | done / clean | steady dot, green; Merge button promoted |
| `stale` | session ended / unaccounted changes | steady dot, muted yellow |

### Summary data source (the extraction question)
The Summary digest is derived from **Claude Code's own end-of-turn output** (its recap/summary text and tool-call log) plus **git diff --stat** against the worktree base. Suggested mapping: `steps[]` ← the tool-call / action log for the current turn; `summaryHead` + `next` ← the model's recap line; `add/del/files` ← git diff stat; `ctx%` ← the session's reported context usage; `baked` ← turn duration. Treat Summary as a derived projection of terminal state, refreshed when the agent yields.

---

## Design Tokens

### Chrome tokens (drive everything; swap per theme)
| token | Beacon (dark) | Native (light) | role |
|---|---|---|---|
| `--bg` | `#0a0d14` | `#f3f3f5` | window content bg |
| `--chrome` | `#0b0f18` | `#e9e9ec` | titlebar / rail / headers / footer |
| `--panel` | `#131926` | `#ffffff` | task cards, palette |
| `--panel2` | `#101623` | `#ffffff` | inputs, stat cards, chips |
| `--panel3` | `#141b28` | `#ededf1` | buttons, tabs, active shell tab bg |
| `--elev` | `#18202f` | `#eef0f4` | hover / selected rows |
| `--border` | `#2a3346` | `#d6d6dc` | primary borders |
| `--border2` | `#242c3c` | `#dcdce2` | secondary borders |
| `--borderSoft` | `#1c2331` | `#e0e0e6` | dividers |
| `--text` | `#e7ebf3` | `#1d1d1f` | primary text |
| `--dim` | `#8a93a6` | `#6b6b70` | secondary text |
| `--faint` | `#6f7890` | `#8a8a90` | tertiary / meta |
| `--faint2` | `#525b6f` | `#a0a0a8` | quaternary |
| `--termbg` | `#080b11` | `#1e1e22` | terminal + viewer (dark in BOTH) |
| `--primary` | `#f0b45e` (amber) | `#0a84ff` (macOS blue) | primary actions |
| `--primaryText` | `#241a08` | `#ffffff` | text on primary |
| `--sb` | `#2a3346` | `#c8c8d0` | scrollbar thumb |

**Native mapping tip:** in Native mode prefer system semantic colors so accent/appearance settings are respected — `--bg`→`windowBackgroundColor`, `--panel`→`controlBackgroundColor`/`textBackgroundColor`, `--primary`→`controlAccentColor`, `--text`→`labelColor`, `--dim`→`secondaryLabelColor`, `--faint`→`tertiaryLabelColor`, borders→`separatorColor`. The hex values above are the fallback / exact-match reference.

### Status accent colors (per theme)
| status | Beacon | Native |
|---|---|---|
| working | `#5ec8e0` | `#0a84c2` |
| needs | `#f0b45e` | `#c8871a` |
| idle | `#6fd39a` | `#1f9d55` |
| stale | `#cbbb5f` | `#98811a` |

### Diff / semantic (used on light or dark surfaces)
- Added: text `#4fb07a` on chrome, `#6fd39a` on terminal; added-line bg `rgba(111,211,154,.10–.12)`.
- Removed: text `#d46b64` on chrome, `#e0736d` on terminal; removed-line bg `rgba(224,115,109,.10–.12)`.
- Model dot: `#3f6cd6`. Context meter gradient: `#5ec8e0 → #4a9fd6`. "diff vs base": `#4a9fd6`.
- File status badges: Added `#5fc389`, Modified `#e0a34a`, Deleted `#d46b64` (badge bg = `{col}33`).

### Terminal syntax colors (on `--termbg`)
base `#c8cfdd` · keyword `#c792ea` · identifier/function `#82aaff` · string `#ecc48d` · tag `#f07178` · comment/dim `#5b6478` · line numbers `#3f4a5e` · tool-call heading `#82aaff` · success marker `#6fd39a` · amber marker/cursor `#f0b45e`.

### Typography
- **UI:** `Space Grotesk` (400/500/600/700). Fallback `system-ui`. On native, `SF Pro` is an acceptable substitute if you prefer stock; Space Grotesk gives the branded feel.
- **Mono (terminal, code, meta, keycaps):** `JetBrains Mono` (400–700). Terminal itself uses whatever SwiftTerm is configured with.
- Scale used: 23 (Harbor title) · 20 (summary head) · 15 (card title) · 14.5 (task header) · 13–13.5 (buttons/body) · 12.5 (secondary/terminal) · 11–11.5 (meta) · 10.5 (pills/keycaps). Letter-spacing: -.01em on big titles, +.04–.06em uppercase labels.

### Radius / spacing / shadow
- Radius: 16 (palette) · 14 (cards) · 12 (repo rows, stat cards) · 11 (rail buttons) · 10 (search/new-task) · 9 (chips, seg, merge) · 8 (tabs, chips) · 7 (segments) · 6/5 (keycaps) · 20 (pills) · 50% (dots/avatars).
- Standard paddings: view gutter 30px; card 16–17px; header rows 52px tall; titlebar 38px; footer 30px; rail 60px; navigator 340px.
- Shadows: card `0 1px 3px rgba(0,0,0,.16)`; needs-you glow `0 0 26px -8px {accent}`; palette `0 30px 80px rgba(0,0,0,.5)`; primary button `0 2px 10px rgba(240,180,94,.28)` (Beacon) / `0 1px 3px rgba(10,132,255,.35)` (Native).

### Keyboard shortcuts
`⌘K` palette · `⌘J` toggle terminal/file-viewer · `⌘\` toggle navigator · `⌘T` new shell tab · `Esc` close palette.

---

## AppKit / SwiftUI Mapping (implementation guide)
- **Window + 3 zones:** `NSSplitViewController` (sidebar = rail/tasks, content = center, inspector = navigator) or SwiftUI `NavigationSplitView`. Navigator is a collapsible **inspector**; rail is a thin collapsed sidebar.
- **Titlebar:** transparent titlebar + `NSTitlebarAccessoryViewController` for the right-side theme switcher; centered title via a titlebar accessory or `NSWindow.title` styling. Use the real traffic lights.
- **Theme:** `NSApp.appearance` (`.darkAqua` for Beacon look isn't required — Beacon is a *custom* dark palette, Native = system). Back all colors with an **Asset Catalog color set** (light/dark variants) or a `Theme` struct exposing the tokens; Native pulls from `NSColor` semantic colors, Beacon from custom values. Swapping `theme` re-resolves colors app-wide.
- **Terminal:** existing **SwiftTerm** `NSView`, hosted via `NSViewRepresentable` if SwiftUI.
- **Segmented controls** (theme switch, Terminal/Summary, navigator tabs): `NSSegmentedControl` / SwiftUI `Picker(.segmented)`.
- **Task list / rail / commit history / file tree:** `NSTableView`/`NSOutlineView` or SwiftUI `List`. Status dot = small circle view; pulse via `CABasicAnimation` on `shadowRadius`/opacity.
- **⌘K palette:** a borderless child `NSPanel` (or SwiftUI overlay `.sheet`-like) with vibrancy + blur (`NSVisualEffectView`).
- **Diff viewer:** attributed-string / text view with per-line background; drive from your git client's diff output.
- **Animations:** Core Animation; respect `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.
- **Ambient beam:** a `CAGradientLayer`/conic layer with a rotation animation behind the Harbor content; gate behind the `showBeam` preference and reduce-motion.

Preferences to expose (mirroring prototype tweaks): default **theme**, default **start view** (harbor/focus), **ambient beam** on/off.

---

## Files
- `Lighthouse.dc.html` — the full interactive prototype (both themes, all views, all interactions). Open it directly in a browser; use the titlebar switcher for Native/Beacon, click cards to enter Focus, `⌘K` for the palette, click navigator files for the viewer.

## Assets
No raster/vector assets required. All iconography in the prototype is Unicode glyphs (`◱ ◨ ◑ ○ ⌕ ✦ ● ✳ ▾ ×`) used as placeholders — **replace with SF Symbols** in the native build (suggested: `square.grid.2x2` for Harbor, `sidebar.right` for navigator toggle, `magnifyingglass` for search, `sparkles` for the agent tab, `circle.fill` for status dots). Fonts (Space Grotesk, JetBrains Mono) are Google Fonts — bundle them or substitute SF Pro / SF Mono. The beacon logo dot is a CSS radial gradient — recreate as a small gradient layer or a bundled icon.
