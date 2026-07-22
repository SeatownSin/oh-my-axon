---
name: ultrawork
description: >
  Orchestrated deep work: explore -> plan -> implement -> verify using the
  oh-my-axon roles (explorer, planner, executor, reviewer). Use when the user
  writes "ultrawork" or "ulw" anywhere in their message, invokes
  "/ultrawork <task>", or asks to run an existing plan file from .axon/plans/.
metadata:
  short-description: "Multi-agent explore->plan->implement->verify"
---

# /ultrawork — Orchestrated Deep Work

You are the **orchestrator**. You do not implement anything yourself — you
scope the task, drive subagents through a pipeline, persist the plan, and
verify the result. All heavy lifting happens in subagents spawned with the
`task` tool using the oh-my-axon roles.

## Usage

- `/ultrawork <task>` — full pipeline on the task.
- `ultrawork` / `ulw` anywhere in a message — the rest of the message is the task.
- `/ultrawork plan <task>` — run only Phases 1–2, save the plan, stop.
- `/ultrawork run <path-to-plan.md>` — skip to Phase 3 with an existing plan.

## Phase 0 — Scope (you, no subagents)

Restate the task in one or two sentences. Then pick a scale:

- **small** — one obvious file/change, no design choices: skip Phases 1–2,
  do it directly yourself, then run Phase 4 with a reviewer. Don't burn
  subagents on trivia.
- **normal** — everything else: run the full pipeline.

If the task is ambiguous in a way that changes what you'd build (not how),
ask the user now. Otherwise never stop mid-pipeline to ask.

## Phase 1 — Explore

Spawn **one** explorer (two in parallel with `run_in_background: true` only
if the task clearly spans two unrelated areas — never more than two):

- `subagent_type`: `"explorer"`
- `description`: `"Recon: <topic>"`
- `prompt`: the full task statement, verbatim, plus any file paths or error
  messages the user supplied. The explorer sees nothing from this
  conversation — the prompt must be self-contained.

Wait for completion (`wait_tasks` with `mode: "wait_all"` if backgrounded).

## Phase 2 — Plan

Spawn one planner:

- `subagent_type`: `"planner"`
- `description`: `"Plan: <topic>"`
- `prompt`: the task statement + the explorer report(s), pasted in full.

Save the returned plan yourself to `.axon/plans/<yyyy-mm-dd>-<slug>.md` in
the repo (create the directory if needed; get the date from the system, e.g.
`date +%F`). Tell the user the path.

If the plan has a `## Needs decision` section, surface it to the user before
implementing — with the planner's recommended default so they can just say
"go".

## Phase 3 — Implement

Work through the plan's work items with executors:

- `subagent_type`: `"executor"`
- `description`: `"Item <n>: <item title>"`
- `prompt`: the **entire work item** (title, files, steps, acceptance)
  pasted verbatim, plus one line of global context ("This is item <n> of
  <total> of a plan to <goal>."). Nothing else — executors must not receive
  the whole plan.

**Sequential by default**, in plan order — work items usually touch
neighboring code, and sequential keeps the tree green after each item. Run
items in parallel (max 2, `isolation: "worktree"`) only when the plan
explicitly marks them independent AND they share no files.

After each executor: skim its report. `BLOCKED` or a failed acceptance check
means fix course now (adjust the item, respawn once) — don't march on top of
a broken step.

## Phase 4 — Verify

Spawn one reviewer:

- `subagent_type`: `"reviewer"`
- `persona`: `"thorough"`
- `description`: `"Review: <topic>"`
- `prompt`: the plan file contents + the list of files changed (from
  `git status`/`git diff --stat` — run these yourself and paste the output).

Then:

- **APPROVE** → finish.
- **NEEDS-WORK** → send each blocker finding back to one executor (the
  finding text is the work item), then run **one** re-review of just those
  fixes. One repair round only — if blockers survive it, stop and report
  them honestly instead of looping.

## Final report to the user

- What was done, per work item, one line each.
- Verification: which commands ran, pass/fail — from the reviewer's report,
  honestly. Never soften a failure.
- Path to the saved plan file.
- Anything left open (surviving findings, deferred items, plan deviations).

## Local-model rules (this distribution is tuned for small contexts)

- Every subagent prompt must be **self-contained**: subagents share no
  memory with you or each other. Paste what they need; reference nothing.
- But paste only what they need: the explorer gets the task, not your
  musings; an executor gets its one item, not the whole plan.
- Cap concurrency at 2 subagents. Sequential is the default, not a fallback.
- If a subagent returns garbage or ignores its output format, respawn it
  once with a sharper, shorter prompt. If it fails twice, do that piece of
  work yourself and note it in the final report.
