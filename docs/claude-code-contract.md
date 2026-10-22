# Claude Code contract — verified facts

> **Status (updated 2026-10-22):** the hook-based attention system was removed
> on 2026-07-29 (commit `3bf8660`). Orchestrator phase 1a reinstated a narrower
> hook path **only for tasks the user opts in to supervising** (observation
> only; see "Hook re-verification" below and `docs/orchestrator-design.md`).
> Unsupervised tasks get no hooks and no socket. The **CLI flags**,
> **multi-account / login shell**, and **transcript JSONL** sections remain
> live contract. The **hook events / payload / configuration / settings.local.json
> / live verification** sections are **historical** — facts as verified on
> 2026-07-09, kept for the day hooks return; they are not exercised by current
> code and were not re-verified in this update. The launch shape changed too:
> the `claude` command is now typed into a persistent `$SHELL -l -i`, not run via
> `-c 'exec claude …'` (see "Multi-account / login shell").

Every fact Lighthouse relies on from the Claude Code CLI, verified against the
installed binary and the current official docs. Where the CLI and docs
disagree, the installed CLI wins and the disagreement is flagged. Re-verify
this file when the CLI is updated; it exists to make contract drift diffable.

- **Verified on:** 2026-07-09
- **CLI:** `2.1.205 (Claude Code)` at `~/.local/bin/claude` (`claude --version`, `claude --help`)
- **Docs:** code.claude.com/docs — hooks reference (`/en/hooks`), CLI reference
  (`/en/cli-reference`), settings (`/en/settings`), fetched 2026-07-09
- **curl:** 8.7.1 (macOS system, `/usr/bin/curl`), `--unix-socket` supported

## CLI flags (verified against `claude --help` 2.1.205)

| Fact | Verified value |
|---|---|
| Additional directories | `--add-dir <directories...>` — variadic, "Additional directories to allow tool access to". Docs add: grants file access, but **most `.claude/` configuration is NOT discovered from these directories** — hooks in sibling worktrees' settings do not load; only the cwd project's settings apply. |
| Resume | `-r, --resume [value]` — by session ID or name; a session ID "searches only the current project directory and its git worktrees" (docs). Optional prompt argument follows. |
| Pre-assigned session ID | `--session-id <uuid>` — "Use a specific session ID for the conversation (must be a valid UUID)". **This makes sessionRef deterministic at launch** — no discovery step needed. |
| Fork on resume | `--fork-session` — new session ID instead of reusing (with `--resume`/`--continue`). |
| Non-interactive | `-p, --print` — prints response and exits; workspace-trust dialog skipped; **settings files that fail validation are silently ignored in this mode** (so an invalid generated settings file = hooks silently absent; the installer must always emit valid JSON). |
| Extra settings at launch | `--settings <file-or-json>` — overrides same keys for the session; omitted keys keep file values. |
| Setting sources | `--setting-sources user,project,local` — all three load by default. |
| Session display name | `-n, --name <name>` — shown in prompt box and `/resume` picker (useful in step 4). |
| Hook kill-switches | `--bare` skips hooks entirely; `--safe-mode` disables hooks; `settings.disableAllHooks`. The pty layer must never pass these. |

## Hook re-verification — CLI 2.1.308, `-p` mode (2026-10-22)

Orchestrator phase 1a reinstated hooks for opted-in tasks (see
`docs/orchestrator-design.md`). Re-checked against the installed CLI
(`claude --version` → `2.1.308`) with the gated `LiveClaudeHookCaptureTests`
(`LIGHTHOUSE_LIVE_CLAUDE_TEST=1`, one haiku turn, `CLAUDE_CONFIG_DIR`
`~/.claude-enterprise`) through the real exec-form curl → unix-socket path:

- Delivered, in order: `SessionStart`, `UserPromptSubmit`, `Stop`, `SessionEnd`.
- Every event echoed the pre-assigned `--session-id` verbatim.
- `SessionEnd` carries the end reason in **`reason`** (value `other`), as on
  2.1.205 — not `end_reason`.
