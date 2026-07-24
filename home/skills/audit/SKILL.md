---
name: audit
description: >
  Whole-codebase standing health check. Fans out read-only agents across
  independent dimensions (security, secrets, dependencies, dead code,
  error handling, tests, licensing), collects and dedupes findings, and
  writes a prioritized report to .axon/audits/. Read-only — never edits.
  Use on "/audit", "audit the codebase", "health check", "what's wrong
  with this repo". For reviewing PENDING CHANGES use /code-review instead.
metadata:
  short-description: "Multi-dimension read-only codebase audit"
---

# /audit — Whole-Codebase Health Check

You are the **coordinator**. You do not read the whole codebase yourself or
fix anything — you scope the audit, fan out read-only agents across
independent dimensions, merge their findings, and write one prioritized
report. `/audit` assesses the repo AS IT STANDS; it is not a diff review
(that is `/code-review`) and it changes nothing.

## Usage

- `/audit` — full audit across the default dimensions below.
- `/audit <dimension...>` — only the named dimensions (e.g. `/audit
  security secrets`).
- `/audit <path>` — restrict the audit to a subtree.

## Phase 0 — Scope (you)

State what is being audited (whole repo or a subtree) and which dimensions
will run. Note the stack (language, package manager, test layout) from a
quick look at the root — each dimension agent gets this so it uses the
right tools.

## Dimensions (default set — drop any that don't apply to the stack)

Each is one independent, read-only job:

1. **security** — injection, unsafe deserialization, path traversal,
   command execution from untrusted input, authz gaps, unsafe defaults.
2. **secrets** — committed credentials, keys, tokens, private key blocks,
   `.env` files in git, hardcoded connection strings.
3. **dependencies** — outdated/abandoned deps, known-vuln versions (from
   the lockfile), duplicate or unused declared dependencies.
4. **dead-code** — unreferenced files, exports nobody imports, unreachable
   branches, commented-out blocks, feature flags long since defaulted.
5. **error-handling** — swallowed errors, unwrap/panic on external input,
   missing timeouts on I/O, unhandled rejection/exception paths.
6. **tests** — modules with no tests, assertions that can't fail, skipped
   tests, coverage gaps on the riskiest code paths.
7. **licensing** — dependency licenses incompatible with the project's,
   missing license headers where the project requires them.

## Phase 1 — Fan out

Spawn one **reviewer** per dimension (reviewer = read + run commands, cannot
edit):

- `subagent_type`: `"reviewer"`
- `persona`: `"thorough"`
- `description`: `"Audit: <dimension>"`
- `prompt`: self-contained — the dimension's definition above, the audit
  scope (repo root or subtree), the detected stack, and this instruction:
  "Report ONLY confirmed findings, each with `file:line`, a severity
  (critical/high/medium/low), and a one-line concrete impact. No stylistic
  nits. If the dimension is clean, say so explicitly."

**Bound the fan-out to your model class** (see the distribution's model-class
profiles): frontier-local models may run 2–3 dimensions in parallel with
`run_in_background: true`; smaller models run strictly one at a time. Never
exceed 3 concurrent. Run the rest sequentially as slots free.

## Phase 2 — Merge

Collect every dimension's findings. Then, yourself:

- **Dedupe**: the same file:line surfaced by two dimensions is one finding
  with both tags.
- **Rank**: severity first, then blast radius. A critical in a hot path
  outranks a critical in a test fixture.
- **Sanity-check**: drop any finding whose `file:line` you can't confirm is
  real (spot-read the cited location if a claim looks surprising). A
  hallucinated critical is worse than a missed low.

## Phase 3 — Report

Write `<repo>/.axon/audits/<yyyy-mm-dd>-<slug>.md` (create the dir; date
from the system). Structure:

```
# Audit: <scope>
Date: <yyyy-mm-dd>   Commit: <short-sha>   Dimensions: <list run>

## Summary
- <n> findings: <c> critical, <h> high, <m> medium, <l> low.
- One-paragraph headline: the single most important thing to fix.

## Findings
### [CRITICAL] <title>  (dimension)
- Where: file:line
- Impact: the concrete failure this causes
- Fix: the direction (not a full patch — this is read-only)

### [HIGH] ...

## Clean
- dimensions that came back with nothing — name them, so silence reads as
  "checked and clear", not "not looked at"

## Not covered
- anything skipped and why (dimension N/A to the stack, subtree excluded,
  a check that needs a tool not installed)
```

Tell the user the path and read them the Summary. **Never auto-fix.** If they
want fixes, hand specific findings to `/ultrawork` or an executor afterward.

## Rules

- Read-only, always. The audit and every agent it spawns only observe.
- Confirmed findings only — every one carries a real `file:line`. "Might be"
  is not a finding; investigate it into a yes or drop it.
- Name what was checked and clean as loudly as what was broken — an audit's
  value is the coverage guarantee, and silent gaps destroy it.
- Scale the dimension set and fan-out to the codebase and the model; a
  three-file repo does not need seven parallel agents.
