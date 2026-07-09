# Lighthouse

A native macOS developer tool: a single-app home for daily agentic development
across git worktrees. This repository currently contains the foundation layer —
the git access layer and its test harness. No UI yet.

## Layout

- `Sources/LighthouseGit` — the `GitClient` actor, the only place in the app
  that ever invokes git, plus pure parsers for the porcelain formats
  (`status --porcelain=v2`, `worktree list --porcelain`). All subprocess calls
  use argument arrays — never a shell. No network git operations exist in this
  API at all (no fetch/pull/push): Lighthouse is fully offline by design.
- `Sources/LighthouseFixtures` — test harness: generates hermetic, throwaway
  git repositories with known state (clean history, dirty trees, detached
  HEAD, content / delete-modify / binary merge conflicts, paths with spaces,
  attached worktrees). Never touches global git config or the network. Kept as
  a separate target so fixtures can never ship inside an app target.
- `Tests/LighthouseGitTests` — fixture-driven tests plus pure parser tests on
  synthetic porcelain input. Failure and edge cases are written before happy
  paths.

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
