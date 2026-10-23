# Orchestrator (supervisor) — design

Status: **phase 1a implemented (observation only); not yet observed in real
use.** Written and built 2026-10-22. Phases 1b and 2 are unbuilt.

### Phase 1a — what exists

- `TaskRecord.supervised` (default false; persisted; absent in old configs → false).
- `LighthouseAdapter`: `HookEvent` + `ClaudeHookParser` (total, bounded; keeps
  `payloadKeys`), `HookInstaller` (restored; wide event set; `Notification`
  unfiltered; install *replaces* stale handlers from the removed attention
  system; refuses invalid JSON), `HookEventListener` (restored socket, 0600,
  `hooks.sock` in the config dir, yields unattributed parsed events in order).
- `LighthouseAppCore`: `HookAttributor` (primary / otherSessionInTask /
  unattributed — path-boundary + `..` safe), `HookEventLog` (bounded, per task)
  and `HookEventSink` (JSONL `hook-events.jsonl`, 0600, rotates at 5 MB).
- `AppRuntime.setSupervised`: starts the listener, installs hooks in every
  workspace (flag persisted only if all installs succeed; partial failure rolls
  back), re-arms at launch, removes hooks on opt-out / task removal / detach.
- UI: a **Supervision** card on the Summary tab — toggle plus the last 30
  events, with non-primary attribution flagged.
- Tests: parser, installer (incl. stale-handler replacement), listener
  (hostile input, ordering, real-curl transport, slow-loris), attribution, log
  bounds, sink permissions/rotation, config round-trip; plus the gated live
  `-p` capture (CLI 2.1.308: see the contract doc).

### Phase 1a — first observations (2026-10-22, one task)

Full dated evidence lives in `docs/hook-observations.md`; the summary here is for decisions.

- Hooks written to a **running** session were honored (it missed only its own
  `SessionStart`); resume reuses `session_id`; exit reports
  `SessionEnd · prompt_input_exit`.
- **`SubagentStop` is not a turn.** Helper subagents (empty `agent_type`) emit
  `SubagentStop` after the real `Stop`, with the primary's session id and text
  that is the suggested-next-prompt placeholder (user-confirmed, ~2 s after the
  `Stop`) or, separately, a recap (inferred). Design rule hardened: only a `Stop`
  with **no `agent_id`** is a turn boundary. The suggestion is a possible *hint*
  of what the agent expects next, but it is untrusted model output — never an
  instruction to act on.
- The card now shows `SessionStart` `source`, keeps an empty `agent_type`, and
  labels anything with an `agent_id` "not a turn".

- **Failure and questions are structural.** An API/network failure ends a turn with
  `StopFailure` (own `error` key), not `Stop`; a questionnaire waiting on the user
  is a `PermissionRequest` (`tool_name`) with no `Stop`; answering it emits no
  event in the installed set. A `PostToolUse` matched to `AskUserQuestion` (experiment E1) **does** fire when
  a questionnaire is answered — an "unblocked" signal for that case (observed
  once, run 4); an Esc-cancelled one still emits nothing. Prompts and `Stop`s
  do not pair one-to-one (a mid-turn message fires `UserPromptSubmit` and gets no
  `Stop` of its own). The parser keeps `error` and `tool_name` but never
  `tool_input` / `tool_response` / `prompt` values.

- **A turn can end with no hook at all.** Esc-interrupting a turn emitted nothing
  (no `Stop`/`StopFailure`/`SessionEnd`), leaving a dangling `PermissionRequest`
  (observed once). 1b therefore needs a liveness/idle fallback (pty state, idle
  timeout, transcript `turn_duration`) and must never treat "no event" as "still
  waiting" or "done". `Notification` `permission_prompt` came ~6 s after 3 of the 4
  questionnaires left open ≥6 s, but not in one 51 s wait (unexplained) — a hint, not a dependable
  "waiting" signal.