- `Stop` carried `last_assistant_message` plus undocumented/extra keys:
  `background_tasks, effort, session_crons, stop_hook_active` (`effort` is new
  since 2.1.205). `SessionStart` carried `source`. Decoders ignore unknown keys.
- Hooks docs (fetched 2026-10-22; page text was truncated, ~63% unread) list 33
  events, add `agent_id`/`agent_type` common fields for subagent events, and
  expand `Notification` types (`permission_prompt`, `idle_prompt`,
  `agent_needs_input`, `agent_completed`, plus elicitation/quota/plugin types).
  **Not established:** whether `Stop` fires for real subagent turns.
- **Interactive observation (2026-10-22, one task, CLI 2.1.308):**
  - A session **already running** began reporting after hooks were written to
    `.claude/settings.local.json` mid-session (first event ~70 s after the write);
    it did not report the `SessionStart` that had already passed. One
    observation, one task — not a guarantee.
  - `SessionEnd` carried `reason: prompt_input_exit` on exit; `SessionStart`
    (`source` key) fired on `--resume` and carried the **same `session_id`**, so
    the pre-assigned `sessionRef` survives exit/resume.
  - **`SubagentStop` fires for unprompted helper output with the primary's
    `session_id`**, `agent_id` set, `agent_type` present but **empty**, and an
    `agent_transcript_path` key; no matching `SubagentStart` was logged.
    **Confirmed by the user's observation (2026-10-22):** the ~2 s-after-`Stop`
    `SubagentStop` carries the suggested next-prompt placeholder shown in the
    prompt box ("go ahead with change 1 on a branch"), seen on three turns. A
    separate ~3 min-later `SubagentStop` (256 chars, "…Next, decide whether…")
    looked like a session recap — inferred from content only, not confirmed. The
    mechanism is not documented in what was read of the hooks reference. Consumers
    must not treat a `SubagentStop` as a turn boundary; its text is untrusted
    model output derived from the conversation.
  - Keys seen: `SessionStart`: `source`; `UserPromptSubmit`: `prompt`,
    `prompt_id`, `permission_mode`, `scratchpad_dir`, `session_title`; `Stop`: also
    `effort`, `background_tasks`, `session_crons`, `stop_hook_active`.

## Hook events — HISTORICAL (removed from Lighthouse 2026-07-29)

(docs /en/hooks; full list is ~30 events — the ones we used)

| Event | Fires | Lighthouse mapping |
|---|---|---|
| `UserPromptSubmit` | user submits a prompt, before Claude processes it | `agentWorking` |
| `Notification` | Claude Code sends a notification; **matcher = notification type** | `permission_prompt`, `idle_prompt`, `agent_needs_input` → `agentNeedsInput`; `agent_completed` → `agentStopped`; other types (`auth_success`, `elicitation_*`) ignored |
| `Stop` | Claude finishes responding (no matcher support) | `agentStopped` |
| `StopFailure` | turn ends due to an API error | `agentNeedsInput` (an errored agent needs a human) |
| `SessionEnd` | session terminates; matcher = end reason (`clear`, `resume`, `logout`, `prompt_input_exit`, `other`) | `sessionDied` |
| `SessionStart` | session begins/resumes (matchers `startup`/`resume`/`clear`/`compact`) | not installed — session identity is pre-assigned via `--session-id`, so no discovery needed |

The spec's hypothesis that `Notification` covers permission/idle was correct
but incomplete: notification *types* are matchable, so the noisy types never
reach our socket at all.

## Hook payload — HISTORICAL (docs /en/hooks; confirmed live 2026-07-09)

Delivered as JSON on stdin to command hooks. Common fields:
`session_id`, `prompt_id` (v2.1.196+), `transcript_path`, `cwd`,
`permission_mode`, `hook_event_name`. Event-specific: `notification_type`,
`message`, `tool_name`, `tool_input` (Notification);
`last_assistant_message` (Stop); `end_reason` (SessionEnd);
`source`, `model` (SessionStart).

