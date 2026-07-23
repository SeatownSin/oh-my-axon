---
name: ultrawork
description: >
  Orchestrated deep work: explore -> plan -> implement -> verify using the
  oh-my-axon agents (scout, architect, executor, reviewer). Use when the user
  writes "ultrawork" or "ulw" anywhere in their message, invokes
  "/ultrawork <task>", or asks to run an existing plan file from .axon/plans/.
metadata:
  short-description: "Multi-agent explore->plan->implement->verify"
---

# /ultrawork — Orchestrated Deep Work

You are the **orchestrator**. You do not implement anything yourself — you
scope the task, drive subagents through a pipeline, persist the plan, and
verify the result. All heavy lifting happens in subagents spawned with the
`task` tool using the oh-my-axon agents: `scout`, `architect`, `executor`,
`reviewer`. Use these EXACT names — do not substitute the built-in types
`explore` or `plan`.

**Two iron rules (violating either one destroys the pipeline):**

1. **You never read whole source files and never edit files.** In every
   phase, reading and editing happen inside subagents. If you are about to
   call a file-edit tool, stop and spawn an executor instead. If you need
   to know what a file contains, a scout already told you or an executor
   will find out. Your own transcript is the scarcest resource in the run —
   every file you paste into it brings compaction closer.
2. **The saved plan file is the durable state of the run.** Save it the
   moment the architect returns, before spawning anything else. If your
   context ever gets compacted (you notice a summary replacing your
   history), do NOT re-explore: re-read the plan file from `.axon/plans/`,
   check `git status` to see which items already landed, and resume at the
   first unfinished item.

## Usage

- `/ultrawork <task>` — full pipeline on the task.
- `ultrawork` / `ulw` anywhere in a message — the rest of the message is the task.
- `/ultrawork plan <task>` — run only Phases 1–2, save the plan, stop.
- `/ultrawork run <path-to-plan.md>` — skip to Phase 3 with an existing plan.

## Phase 0 — Scope (you, no subagents)

Restate the task in one or two sentences. Then pick a scale:

- **small** — one obvious file/change, no design choices: skip Phases 1–2
  and hand the whole task to a single executor as one work item (you still
  do not edit anything yourself), then run Phase 4 with a reviewer.
- **normal** — everything else: run the full pipeline.

If the task is ambiguous in a way that changes what you'd build (not how),
ask the user now. Otherwise never stop mid-pipeline to ask.

## Phase 1 — Explore

Spawn **one** scout (two in parallel with `run_in_background: true` only
if the task clearly spans two unrelated areas — never more than two):

- `subagent_type`: `"scout"`
- `description`: `"Recon: <topic>"`
- `prompt`: the full task statement, verbatim, plus any file paths or error
  messages the user supplied. The scout sees nothing from this
  conversation — the prompt must be self-contained.

Wait for completion (`wait_tasks` with `mode: "wait_all"` if backgrounded).

## Phase 2 — Plan

Spawn one architect:

- `subagent_type`: `"architect"`
- `description`: `"Plan: <topic>"`
- `prompt`: the task statement + the scout report(s), pasted in full.

Save the returned plan to `.axon/plans/<yyyy-mm-dd>-<slug>.md` in the repo
**immediately — this is not optional and not deferrable** (create the
directory if needed; get the date from the system, e.g. `date +%F`; writing
this one file is the single exception to iron rule 1). Tell the user the
path. From here on the plan file, not your memory, is the source of truth.

If the plan has a `## Needs decision` section, surface it to the user before
implementing — with the architect's recommended default so they can just say
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
- But paste only what they need: the scout gets the task, not your
  musings; an executor gets its one item, not the whole plan.
- Cap concurrency at 2 subagents. Sequential is the default, not a fallback.
- If a subagent returns garbage or ignores its output format, respawn it
  once with a sharper, shorter prompt. If it fails twice, simplify the work
  item (split it, or reduce it to the smallest change that satisfies its
  acceptance) and try one final executor — never absorb the work into your
  own session.
- Watch your own context. Skim subagent reports, keep only their headline
  facts in play, and lean on the plan file instead of re-pasting earlier
  phases. An orchestrator that triggers compaction has already failed —
  the run only survives it because the plan file is on disk.
