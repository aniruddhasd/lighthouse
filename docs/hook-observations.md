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

## Run 4 — 2026-10-23, 09:07–09:09 (E1 build: Esc first, then answered)

Build `f32a87d` (has the `PostToolUse` hook, `error`/`tool_name` capture, state labels).

| Time | Event | Notes |
|---|---|---|
| 09:07:41 | `SessionStart` `source=resume` | |
| 09:07:53 | `UserPromptSubmit` | asked for a questionnaire |
| 09:08:02 | `PermissionRequest` (`AskUserQuestion`) | round 1 |
| 09:08:08 | `Notification` `permission_prompt` | +6 s |
| *(~09:08:1x)* | *(no hook event)* | **Esc** on round 1 |
| 09:08:17 | `UserPromptSubmit` | round 2 |
| 09:08:29 | `PermissionRequest` (`AskUserQuestion`) | |
| 09:08:35 | `Notification` `permission_prompt` | +6 s |
| 09:09:01 | **`PostToolUse` (`AskUserQuestion`)** | **answered**, 32 s after the request; keys `duration_ms`, `tool_name`, `tool_input`, `tool_response`, `tool_use_id` |
| 09:09:14 | `Stop` | turn complete |
| 09:09:16 | `SubagentStop` | next-prompt suggestion, +2 s after `Stop` |

Findings
- **E1 result: positive for the answered case** *(observed, once)*. Answering an
  `AskUserQuestion` fires `PostToolUse` with `tool_name=AskUserQuestion`, so
  "waiting on you" (`PermissionRequest`) now has a matching "unblocked"
  (`PostToolUse`) when the user answers.
- **Esc still emits nothing** *(observed, 2nd time)*: round 1 produced no
  `PostToolUse` and no `Stop`; the next event was the next prompt. This matches the
  docs ("`PostToolUse` fires after a tool *succeeds*"). A dangling
  `PermissionRequest` can still mean "interrupted"; the unblock signal covers only
  the answered case.
- **`Notification` `permission_prompt` fired ~6 s after a still-open
  `PermissionRequest` in 3 of the 4 questionnaires that stayed open at least 6 s**
  *(observed)*: run 3 round 1 and both run 4 rounds. A fifth (run 3 round 2) was
  Esc'd after ~2 s, before the 6 s mark, and got none — consistent. **The exception
  is run 2:** a questionnaire open for 51 s with no `Notification`, still
  unexplained. Treat it as a hint, never a requirement.
- **`PostToolUse` carries `duration_ms`**, which for this tool presumably includes
  the time the user took to answer *(unverified — not stored)*. Its
  `tool_response` holds the answers; never retained.
- A questionnaire turn completes normally afterwards (`Stop`, then the
  `SubagentStop` suggestion).

### Run 4 addendum — a `Stop` that is really a question (09:09:14)

The turn after the answered questionnaire ended with an ordinary `Stop`
(2,486 chars, no `agent_id`). Its opening says the agent has not written any code
and needs to check something with the user first — i.e. **it is asking, not
done**. The `SubagentStop` suggestion 2 s later (33 chars) reads like a predicted
*answer* to that, not a next task.

- **A "question" `Stop` is structurally identical to a "done" `Stop`** *(observed)*:
  same event, no `error`, no pending `PermissionRequest`/tool, nothing in the
  payload keys that differs. Only the text says the agent is waiting on the user.
  This is the case a hook-driven rule engine would get wrong, and it is why the
  done / blocked / question judgment has to read `last_assistant_message`.
- **The question may sit anywhere in a long message** — here 2,486 chars, of which
  the card shows ~3 lines. A classifier must be given the whole message (or at
  least its tail), not a preview. (The full text is in the JSONL, capped at 8,000
  chars by the parser; the tail was not examined for this record.)
- **The suggestion may track the agent's state** *(one case, inferred)*: a predicted
  answer after a question, a predicted next task after finished work. Untrusted
  model output; at most a corroborating hint.

## Still unseen / open
- `Notification` `idle_prompt` / `agent_needs_input` — not yet seen (only
  `permission_prompt`; runs 3–4).
- Why run 2's 51 s questionnaire produced no `Notification` (see run 4).
- A genuine subagent's `Stop`/`SubagentStop` (Task tool) with a non-empty
  `agent_type`.
- Esc on a questionnaire: emits **no** event (runs 3 and 4).
- Second `claude` session in another tab of a supervised tile
  (`otherSessionInTask` attribution) — not yet exercised.

## Experiments in flight

**E1 — "unblocked" signal via `PostToolUse` matched to `AskUserQuestion`.**
*Result (run 4): works for an answered questionnaire; silent on Esc.* Installed
2026-10-22 (first run on 2026-10-23, build `f32a87d`). Docs say `PostToolUse`
matches by tool name and fires after a tool succeeds; they do not say it fires for
`AskUserQuestion` — observed that it does. One observation; its payload's
`tool_response` (the answers) is never retained.