Real captured payloads (live one-shot run, CLI 2.1.205, 2026-07-09, via the
gated `LiveClaudeHookCaptureTests`; home and temp paths shortened):

```json
{"session_id":"f003c561-…","transcript_path":"~/.claude-enterprise/projects/…/f003c561-….jsonl","cwd":"/private/var/…/clean-DD46E857","prompt_id":"353dccec-…","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"Reply with exactly: OK"}

{"session_id":"f003c561-…","transcript_path":"…","cwd":"…","prompt_id":"353dccec-…","permission_mode":"default","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"OK","background_tasks":[],"session_crons":[]}

{"session_id":"f003c561-…","transcript_path":"…","cwd":"…","prompt_id":"353dccec-…","hook_event_name":"SessionEnd","reason":"other"}
```

**CLI-vs-docs disagreements observed live (CLI wins):**
- `SessionEnd` delivers the end reason in a field named **`reason`** — the
  docs say `end_reason`. Lighthouse does not read the field (every
  SessionEnd maps to `sessionDied`), but any future consumer must use
  `reason` on 2.1.205.
- `Stop` carries undocumented extras (`stop_hook_active`,
  `background_tasks`, `session_crons`) and `SessionEnd` omits
  `permission_mode`. Decoders must ignore unknown fields and treat
  common fields as optional — ours do.

## Hook configuration shape — HISTORICAL (docs /en/hooks)

Three-level nesting: event name → matcher groups → handlers. A handler with
`"type": "command"` plus an **`args` array runs in exec form: "command is
resolved as executable, spawned directly with args as argument vector, no
shell involved."** Lighthouse uses exec form exclusively — hook delivery
never touches a shell, so hostile content in payloads/paths has no shell to
reach. (`"type": "http"` exists but is TCP-only — rejected: the spec forbids
any TCP listener.)

`async: true` runs the hook in the background without blocking the agent —
used so a dead listener can never stall a session (spec §8 fail-safe).

## settings.local.json + gitignore — HISTORICAL (docs /en/settings)

- Precedence (highest→lowest): managed policy → CLI args →
  `.claude/settings.local.json` → `.claude/settings.json` → `~/.claude/settings.json`.
  Project-level files live in the project directory and load regardless of
  which user config dir is active (confirmed live under `CLAUDE_CONFIG_DIR`,
  see below).
- **The spec assumed Claude Code auto-gitignores `settings.local.json`. The
  docs say it does so only "when Claude Code creates" the file: "If you
  create the file yourself, add it to your gitignore manually."** Lighthouse
  creates the file, so Lighthouse owns the ignore. Mechanism: append
  `.claude/settings.local.json` to `git rev-parse --git-path info/exclude` —
  verified empirically (git 2.50.1) to resolve from a linked worktree to the
  repo's shared `.git/info/exclude`, so one repo-local entry covers every
  task worktree and can never be committed.

## Multi-account / login shell (verified on this machine)

The user's `claude` is a zsh **function** that sets
`CLAUDE_CONFIG_DIR=$HOME/.claude-enterprise` when `$PWD` is under the work
directory. Functions come from `.zshrc`, which only interactive shells load —
so the launch plan runs a persistent `$SHELL -l -i` (login **and** interactive)
in the pty and *types* the `claude` command into it (`LaunchPlan.typedCommand`,
composed by `ShellQuoter`). This replaced `-l -i -c 'exec claude …'` on
2026-07-13: `exec` made Claude's exit kill the pty, whereas a persistent shell
drops back to the user's prompt in the worktree with the same account env. A
plain `-l -c` would silently miss `.zshrc`-defined selectors and launch under
the wrong account. `CLAUDE_CONFIG_DIR` itself is absent from the settings docs page —
its per-folder selection is user-side shell logic, not a documented contract.

## Live hook verification — HISTORICAL (gated test, run once 2026-07-09)

