---
name: handoff
description: >
  Session-to-session memory: save a durable handoff file capturing the
  session's working state (goal, verified state, decisions, dead ends, next
  steps) to .axon/handoffs/, or resume from one. Use on "/handoff",
  "save a handoff", "write up where we are" — and for resuming:
  "/handoff resume", "pick up where we left off", "continue from the
  handoff".
metadata:
  short-description: "Save/resume working state across sessions"
---

# /handoff — Session-to-Session Memory

A handoff is a file a FUTURE session (or teammate) reads with zero context
from this one. Plans (`.axon/plans/`) say what to build; handoffs say where
work actually stands.

## Modes

- `/handoff [topic]` — save/update the handoff for this session's work.
- `/handoff resume [topic]` — load the newest (or named) handoff, verify
  it against reality, continue.
- `/handoff list` — list existing handoffs with their Updated dates.

## Saving

1. Pick the topic slug (from the argument, or the session's main task).
2. Path: `<repo>/.axon/handoffs/<slug>.md` — or `~/.axon/handoffs/<slug>.md`
   when there is no repo. **One file per topic, rewritten in place**:
   supersede stale content, never append a running log. Old handoffs for
   finished work get deleted, not kept.
3. **Verify before writing.** Run `git status`, `git log --oneline -3`, and
   the project's check command if cheap — the State section records what you
   just confirmed, not what you remember. Anything not re-verified this
   session is labeled `(unverified)`.
4. Write exactly this structure:

```
# Handoff: <topic>
Updated: <yyyy-mm-dd from the system>   Branch: <branch> @ <short-sha>

## Goal
What is being built/done and why — 2-3 sentences a stranger can act on.

## State
- DONE: item — evidence (test/command output, commit sha)
- IN PROGRESS: item — exactly where it stands
- BLOCKED: item — on what, precisely

## Verified facts
- fact — file:line or the command that proved it (mark `(unverified)` otherwise)

## Decisions
- choice — the why, in one line, so it is not relitigated

## Dead ends
- what was tried — why it failed (this section saves the most time; never omit it)

## Next steps
1. Ordered and concrete; step 1 must be executable immediately.

## Gotchas
- environment quirks, required flags, footguns hit this session
```

5. Rules: under ~80 lines; no transcripts or narration; **never secrets** —
   write where a credential lives ("api_key in ~/.axon/config.toml
   [model.x]"), never its value. Tell the user the saved path.

## Resuming

1. Find the handoff (`ls .axon/handoffs/` then `~/.axon/handoffs/`); use
   the named topic or the newest `Updated:` line.
2. Read it fully. Then **verify its State against reality** — the handoff
   records what WAS true: run `git status`/`git log` and compare against
   `Branch @ sha`; spot-check one or two Verified facts; confirm endpoints
   or services it depends on still respond.
3. Report divergences to the user in one short list ("since the handoff:
   branch moved to X, file Y changed").
4. Continue from the first unfinished Next step. Do not redo DONE items —
   trust the evidence, not your instinct to re-explore.
5. When the work advances materially, update the handoff (mode: save).

## When to suggest a handoff unprompted

At the natural end of a work session — a feature merged, a long run
finished, a blocker hit that needs the user — offer once: "want me to
save a handoff?" Never write one without being asked.
