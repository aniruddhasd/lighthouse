# Lighthouse

A native macOS developer tool: a single-app home for daily agentic development
across git worktrees — task-centric sessions, ambient attention state, and
worktree bookkeeping handled for you.

## Layout

- `Sources/LighthouseGit` — the `GitClient` actor, the only place in the app
  that ever invokes git, plus pure parsers for the porcelain formats
  (`status --porcelain=v2`, `worktree list --porcelain`). All subprocess calls
  use argument arrays — never a shell. No network git operations exist in this
  API at all (no fetch/pull/push): Lighthouse is fully offline by design.
- `Sources/LighthouseTaskEngine` — the task lifecycle. Atomic task creation
  (worktree + branch per repo from the local base tip, env-file copies, setup
  scripts) with full rollback on any failure; guarded removal in which
  destroying unmerged work requires a typed confirmation carrying the exact
  (repo, branch) list; the pure, total attention state machine
  (working / needs-input / done / dirty); and the schema-versioned JSON config
  store with atomic writes.
- `Sources/LighthouseAdapter` — the agent seam. The `AgentAdapter` protocol
  (launch/resume plans, attention wiring, payload translation — one of the
  two future-public contracts) and its single v1 implementation,
  `ClaudeCodeAdapter`. Includes the hook installer (surgical merge into
  `.claude/settings.local.json` plus a repo-local git exclude entry), the
  Unix-socket attention listener (0600, size-capped, hostile-input hardened),
  and the shell quoter guarding the app's single shell string (the
  login-shell launch). Every Claude Code CLI fact is recorded with its source
  in `docs/claude-code-contract.md` — re-verify that file when the CLI updates.
- `Sources/LighthouseAppCore` — the app's testable core, free of UI imports:
  the observable `AppModel` (repo registry, task list, attention reducer,
  switcher/inbox ordering, quit and resume derivations), the fuzzy matcher
  behind Cmd+K, and the honest failure formatter.
- `Sources/LighthouseApp` — the macOS app itself: SwiftUI shell
  (NavigationSplitView, sidebar with attention badges, Cmd+K switcher,
  guardrail sheets), the SwiftTerm session layer, and the live review pane
  (per-task repo switcher, changed-files tree, diff-vs-base in a locked-down
  WKWebView, FSEvents-driven refresh). Terminals live in a registry keyed by
  task id, outside the SwiftUI view tree — sessions keep running while
  unfocused and survive tab switches. The diff renderer is vendored
  diff2html (see `docs/diff-renderer.md`) — fully offline.
- `Sources/LighthouseFixtures` — test harness: generates hermetic, throwaway
  git repositories with known state (clean history, dirty trees, detached
  HEAD, content / delete-modify / binary merge conflicts, paths with spaces,
  attached worktrees). Never touches global git config or the network. Kept as
  a separate target so fixtures can never ship inside an app target.
- `Tests/` — fixture-driven tests plus pure tests on synthetic input (porcelain
  parsing, state-machine table, config round-trips, matcher ranking). Failure
  and edge cases are written before happy paths.

## Building, testing, running

Requires macOS 14+, git >= 2.35, Xcode 26+ (SwiftTerm needs the full SDK),
and the Claude Code CLI on PATH for live sessions.

```sh
swift test               # the single test entry point (all targets)
Scripts/make-app.sh      # assemble dist/Lighthouse.app from the SPM build
open dist/Lighthouse.app
```

The SPM package is the single source of truth — there is no .xcodeproj.
`make-app.sh` wraps the release binary in a minimal bundle
(`dev.lighthouse.app`, ad-hoc signed), which native notifications will need
later. `LIGHTHOUSE_SMOKE=1 Scripts/smoke-run.sh` launches the built app,
checks the attention socket (0600) and clean-quit behavior, and exits.

State locations: config + attention socket in
`~/Library/Application Support/Lighthouse/`. Task worktrees are created next
to each repo — `<repo parent>/lighthouse-worktrees/<task name>/<repo>/` — so
sessions inherit whatever cwd-keyed environment (per-folder account
selectors, direnv) applies to that directory tree; a global
`worktreesRootOverride` path in the config replaces the derived location.
Tasks created before this scheme keep working from their persisted worktree
paths.
