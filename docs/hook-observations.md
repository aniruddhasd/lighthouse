# Hook observations — orchestrator phase 1a evidence log

What the supervised-task hook stream actually did, recorded as observed. This is
the **evidence** file: `docs/orchestrator-design.md` holds the decisions and
`docs/claude-code-contract.md` the CLI facts; this one holds dated runs so a
claim can be traced to a run. Add new runs at the bottom; don't rewrite old ones.

**Method.** One real task (`debug-fetch-metrics`, an in-place workspace) with
supervision on; the user worked normally. Events come from the app's JSONL
(`~/Library/Application Support/Lighthouse/hook-events.jsonl`, metadata only) and,
where a cause had to be established, **structure-only** reads of the session
transcript (entry types / tool names / timestamps — no message text).
Timestamps are local time (the JSONL is UTC). CLI **2.1.308**. Message text,
prompts, tool inputs and answers are deliberately not reproduced here.

**Caveat on strength.** One task, one user, one afternoon. Findings marked
*(observed)* happened; *(inferred)* are conclusions from content; *(unverified)*
are open.

## Run 1 — 2026-10-22, 17:02–17:12 (first interactive turns)

| Time | Event | Notes |
|---|---|---|
| 17:02:54 | `UserPromptSubmit` | hooks had been written to the running session at 17:01:44 |
| 17:03:08 | `Stop` | full reply (1,799 chars), no `agent_id` |
| 17:03:10 | `SubagentStop` | 31 chars; next-prompt suggestion |
| 17:06:11 | `SubagentStop` | 256 chars; recap-like *(inferred)* |
| 17:09:59 | `SessionEnd` `reason=prompt_input_exit` | user exited |
| 17:10:26 | `SessionStart` `source=resume` | same `session_id` as before exit |

Findings
- **Mid-session pickup** *(observed, once)*: hooks written while the session ran
  were honored from the next event; only the already-passed `SessionStart` was
  missed. Earlier "mid-session pickup" conclusions were briefly confused by
  looking at the wrong task (`review`); the file mtimes of the *correct* task
  (api, 17:01:44) match the toggle time.
- **Resume reuses `session_id`** *(observed, 3 resumes)*; every event
  attributed `primary`.
- **`SubagentStop` after `Stop` is the next-prompt placeholder** *(user-confirmed,
  3 turns)*: ~2 s after `Stop`, `agent_id` set, `agent_type` present but empty,
  no `SubagentStart`. Only a `Stop` without `agent_id` is a turn boundary.

## Run 2 — 2026-10-22, 17:36–17:53 (failure, question, mid-turn message)

| Time | Event | Notes |
|---|---|---|
| 17:36:08 | `SessionStart` `source=resume` | extra keys: `context_tokens`, `seconds_since_last_response`, `prompt_cache_likely_expired`, `estimated_cache_write_usd`, `session_title` |
| 17:43:45 | `UserPromptSubmit` | |
| 17:46:34 | **`StopFailure`** | no network; message text + a separate structured `error` key |
| 17:47:57 | `UserPromptSubmit` | user retried |
| 17:49:28 | `Stop` | 6,379 chars |
| 17:49:45 | `UserPromptSubmit` | user asked for a questionnaire |
| 17:49:58 | **`PermissionRequest`** | keys `tool_name`, `tool_input`; transcript shows an `AskUserQuestion` tool call this second |
| 17:50:49 | *(no hook event)* | questionnaire answered — transcript shows the answer as a `tool_result` |
| 17:51:34 | `UserPromptSubmit` | user's message sent **while the agent was still working** |
| 17:53:02 | `Stop` | one `Stop` for the whole span |
| 17:53:04 | `SubagentStop` | next-prompt suggestion again |

Findings
- **Failure is structural** *(observed)*: an API/network failure ends the turn with
  `StopFailure`, not `Stop`; the supervisor needn't read prose to know a turn
  failed. The "VPN is down" case is therefore distinguishable from "done" without
  an LLM.
- **Hook timestamps match the terminal's own timers** *(observed)*: 17:43:45→17:46:34
  = 2m49s ("Cooked for 2m 49s"); 17:47:57→17:49:28 = 1m31s ("Worked for 1m 31s").
- **A question waiting on the user is a `PermissionRequest`** *(observed)*, raised
  the same second as the `AskUserQuestion` tool call, with no `Stop` while it waits.
- **Answering the questionnaire emits no hook event** *(observed)* in the installed
  set. "Waiting on you" starts with a `PermissionRequest` and ends silently.
