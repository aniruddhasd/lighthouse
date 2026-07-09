# Lighthouse

A native macOS developer tool: a single-app home for daily agentic development
across git worktrees. This repository currently contains the foundation
layers — the git access layer, the task engine, and their test harness.
No UI yet.

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
  store with atomic writes. Records `adapterKind`/`sessionRef` but never
  launches agent sessions — that is the agent adapter's job (next layer).
- `Sources/LighthouseAdapter` — the agent seam. The `AgentAdapter` protocol
  (launch/resume plans, attention wiring, payload translation — one of the
  two future-public contracts) and its single v1 implementation,
  `ClaudeCodeAdapter`. Includes the hook installer (surgical merge into
  `.claude/settings.local.json` plus a repo-local git exclude entry), the
  Unix-socket attention listener (0600, size-capped, hostile-input hardened),
  and the shell quoter guarding the app's single shell string (the
  login-shell launch). Every Claude Code CLI fact is recorded with its source
  in `docs/claude-code-contract.md` — re-verify that file when the CLI updates.
- `Sources/LighthouseFixtures` — test harness: generates hermetic, throwaway
  git repositories with known state (clean history, dirty trees, detached
  HEAD, content / delete-modify / binary merge conflicts, paths with spaces,
  attached worktrees). Never touches global git config or the network. Kept as
  a separate target so fixtures can never ship inside an app target.
- `Tests/` — fixture-driven tests plus pure tests on synthetic input (porcelain
  parsing, state-machine table, config round-trips). Failure and edge cases
  are written before happy paths.

## Building and testing

Requires macOS 14+, git >= 2.35, and a Swift 6 toolchain.

```sh
swift build
swift test
```

### On machines with only Command Line Tools (no Xcode)

CLT ships Swift Testing as `Testing.framework`, but SwiftPM (observed with
Swift 6.3.2 / CLT 26.x, 2026-07) passes that directory to the compiler as a
swiftmodule search path (`-I`) instead of a framework search path (`-F`). The
auto-generated test runner then compiles its `#if canImport(Testing)` block
away, and **`swift test` exits 0 having run zero tests** — a silent false
green.

After any fresh clone or `.build` wipe, run once:

```sh
./Scripts/bootstrap-clt-swift-testing.sh
swift test
```

A healthy run prints a `Test run with N tests` summary line. If `swift test`
prints no test summary at all, the shim is missing — do not trust that run.
Xcode-based toolchains don't need any of this.