- **A question can arrive as a plain `Stop`** (observed, run 4 addendum): same
  event as "done", only the text differs, and the question may be deep in a long
  message. Classification must read the full `last_assistant_message`, not a
  preview. The card truncates to 3 lines — fine for comparison with the terminal,
  not for judging.

### Phase 1a hardening (2026-10-23)

Done after the observation runs: recent events reload from `hook-events.jsonl` at
launch (bounded, read-only, events of deleted tasks dropped); the card shows a
count and last reason for deliveries the socket dropped; a workspace added to an
already-supervised task is wired immediately; long messages expand in the card.

Known gaps in 1a: mid-session pickup is observed, not proven in general;
`idle_prompt` / `agent_needs_input`, a real subagent with a non-empty `agent_type`
and a second session in another tab have not been exercised. Leftovers: old
attention hooks already sitting in existing worktrees stay inert until that task
is supervised (install replaces them) or never (they curl a dead socket, async,
harmlessly).

## 1. Goal

A central **supervisor** that talks to the agent sessions in selected Harbor
tiles. The user leaves standing instructions in natural language ("once A
finishes the migration, tell B to start the API changes"); the supervisor
watches the tasks, judges what happened, and does the follow-up.

Not in scope: a rigid rules schema (rejected — the completion condition is
semantic), supervising every session by default, multiple Claude sessions per
tile (phase 2), any auto-send without confirmation (until phase 1a evidence
supports it).

## 2. The central problem: "turn ended" is not "task done"

An agent can end a turn cleanly while having failed ("looks like the VPN is
down, I couldn't complete the request"). A hook `Stop` is structurally
identical for success, failure and a question. Therefore:

- **Hooks are a deterministic event source** — they say *when* to look and carry
  the agent's actual reply text.
- **The supervisor LLM is the judge** — it reads the reply and classifies it.
- **Default is hold.** Unclear classification → flag to the user, never advance.

## 3. Signal source: Claude Code hooks

From `docs/claude-code-contract.md` (CLI 2.1.205, verified 2026-07-09 —
**must be re-verified on the current CLI before relying on it**):

| Event | Meaning | Use |
|---|---|---|
| `Stop` | turn finished; payload has `last_assistant_message` | judge: done / blocked / question |
| `Notification` (matchers `permission_prompt`, `idle_prompt`, `agent_needs_input`) | agent blocked on a human | structural "needs a human"; never advance |
| `StopFailure` | turn ended on an API error | never "done" |
| `SessionEnd` | session terminated | mark target unavailable |
| `UserPromptSubmit` | a turn started | target is busy |

Every payload carries `session_id` and `transcript_path`. Hook config shape,
exec-form `args`, `async: true`, and the gitignore mechanism
(`.claude/settings.local.json` + the repo's shared `info/exclude`) are recorded
in that file's historical sections. `--bare` / `--safe-mode` disable hooks; the
pty layer must never pass them.

### Why the previous signals mismatched (unknown)

The attention system was removed in `3bf8660` (2026-07-29) without recorded
reasons beyond "replace with session liveness and freetext status". The user
recalls signals that "did not match the activity inside the session".

**Ruled out by reading the old code:** cwd-based attribution. The old listener
already attributed by `session_id` (`registrations[sessionRef]`), so a second
`claude` in the same worktree was dropped as "unknown session", not credited to
the primary. Remaining candidates (all unverified): the old *mapping* of events
to a state (`Notification` `idle_prompt`/`agent_completed` → needs-input/stopped,
`Stop` → stopped regardless of content), events from subagents, resumed/forked
sessions arriving under a new `session_id`, and delivery latency/ordering.
Phase 1a records `agent_id`, `session_id` and attribution per event precisely so
these can be told apart.

## 4. Architecture

```
claude (primary session of an opted-in tile)
  └─ hook (exec-form, async) ─▶ local Unix socket (0600) ─▶ EventLog (per task)
                                                              │
        supervisor (a Claude session) ◀── tool surface ───────┘
              tools: list_tasks · read_turn · read_transcript_tail
                     · propose_send · hold · ask_user
                                  │
                                  ▼
            confirm (UI) ─▶ SessionRegistry.typeIntoSession(taskId:text:)
```

- **Opt-in per tile.** A `supervised` flag on `TaskRecord` (alongside `status`,
  `hidden`; absent → false). Un-supervised tiles get no hook wiring, so they emit
  nothing and are unreachable by the supervisor. This is also a security
  boundary.
- **Event log** (`LighthouseAppCore`, pure + testable): append-only per task;
  stores type, `session_id`, timestamp, and the **full** `last_assistant_message`
  for `Stop`. Memory-bounded; no secrets in config.
- **Transport**: Unix socket listener, 0600, size-capped, hostile-input
  hardened (the removed `AttentionSocketListener` is the prior art — see git
  history before `3bf8660`). macOS `sun_path` limit ≈ 103 bytes.
- **Supervisor**: a long-lived Claude session holding the user's standing
  instructions, given a narrow tool surface (MCP server: spike-verified in `-p` mode, see §10; interactive pty-hosted
  attach still untested). Woken only on
  `Stop`, `Notification`, `StopFailure` — not every event — to bound cost.
- **Delivery**: existing `SessionRegistry.typeIntoSession` (`SessionRegistry.swift:106`).

### Boundaries (per the project's design constraints)

Event log + classification inputs are pure `AppCore`; the socket and pty live in
the app layer; the supervisor is behind a protocol so its transport (MCP, CLI)
is replaceable. The adapter stays the only place that knows Claude CLI facts —
hook installation belongs in `ClaudeCodeAdapter`'s side of the seam.

## 5. Behaviour rules

1. **Classify each `Stop`** as `done` / `blocked-or-failed` / `question` /
   `unclear`. Only `done` may advance a standing instruction.
2. `Notification` and `StopFailure` never advance.
3. **Deliver only to an idle target** (last event for it was `Stop` or
   `idle_prompt`, not `UserPromptSubmit`) — typing into a busy agent or
   permission prompt can answer a prompt by accident.
4. **Every send requires user confirmation** in phase 1b. Composition: the
   supervisor sends text *it* wrote; it never forwards raw agent output into
   another session.
5. **Single-shot with a hop limit**; persist "fired" before sending
   (idempotent across restart); no A→B→A loops.
6. Fail closed on any parse/delivery error; surface the typed error.

## 6. Security

- Agent output, transcripts and repo content are **untrusted**; the supervisor
  is a prompt-injection target with write access to other sessions. Mitigations:
  opt-in scope, no raw forwarding, mandatory confirmation, allowlisted tools,
  hop limit.
- Socket: 0600, owner-only parent dir, size-capped reads, input validated at the
  boundary; decoders ignore unknown fields and treat common fields as optional
  (the CLI added undocumented fields before).
- Hook delivery is exec-form (no shell). No secrets in hook payload handling,
  logs or the event log beyond what the agent itself said — treat the log as
  sensitive and keep it out of git and `/tmp`.

## 7. Multiple sessions per tile

A tile's extra tabs are plain shell tabs. If the user runs `claude` in one,
Lighthouse does not know its `session_id` (the CLI assigns it), yet the
worktree's hooks fire for it too. Handling of unknown `session_id` in a
supervised tile:

1. **Phase 1:** ignore (optionally log as `unregistered`, never act on it).
2. **Phase 2:** a "New Claude tab" action that launches through the adapter with
   a pre-assigned `--session-id`, registers it as a named child session of the
   tile, and makes it an addressable supervisor target. Requires a session
   registry carrying `(taskId, tabId, sessionId, role)` and delivery by tab
   (today's `typeIntoSession` takes only a task id).

Phase 1 event records carry `session_id` and tab id now so phase 2 is not a
schema change.

## 8. Phasing

| Phase | Scope | Exit criterion |
|---|---|---|
| 1a | Opt-in flag, hook install, socket, EventLog keyed by `session_id`; **observation only**, no actions | Logged events match terminal activity over ~1 week: no missed/duplicate `Stop`, no cross-session attribution, acceptable latency |
| 1b | Supervisor reads events + `last_assistant_message`, classifies, **proposes** sends; user confirms | Classification judged correct on real turns, incl. the blocked-by-environment case |
| 2 | Launchable tab sessions with pre-assigned ids; per-session targets | — |

Re-verify the hook contract against the installed CLI at the start of 1a and
update `docs/claude-code-contract.md`.

## 9. Open questions

- What exactly failed in the old hook pipeline (delivery, attribution, false
  "done")? Phase 1a answers this with evidence; the git history before
  `3bf8660` holds the old code.
- How does the supervisor get its tools (MCP server vs a CLI it shells out to)?
- Where does the supervisor session live — a dedicated tile, or a separate
  surface? Does it count as a "supervised" session itself?
- Cost ceiling: supervisor wakes per `Stop` per supervised tile.
- UI: where proposed sends and held items surface in Harbor.

## 10. Spike: supervisor tool surface (2026-10-23, CLI 2.1.308)

Question: can the supervisor be given *only* Lighthouse's tools — no shell, no
other MCP servers — and can it call them? Method: a throwaway stdio MCP server
(one tool, `ping`, logging every call to a file) launched through the real CLI in
`-p` mode with haiku, `CLAUDE_CONFIG_DIR=~/.claude-enterprise`, in an empty
non-git directory. Evidence is the init message's `tools` / `mcp_servers`, the
stub's call log, and a side-effect file. Five single-turn runs.

| Run | Flags | Result |
|---|---|---|
| A | `--tools "" --strict-mcp-config --mcp-config <ours> --allowedTools mcp__lh__ping` | tools = `[mcp__lh__ping]` only; server `connected`; the tool was called (stub log has the call); asked to run a shell command, the model said it had no such tool and the side-effect file was **not** created |
| B | as A without `--strict-mcp-config` (control) | same — this account has no other MCP servers, so the control proved **nothing** about strictness |
| C | as A without `--allowedTools` | model attempted the call; it was **denied** (`permission_denials: [mcp__lh__ping]`); the stub never ran |
| D | project `.mcp.json` declaring a second server, no `--strict-mcp-config` | tools = both `mcp__intruder__ping` and `mcp__lh__ping` |
| E | same `.mcp.json`, **with** `--strict-mcp-config` | tools = `[mcp__lh__ping]` only |

Findings
- **`--tools ""` removes every built-in tool**, Bash included (A). Stricter than
  `--restricted`, which per `--help` removes only the code-running tools and
  `WebFetch` and also ignores user/project/local settings files.
- **`--strict-mcp-config` isolates the session to our `--mcp-config`** (D vs E).
  Without it a repo's `.mcp.json` **adds tools to the session** — so the
  supervisor must run in a controlled working directory *and* strict.
- **An MCP tool needs an explicit allowlist to run unattended** (C): list ours in
  `--allowedTools`; in `-p` mode an unlisted call is denied. Interactively it
  would prompt a human instead (untested).
- Together: supervisor surface = exactly our tools, nothing else. This supports
  the MCP choice **for the narrow surface**, not for the protocol.

Not covered
- **Interactive (pty) mode** — flag behaviour was observed in `-p` only. The
  supervisor need not be a pty tile at all: a headless `-p` / SDK-driven process
  fits "wake on event, judge, propose" and avoids typing into a TUI.
- **The real server.** The stub proves the attach mechanism, not Lighthouse's
  tools: the real one is a separate process spawned by `claude`, so it must reach
  the app over a local channel (socket) and enforce validation there — the app,
  not the MCP process, owns the propose/confirm queue.
- Behaviour under a hostile tool result or repo content (prompt injection).
- Cost: each supervisor wake is a model call.