- **A message sent mid-turn fires `UserPromptSubmit` at enqueue time** and gets no
  `Stop` of its own *(observed)*: transcript shows a queue enqueue at 17:51:34,
  consumed 2 s later by the running turn. Two `UserPromptSubmit` + one `Stop`
  between 17:49:45 and 17:53:02. **Prompts and stops do not pair one-to-one.**

## Run 3 — 2026-10-23, 08:32–08:55 (second questionnaire, mid-turn message, Esc)

**E1 was NOT exercised in this run.** The app was still the build from the previous
evening (it predates the `PostToolUse` hook and the new labels), and the task's
`.claude/settings.local.json` lists no `PostToolUse` entry. Do not read anything
below as an E1 result.

| Time | Event | Notes |
|---|---|---|
| 08:32:33 | `SessionEnd` `reason` | user exited |
| 08:32:44 | `SessionStart` `source` | resume; again 08:32:55 `SessionEnd` |
| 08:49:19 | `UserPromptSubmit` | user asked for a questionnaire |
| 08:49:31 | `PermissionRequest` | transcript: `AskUserQuestion` tool call, same second |
| 08:49:37 | **`Notification` `permission_prompt`** | **first `Notification` ever seen**; +6 s after the request; payload keys `message`, `notification_type` |
| 08:52:46 | *(no hook event)* | questionnaire answered (transcript `tool_result`), 3m15s after it appeared |
| 08:55:16 | `UserPromptSubmit` | user asked again **mid-turn**; transcript queue enqueue 08:55:16, consumed 08:55:19 |
| 08:55:28 | `PermissionRequest` | second questionnaire (`AskUserQuestion`) |
| 08:55:30 | *(no hook event)* | user pressed **Esc**: transcript shows the tool result as an error, a short user text entry, and a `system` entry with subtype `turn_duration` |
| after | *(no hook event)* | **no `Stop`, no `StopFailure`, no `SessionEnd`, no `Notification`** |

Findings
- **Interrupting a turn (Esc) emits no hook event** *(observed, once)*. A
  `PermissionRequest` with nothing after it is therefore ambiguous: still waiting,
  or interrupted. A supervisor that waits for a `Stop` would wait forever. The
  transcript did record the end (`system` / `turn_duration`) at the moment of the
  interrupt, so a transcript tail is a possible fallback signal *(inferred from one
  case)*; so is pty/session liveness plus an idle timeout.
- **`Notification` appears — but not reliably** *(observed)*: `permission_prompt`
  came 6 s after this questionnaire, whereas none came in the 51 s the questionnaire
  waited in run 2. What differs is unknown *(unverified)*; terminal focus / user
  presence is one untested possibility. Do not build a "waiting on you" detector
  that requires it.
- **Mid-turn message behaves the same as run 2** *(observed, 2nd time)*:
  `UserPromptSubmit` fires at enqueue, the turn picks it up ~3 s later, no extra
  `Stop`. The earlier finding now rests on two cases.
- **Answering emits no event** *(observed, 2nd time)* — still true without E1.
- A turn can run for minutes with no `Stop`: 08:49:19 → 08:55:30 here.

## Still unseen / open
- `Notification` `idle_prompt` / `agent_needs_input` — not yet seen (only
  `permission_prompt`, once; see run 3).
- A plain-text question at the end of an ordinary `Stop` (no tool involved).
- A genuine subagent's `Stop`/`SubagentStop` (Task tool) with a non-empty
  `agent_type`.
- Esc on a questionnaire: now seen (run 3) — it emits **no** event. Whether
  `PostToolUse` fires on a *successful* answer is still E1.
- Second `claude` session in another tab of a supervised tile
  (`otherSessionInTask` attribution) — not yet exercised.

## Experiments in flight

**E1 — "unblocked" signal via `PostToolUse` matched to `AskUserQuestion`.**
Installed 2026-10-22 (after run 2). Question: does answering a questionnaire fire
`PostToolUse` with `tool_name=AskUserQuestion`? Docs say `PostToolUse` matches by
tool name and fires after a tool completes successfully; they do **not** say it
fires for `AskUserQuestion`. Its payload carries `tool_response` (the user's
answers) — the parser never retains it. *Result: **not yet run** (run 3 used the pre-E1 build; no `PostToolUse` hook was
installed). Re-run after relaunching on the new build; a cancelled (Esc) questionnaire
is already known to emit nothing.*
