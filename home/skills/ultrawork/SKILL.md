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
3. **Never end your turn between phases.** Announcing a phase and stopping
   is a failed run: every phase announcement must be followed immediately,
   in the same turn, by that phase's tool calls. You end your turn exactly
   once — after the final report.

## Usage

- `/ultrawork <task>` — full pipeline on the task.
- `ultrawork` / `ulw` anywhere in a message — the rest of the message is the task.
- `/ultrawork plan <task>` — run only Phases 1–2, save the plan, stop.
- `/ultrawork run <path-to-plan.md>` — skip to Phase 3 with an existing plan.
- `--handoff=file` anywhere in the invocation, or the line `handoff: file` in
  the task statement, switches every handoff to files (see Handoff mode).

## Handoff mode

Subagents share no memory, so each phase's output has to reach the next one.

- **`paste` (default):** you paste reports and work items into the next
  subagent's prompt, and you type the architect's plan into the plan file.
- **`file`:** subagents' outputs go to disk with a script, and the next
  subagent is given **paths**. Nothing long passes through your own replies.

**Why `file` exists:** every token you paste or type is a token you
*generate*. On a local model that costs minutes per handoff. Worse, a long
scout report or plan can push one of your replies past the server's
per-reply output cap. Axon reports that as `max_tokens_truncation`, and if it
happens in your own turn the whole run ends. Use `file` for local models, for
long tasks, and whenever a run has already died that way.

**The tool:** `scripts/save_subagent_report.py`, next to this SKILL.md.

    python3 <this skill's directory>/scripts/save_subagent_report.py <subagent_id> <out.md>

- Use `python` if that is the interpreter's name on this machine.
- It copies the subagent's **final message** verbatim from its session
  transcript on disk and prints one line: `OK: <n> lines …` or `ERROR: …`.
- Running it is allowed under iron rule 1. It neither reads source nor edits
  it, and the plan file it writes is the rule's existing exception.

**What changes in `file` mode** (everything else in the pipeline stays the
same):

- **Phase 1:** when the scout finishes, save its report to
  `.axon/findings/<yyyy-mm-dd>-<slug>-scout.md`. Don't keep the report in
  your context. If the task already names a saved recon file, skip the scout.
- **Phase 2:**
  - The architect's prompt is the task statement (or the task file's path)
    plus the scout report's **path**.
  - Tell the architect its final message is saved verbatim as the plan. So it
    must be only the plan markdown: no preamble, no code fences, no closing
    summary. Ask for a compact plan, roughly 12 items or fewer and 15 lines or
    fewer per item.
  - Save it with the tool to `.axon/plans/<yyyy-mm-dd>-<slug>.md`, instead of
    typing it. Then read only its headings (e.g. `Select-String '^#'` or
    `grep '^#'`) to learn the item list.
- **Phase 3:** each executor's prompt is the plan **path** and its item
  number, plus the global-context line and the findings-file line. The
  executor reads its own item from the plan.
- **Phase 4:** the reviewer gets the plan path instead of its contents.
- **If the tool prints `ERROR`:** the subagent left no final text, so treat it
  as a failed subagent (respawn rules below). Never type the missing report
  yourself.

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
  (`file` mode: the report's path instead, and see Handoff mode for how the
  plan comes back.)

Save the returned plan to `.axon/plans/<yyyy-mm-dd>-<slug>.md` in the repo
**immediately — this is not optional and not deferrable** (create the
directory if needed; get the date from the system, e.g. `date +%F`; writing
this one file is the single exception to iron rule 1). Tell the user the
path. From here on the plan file, not your memory, is the source of truth.

Then create an empty findings file next to it,
`.axon/findings/<yyyy-mm-dd>-<slug>.md`, with this header and nothing else:

    # Findings - <slug>
    One line per established fact. A fact with no evidence command is
    inadmissible. Keep to ~40 lines; overflow means the plan is too big.

    | fact | evidence command | item |
    |---|---|---|

**This file exists because subagents share no memory.** An executor sees only
its own work item, so a fact item 3 proves is invisible to item 7 unless
something carries it. Executors read and append to this file themselves --
you never relay findings through your own context.

If the plan has a `## Needs decision` section, do NOT stop: state the
question and the architect's recommended default in one sentence, adopt the
default, record it in the saved plan file, and continue straight into
Phase 3 in the same turn. The user reads it in your final report and can
ask for a change afterward. (Only exception: the choice changes WHAT is
being built rather than how — that should have been caught in Phase 0.)

## Phase 3 — Implement

Work through the plan's work items with executors:

- `subagent_type`: `"executor"`
- `description`: `"Item <n>: <item title>"`
- `prompt`: the **entire work item** (title, files, steps, acceptance)
  pasted verbatim, plus one line of global context ("This is item <n> of
  <total> of a plan to <goal>."), plus one line naming the run's findings
  file ("Read <path> before you start; append what you establish before you
  finish."). Nothing else - executors must not receive the whole plan.
  (`file` mode: the plan path and the item number instead of the pasted item.)

  That one line is the whole cross-item channel. The executor does the
  reading and appending itself, so this costs you no context and you never
  become a relay. Naming the file is not optional: without it the item
  cannot see anything an earlier item proved, and will correctly but
  wastefully report as unverifiable a fact the run already established.

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
- `prompt`: the plan file contents (`file` mode: its path) + the list of files changed (from
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

## Context and delegation rules

These defaults are safe for every model class. With a frontier-class local
model (100B+, 100k+ real context) you may parallelize independent
executors (worktree isolation, still max 2–3) and pass fuller reports
between phases; with small models (≤14B), tighten instead — smallest
possible prompts, never parallel.

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
- A subagent or your own turn failing with `max_tokens_truncation` means a
  reply outgrew the server's per-reply output cap. A sharper prompt rarely
  fixes it. Switch to `file` handoff mode, and tell the user the cap may need
  raising (`max_completion_tokens` on the model in `config.toml`; some
  servers default to 8192 when it is unset).
- Watch your own context. Skim subagent reports, keep only their headline
  facts in play, and lean on the plan file instead of re-pasting earlier
  phases. An orchestrator that triggers compaction has already failed —
  the run only survives it because the plan file is on disk.
