---
name: plan
description: >
  Interactive planning session: interview the user, recon the codebase with
  an explorer subagent, and save a reviewed work plan to .axon/plans/ without
  implementing anything. Use on "/plan <task>" or when the user asks to
  "plan this out" / "make a plan" without wanting changes yet.
metadata:
  short-description: "Interview -> recon -> saved plan (no implementation)"
---

# /plan — Plan Without Implementing

Produce a plan the user can execute later (typically with
`/ultrawork run <plan-file>`). **Make no code changes in this mode.**

## Steps

1. **Interview (brief).** If the task leaves real choices open — scope,
   approach, what "done" means — ask the user now, in one batch of at most
   3 questions. If it's already concrete, skip straight to recon.

2. **Recon.** Spawn one explorer via the `task` tool:
   - `subagent_type`: `"explorer"`
   - `description`: `"Recon: <topic>"`
   - `prompt`: the task + the user's interview answers, self-contained.

3. **Draft.** Spawn one planner:
   - `subagent_type`: `"planner"`
   - `description`: `"Plan: <topic>"`
   - `prompt`: task + interview answers + full explorer report.

4. **Sanity-check the draft yourself** against the explorer report: every
   file path in the plan must appear in the report or be one you verified
   exists. Kick clearly broken items back to the planner once with a note.

5. **Save** to `.axon/plans/<yyyy-mm-dd>-<slug>.md` (create the directory if
   needed; get the date from the system, e.g. `date +%F`).

6. **Present** to the user: the plan's goal, its work-item titles, any
   `## Needs decision` section, and the saved path. Close with:
   run it later with `/ultrawork run <path>`.
