# Lighthouse

A native macOS developer tool: a single-app home for daily agentic development
across git worktrees. A **task** owns one or more git workspaces (a worktree per
repo, or a repo's own checkout) and a Claude Code session; Lighthouse runs the
sessions side by side, lets you review each task's changes live, and handles the
worktree bookkeeping.

The app has two top-level views:

- **Harbor** — the fleet overview: a grid of task cards (live-session dot,
  free-text status, diff counts) plus a collapsible Repos section.
- **Focus** — one task, with the terminal as the full-bleed hero. A 60px rail of
  task dots on the left; a slide-in navigator (Changes / Files / History) and a
  file viewer/editor on demand; a Terminal ⇄ Summary toggle.

## Status model

Lighthouse does **not** infer what an agent is doing. The attention system
(automatic hooks for every task, the working / needs-input / done / dirty state
machine, notifications and the dock badge) was removed on 2026-07-29 — hook signals were not trustworthy enough to drive the UI. What
remains:

- **Free-text status** — a per-task string you set by hand (`TaskRecord.status`).
- **Session liveness** — whether a pty exists for the task right now
  (`AppModel.isSessionLive`). This is the only automatic signal, and it gates
  the quit confirmation and resume.
- **Supervision (opt-in, observation only)** — a per-task `supervised` flag.
  When on, Lighthouse installs Claude Code hooks in the task's workspaces and
  logs the events the agent reports (Summary tab → Supervision). Nothing acts on
  them yet; this is orchestrator phase 1a, see `docs/orchestrator-design.md`.
- **Hide** — a per-task view preference that drops a task from the Harbor grid
  and ⌘K (Harbor's "Hidden N" toggle reveals them).

The merge-to-base feature (merge walk, conflict resolution) was also removed
(2026-07-23, commit `7bec890`). `WorkspaceMergeState` remains in the persisted model but nothing in the UI
drives it.

## Layout

- `Sources/LighthouseGit` — the `GitClient` actor, the only place in the app that
  invokes git (plus `ProcessRunner`), with pure parsers for the porcelain
  formats (`status --porcelain=v2`, `worktree list --porcelain`, name-status,
  numstat, commit log). Covers worktrees and branches, live and uncommitted
  diffs, diff stats, file listing/contents/`writeFile`, `git grep`, commit log
  and commit diffs. All subprocess calls use argument arrays — never a shell.
  `RepoCloner` (clone-from-URL registration) and `PullRequestCheckout` (resolve
  and check out a PR through the `gh` CLI) are the only network-touching paths,
  and both are user-initiated; there is no background fetch/pull/push.
- `Sources/LighthouseTaskEngine` — the task lifecycle. Atomic task creation
  (worktree + branch per repo from the local base tip, env-file copies, setup
  scripts) with full rollback on any failure; in-place tasks (investigate in a
  repo's own checkout, no branch); adding a worktree, a tracked checkout, or an
  adopted existing worktree to a running task; guarded removal of a task or a
  single workspace (destroying unmerged or dirty work requires a typed
  confirmation carrying the exact (repo, branch) list; in-place workspaces are
  never destroyed, only detached); and the schema-versioned JSON config store
  with atomic writes.
- `Sources/LighthouseAdapter` — the agent seam, and the supervision hook
  transport (`HookInstaller`, `HookEventListener`, `ClaudeHookParser`). The `AgentAdapter` protocol
  (`launchPlan` / `resumePlan`) and its single implementation,
  `ClaudeCodeAdapter`, plus the shell quoter guarding the app's one shell
  string. The adapter only builds the launch command — the pty runs a
  persistent interactive login shell (`$SHELL -l -i`) and the `claude` command
  is *typed* into it, so quitting Claude returns you to your prompt in the
  worktree. Every Claude Code CLI fact is recorded in
  `docs/claude-code-contract.md`; re-verify it when the CLI updates.
- `Sources/LighthouseAppCore` — the testable core, free of UI imports: the
  observable `AppModel` (repo registry, task list, session liveness, status,
  hide, ordering, quit/resume derivations, task creation/removal orchestration),
  navigation state, the fuzzy matcher behind ⌘K, the ⌘P file finder, the
  navigator presenter and tree builder, the live-diff service, diff/file page
  builders, prerequisite checks, the failure formatter, and the `TaskDigest`
  cache and `TranscriptReader`.
- `Sources/LighthouseApp` — the macOS app: SwiftUI shell (`HarborView`,
  `FocusView`, `CenterStageView`, `NavigatorView`, sheets, ⌘K / ⌘P / content-search
  overlays), the SwiftTerm session layer (`SessionRegistry`,
  `LighthouseTerminalView`), a runtime theme (Beacon dark / Native light), a
  custom titlebar, motion, Preferences, and the review pane (changed-files tree,
  diff in a locked-down WKWebView, FSEvents-driven refresh). Terminals live in a
  registry keyed by task id, outside the SwiftUI view tree — sessions keep
  running while unfocused and survive Harbor ⇄ Focus flips. The diff renderer is
  vendored diff2html (`docs/diff-renderer.md`) — fully offline. The terminal font
  is a bundled JetBrains Mono.
- `Sources/LighthouseFixtures` — test harness: generates hermetic, throwaway git
  repositories with known state. Never touches global git config or the network.
  A separate target so fixtures can never ship inside an app target.
- `Tests/` — one test target per source target (Swift Testing). Failure and
  edge cases are written before happy paths.
- `Scripts/` — `make-app.sh` (bundle assembly), `smoke-run.sh` (runtime gates),
  `verify-pins.sh` / `verify-vendored-assets.sh` (supply-chain gates).
- `docs/` — see [Docs](#docs).
- `AppIcon.appiconset/` and `design_handoff_lighthouse_ui/` — the icon asset and
  the original UI design handoff (reference only).

## Features

**Tasks**
- **New Task** sheet with three modes: *New worktree* (a worktree + branch per
  selected repo), *Current directory* (in-place, no branch), and *From PR*
  (a GitHub PR number/URL checked out through `gh` onto `pr-<N>`; one repo).
- **Add to task**: a new worktree, track a repo's current directory, or adopt an
  existing worktree.
- **Remove** a task, or remove/detach one repo from a task (*Detach* keeps the
  files; *Discard* deletes them behind the typed confirmation when work would be
  lost).
- **Scratch terminal** (⌘⌥T): a plain terminal in a chosen directory, no repo,
  not persisted.
- Sessions are named after the task (`-n`) and resumable (`claude --resume`);
  extra workspaces are passed with `--add-dir`.

**Repos**
- **Register Repo** (⇧⌘O) from a local clone, or clone from a URL (base branch
  is auto-detected). Per-repo optional setup script and env-copy list.

**Review (Focus)**
- Navigator tabs: *Changes* (live diff vs the task's base, with an
  uncommitted-only scope), *Files*, *History*. Diff files are collapsible.
- The diff base is a per-task, per-workspace branch override chosen on the
  Summary tab (default: the repo's registered base branch).
- File viewer with a simple editor (⌘S saves; external-change conflict prompt).
- ⌘P quick-open, ⌘F find in file, ⇧⌘F find in files (`git grep`).
- **Summary** tab: status, diff-base picker, diff-stat cards, and the opt-in
  **Supervision** card (hook-event log for that task).

**Shell**
- ⌘K switcher, Harbor keyboard traversal (Tab / arrows / Return), themes,
  Preferences (⌘,): theme, start view, ambient beam, terminal font size.

### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘K | Switch task (search) |
| ⇧⌘] / ⇧⌘[ | Next / previous task |
| ⇧⌘H | Back to Harbor |
| ⌘P | Find file (Focus) |
| ⌘F / ⇧⌘F | Find in file / in files (Focus) |
| ⌘J | Close the file viewer, back to the terminal/summary (Focus) |
| ⌘\ | Toggle the navigator (Focus) |
| ⌘⌥→ / ⌘⌥← | Cycle Focus chrome stops (mode toggle → navigator toggle → repo picker) |
| ⌘⌥↑ / ⌘⌥↓ | Operate the highlighted chrome stop |
| ⌘R | Refresh diff (navigator visible) |
| ⌘T / ⌘W | New / close terminal tab |
| ⌘⌥T | New scratch terminal |
| ⇧⌘O | Register repo |
| ⌘, | Preferences |

Chrome shortcuts use ⌘ (not Ctrl, not Esc) because ⌘ reaches the app before the
terminal; Ctrl keys and Esc belong to the shell and the agent.

## Building, testing, running

Requires macOS 14+, git ≥ 2.35, Xcode 26+ (SwiftTerm needs the full SDK), and
the Claude Code CLI resolvable in your login shell for live sessions. The `gh`
CLI is needed only for *From PR*.

```sh
swift test               # the single test entry point (all targets)
Scripts/make-app.sh      # assemble dist/Lighthouse.app from the SPM build
open dist/Lighthouse.app
```

The SPM package is the single source of truth — there is no .xcodeproj.
`make-app.sh` first runs the supply-chain gates (vendored diff2html and bundled
fonts match their `SHA256SUMS`; `Package.resolved` matches
`Scripts/pinned-revisions.txt`), builds with `--force-resolved-versions`, then
wraps the release binary in a minimal bundle (`dev.lighthouse.app`, ad-hoc
signed, app icon compiled with `iconutil`, build stamp = short git SHA plus
`-dirty` when the tree is dirty).

`LIGHTHOUSE_SMOKE=1 Scripts/smoke-run.sh` drives the real app through runtime
gates for SwiftUI/WebKit behaviour unit tests can't reach (terminal geometry,
review pane, diff and file render, navigator, theme, Harbor, Focus, digest,
motion). Each gate is switched on by a `LIGHTHOUSE_DEBUG_*` environment
variable; `LIGHTHOUSE_CONFIG_DIR` points the app at a throwaway config dir.
*Caveat:* the script's first check still asserts the removed attention socket
(`attention.sock`, mode 0600), so that section is out of date with the code —
see *Known gaps* below.

## First run

On first launch (no repos registered, setup never completed) a setup sheet runs
two prerequisite checks — git ≥ 2.35, and `claude` resolvable through your
interactive login shell — then points you at registering a first repo. Re-run
any time from **Help → Run Setup Checks**.

## State locations

- Supervision: `hooks.sock` (0600) and `hook-events.jsonl` (0600, rotates at
  5 MB; contains agent output — treat as sensitive) beside the config, and a
  `.claude/settings.local.json` in each supervised workspace (git-excluded via the
  repo's shared `info/exclude`).
- Config: `~/Library/Application Support/Lighthouse/config.json` (schema v6;
  older versions migrate on load; the legacy attention `state` key is ignored).
  Holds repos, tasks (name, branch, adapter kind, session ref, free-text status,
  hidden flag, workspaces with per-workspace diff-base override), the worktrees
  root override, and UI prefs (theme, start view, ambient beam, terminal font
  size, Repos section collapsed). Never contains secrets; env files are copied
  between worktrees but their contents are never read into config.
- Task worktrees are created next to each repo —
  `<repo parent>/lighthouse-worktrees/<task name>/<repo>/` — so sessions inherit
  whatever cwd-keyed environment (per-folder account selectors, direnv) applies
  to that directory tree. A global `worktreesRootOverride` in the config replaces
  the derived location. Tasks created under older schemes keep working from
  their persisted worktree paths.

## Docs

- `docs/claude-code-contract.md` — verified Claude Code CLI facts (flags, launch
  shell, transcript schema). Hook sections are retained as history; see its
  status banner.
- `docs/diff-renderer.md` — diff2html choice, vendoring, checksum and pin gates,
  and the diff-pane security posture.
- `docs/redesign-implementation-spec.md` — the Harbor/Focus redesign plan, with a
  status section listing what shipped and where reality diverged.

## Known gaps

- `TaskDigest` holds `model`, `context` (ctx%), `baked` and `action` fields, and
  `TranscriptReader` can derive model/ctx% from a session transcript — but
  nothing in the app feeds them since the hooks were removed (only `diffStat` is
  populated), so those chips render blank. The rich Summary ("what the agent
  did", "next step") was never built.
- `Scripts/smoke-run.sh` still asserts the removed `attention.sock` (the new
  socket is `hooks.sock`, and only exists while a task is supervised).
- Supervision (phase 1a) has one real interactive observation so far (see
  `docs/orchestrator-design.md`): the gated live test covers `-p` mode only, and a
  workspace added to an already-supervised task isn't wired until the toggle is
  cycled.
- Stale wording remains in comments and UI strings (e.g. the RemoveTaskSheet
  in-place text mentions "attention hooks"; `AppRuntime`/`SetupView` doc
  comments describe the socket and hook self-test).