`claude -p "Reply with exactly: OK" --model haiku --session-id <uuid>` in a
temp git fixture, with hooks installed by our HookInstaller into
`.claude/settings.local.json` and `CLAUDE_CONFIG_DIR` pointing at the
enterprise account. Result (exit 0, ~5s): `UserPromptSubmit`, `Stop`, AND
`SessionEnd` all fired and were delivered through
`curl --unix-socket → AttentionSocketListener`, mapping to
`agentWorking` / `agentStopped` / `sessionDied` for the pre-assigned session
ID. This confirms live: hooks fire in `-p` mode (including SessionEnd),
project-local settings apply under a non-default `CLAUDE_CONFIG_DIR`, the
pre-assigned `--session-id` is echoed back verbatim in `session_id`, and
exec-form curl delivery works end-to-end.

Also learned the hard way: macOS caps unix socket paths (`sun_path`) at
~104 bytes — the listener rejects longer paths loudly at start. The prod
socket directory (app container) must stay comfortably under that.

## Transcript JSONL — schema for the digest (Phase 4)

- **Verified on:** 2026-07-15, against a real session transcript under
  `~/.claude/projects/<slug>/<session-id>.jsonl` (structure/keys only — no
  conversation content was copied anywhere). Treat every byte as untrusted.

The transcript is line-delimited JSON (one object per line). Each line has a
top-level `type`; the values observed were `user`, `assistant`, `system`,
`summary`, `attachment`, `file-history-snapshot`, plus several bookkeeping
types (`agent-name`, `ai-title`, `mode`, `permission-mode`, `last-prompt`,
`queue-operation`). Only `assistant` lines matter for the digest.

An `assistant` line carries a nested `message` object (the raw Anthropic API
message) alongside envelope keys (`uuid`, `parentUuid`, `sessionId`,
`timestamp`, `gitBranch`, `cwd`, `version`, `requestId`, …). Inside `message`:

| Field | Shape | Digest use |
|---|---|---|
| `message.model` | string, e.g. `claude-opus-4-8`; synthetic/injected turns carry the literal `<synthetic>` | **model** chip — the honest source. `<synthetic>` is filtered out. |
| `message.usage.input_tokens` | int (uncached prompt tokens for that request) | ctx numerator |
| `message.usage.cache_read_input_tokens` | int (prompt tokens served from cache) | ctx numerator |
| `message.usage.cache_creation_input_tokens` | int (prompt tokens newly written to cache) | ctx numerator |
| `message.usage.output_tokens` | int | — |

**ctx% — DECISION: build the meter (honest estimate).** The three input-side
counters on a request are disjoint and sum to the full prompt size sent to the
model that turn: `prompt = input_tokens + cache_read_input_tokens +
cache_creation_input_tokens`. On the **last non-synthetic `assistant` line**,
that sum is a genuine measure of how full the context window is right now.
Divide by the model's context window to get an occupancy estimate. Context
windows (verified 2026-07-15 via the `claude-api` skill's model catalog):
`claude-opus-4-*`, `claude-sonnet-5`, `claude-sonnet-4-6`, `claude-fable-5`,
`claude-mythos-5` → **1,000,000**; `claude-haiku-4-5` → **200,000**. The meter
is framed as an **estimate**, and is **omitted** (field stays nil, nothing
renders) whenever the model id is unknown to that map or the transcript has no
usable last-usage line — never a fabricated or hand-waved percentage.

> **Current wiring (2026-10-22):** `TranscriptReader` exists and is unit-tested,
> but nothing in the app calls it since the hooks were removed, and the
> `baked`/`action` inputs below came from hooks. The ctx%/model schema above is
> intact; only the feeding is gone.

`baked` (turn duration) does **not** need the transcript: it is wall-clock
between this task's most recent `UserPromptSubmit` (agentWorking) hook and its
`Stop` (agentStopped) hook, tracked per task in the runtime. `action` is the
`Stop` hook's `last_assistant_message` (untrusted; rendered inert as SwiftUI
`Text`). Both are surfaced from the hook payload, not read here.

The reader is read-only, byte-bounded (tails the file — a transcript can be
hundreds of MB), and malformed-safe: bad/partial JSON on any line is skipped,
missing fields yield nil, and it never throws to the caller. No transcript
content is ever logged, committed, or written into this doc.
