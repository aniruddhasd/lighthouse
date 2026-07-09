# Claude Code contract — verified facts

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

## Hook events (docs /en/hooks; full list is ~30 events — the ones we use)

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

## Hook payload (docs /en/hooks; confirmed live — see sample below)

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

## Hook configuration shape (docs /en/hooks)

Three-level nesting: event name → matcher groups → handlers. A handler with
`"type": "command"` plus an **`args` array runs in exec form: "command is
resolved as executable, spawned directly with args as argument vector, no
shell involved."** Lighthouse uses exec form exclusively — hook delivery
never touches a shell, so hostile content in payloads/paths has no shell to
reach. (`"type": "http"` exists but is TCP-only — rejected: the spec forbids
any TCP listener.)

`async: true` runs the hook in the background without blocking the agent —
used so a dead listener can never stall a session (spec §8 fail-safe).

## settings.local.json + gitignore (docs /en/settings — SPEC DIVERGENCE)

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
so the launch plan runs `$SHELL -l -i -c 'exec claude …'` (login **and**
interactive; the session lives in a pty anyway, step 4). A plain `-l -c`
would silently miss `.zshrc`-defined selectors and launch under the wrong
account. `CLAUDE_CONFIG_DIR` itself is absent from the settings docs page —
its per-folder selection is user-side shell logic, not a documented contract.

## Live verification (gated integration test, run once 2026-07-09)

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
