# oh-my-axon

Batteries-included, **privacy-first**, local-model-tuned distribution for the
[Axon](https://github.com/SeatownSin/axon) agent harness — what oh-my-zsh is
to zsh. One install turns bare Axon into an opinionated multi-agent setup
that never phones home and is tuned for the models running on your own box.

Not a fork: everything here is plain config, prompts, skills, and hooks that
drop into `~/.axon/`, built on Axon's native extension surface.

## What you get

| Piece | Where it lands | What it does |
|---|---|---|
| **5 subagents** | `~/.axon/agents/` | `scout` (read-only recon), `architect` (read-only planning), `executor` (implements one work item), `reviewer` (runs checks, can't edit), `looker` (vision: reads screenshots/mockups/diagrams, transcribes visible text verbatim) — each with a tuned prompt and least-privilege capability mode, named to never collide with the built-in `explore`/`plan` types. `looker` spawns on the model named `vision`: add a `[model.vision]` entry pointing at any multimodal endpoint |
| **2 personas** | `~/.axon/personas/` | `concise` (small-context-friendly output), `thorough` (skeptical verification passes) |
| **`/ultrawork` skill** | `~/.axon/skills/ultrawork/` | The headline: say `ultrawork` (or `ulw`, or `/ultrawork <task>`) and Axon orchestrates explore → plan → implement → verify across the agents, persisting the plan to `.axon/plans/` in your repo |
| **`/plan` skill** | `~/.axon/skills/plan/` | Interview → recon → saved plan, no implementation; run it later with `/ultrawork run <plan-file>` |
| **`/handoff` skill** | `~/.axon/skills/handoff/` | Session-to-session memory: save verified working state (goal, state with evidence, decisions, dead ends, next steps) to `.axon/handoffs/`; `/handoff resume` verifies it against reality and continues |
| **`/audit` skill** | `~/.axon/skills/audit/` | Whole-codebase health check: fans out read-only agents across dimensions (security, secrets, deps, dead code, error handling, tests, licensing), dedupes and ranks findings, writes a prioritized report to `.axon/audits/`. Never edits — hand fixes to `/ultrawork` after |
| **secret-scan hook** | `~/.axon/hooks/` | PreToolUse gate that blocks edits/commands containing things that look like real credentials (AWS/GitHub/Slack/OpenAI/Anthropic/Google/Stripe keys, private key blocks). 100% local |
| **format-on-edit hook** (opt-in) | `~/.axon/hooks/` | PostToolUse hook that auto-formats an edited file with the project's own formatter (rustfmt / prettier / black, detected by config file). Never blocks an edit; installed only with `--with-format-hook` / `-WithFormatHook` |
| **subagent telemetry hook** (opt-in) | `~/.axon/hooks/` | SubagentStop hook that appends one line per finished subagent to `~/.axon/telemetry/subagents.jsonl` — role, model, exit status, duration, context used, turns, tool calls. Never blocks, never leaves your machine, records no prompt text; installed only with `--with-telemetry` / `-WithTelemetry` |
| **Subagent report** | stays in this repo | `tools/subagents.sh` / `.ps1` — turns that log into per-role measurements: which roles fail, how long they take, and how close each one came to filling its model's context window |
| **Model config reference** | stays in this repo | `config/config.toml.snippet` — LM Studio / Ollama / LAN-server blocks with the context-window gotchas spelled out |
| **Fleet doctor** | stays in this repo | `tools/doctor.sh` / `.ps1` — checks that the models your config names are actually up, serving what you think, and honest about their context window. Exits non-zero when a role's model is broken |
| **Role preset generator** | stays in this repo | `tools/gen-roles.sh` / `.ps1` — reads the models you already have and prints a `[models]` + `[subagents.models]` block wiring each agent to a sensible one. Prints only; never writes your config |

## Install

Requires an Axon install (v0.3.0+). Clone and run the installer for your
platform:

```sh
# Linux / WSL / macOS
git clone https://github.com/SeatownSin/oh-my-axon
cd oh-my-axon && ./install.sh
```

```powershell
# Windows
git clone https://github.com/SeatownSin/oh-my-axon
cd oh-my-axon; .\install.ps1
```

The installer copies files into `$AXON_HOME` (default `~/.axon`), backs up
anything it would overwrite, records a manifest, and **never touches your
`config.toml`**. Preview everything it would do without writing a byte via
`./install.sh --dry-run` / `.\install.ps1 -DryRun`. Add the opt-in
auto-format hook with `--with-format-hook` / `-WithFormatHook`. Uninstall
cleanly with `./install.sh --uninstall` / `.\install.ps1 -Uninstall`.
`--help` / `-Help` lists every flag, and an unrecognised one is refused
rather than ignored — so a typo in `--dry-run` cannot install for real.

Windows and WSL are separate installs (separate home dirs) — run the
installer in each environment you use Axon from.

## Use

```
/ultrawork add retry with backoff to the sync client   # full pipeline
ulw fix the flaky watcher test                         # same, inline trigger
/plan migrate the config loader to toml v2             # plan only
/ultrawork run .axon/plans/2026-07-22-config-loader.md # execute a saved plan
```

The agents are also usable directly from any session via the task tool
(`subagent_type: "scout"`, persona `"concise"`, etc.) — `/ultrawork` is
just the curated way to drive them.

## Wire the agents to your models

With more than one server running, the agents should not all share one model:
`executor` and `reviewer` want your strongest model, `scout` and the session
housekeeping want your fastest. The generator reads the catalog you already
have and prints that mapping:

```sh
tools/gen-roles.sh              # read ~/.axon/config.toml
tools/gen-roles.sh --probe      # ask those servers what they are actually serving
```

```powershell
.\tools\gen-roles.ps1
.\tools\gen-roles.ps1 -Probe
```

It writes nothing — review the block and paste what you want into
`~/.axon/config.toml`. Three things worth knowing about the output:

- **Sizes are read from model names**, not measured. A model whose name
  carries no parameter count sorts last rather than winning the "biggest"
  slot by accident, and if nothing looks smaller than anything else it says
  so instead of inventing a split.
- **Off-box models are skipped by default** and listed under a "skipped"
  heading. A role quietly pointed at a hosted endpoint would send your code
  off your machine, which is the one thing this distribution promises not to
  do. `--include-remote` / `-IncludeRemote` overrides that if you mean it.
- **`--probe` contacts the endpoints your config already names** — it does not
  guess ports. Guessing misses an LM Studio server on a high port and every
  model served from another box, which between them cover most real setups.
  Finding servers you have *not* configured yet is the first-run wizard's job
  (`axon`), which sweeps the LAN too.

The probe answers the question the name heuristic cannot — whether the models
you configured are there at all:

```
# Probe -- what your configured endpoints are serving right now:
#   DOWN   little -- http://127.0.0.1:49152/v1 (no answer)
#   STALE  nemotron -- http://gata.local:8000/v1 (up, but serving laguna -- not "nemotron")
#   UP     laguna -- http://gata.local:8000/v1
#   SKIP   gemma-cloud -- off-box, not contacted
#
# Problems:
#   little is assigned below (session_summary, prompt_suggestion, web_search, scout)
#   but is not usable right now.
```

`STALE` is the one worth knowing: the server is up, but serving something else
— the usual cause is two models configured against one endpoint that only runs
one at a time. It also compares the `context_window` you configured against
what the server reports, which is the only mechanical check on the
misconfiguration described below.

Two deliberate limits. Probing **never changes the assignments** — those come
from your config alone, so a server that happens to be down cannot silently
rewrite your mapping; it gets reported instead. And off-box endpoints are not
contacted at all without `--include-remote`, for the same reason they are not
assigned.

`--probe` exists to sanity-check a block you are about to paste. For a
standalone health check with exit codes, role attribution and context
comparison, use [the doctor](#check-the-fleet-before-a-long-run) instead.

The generated `[subagents.models]` pins beat each agent's own `model:`
frontmatter, so this is how you retarget the agents without editing their
files.

## Check the fleet before a long run

A model that is down, swapped out from under you, or lying about its context
window does not fail cleanly. It fails in the middle of a pipeline, as an
inference error that says nothing about the real cause. The doctor asks first:

```sh
tools/doctor.sh              # fast: reachability, served ids, context drift
tools/doctor.sh --generate   # also send one completion per model
```

```powershell
.\tools\doctor.ps1
.\tools\doctor.ps1 -Generate
```

```
oh-my-axon doctor -- 5 endpoint(s) contacted from ~/.axon/config.toml

  DOWN   little -- http://127.0.0.1:49152/v1
  STALE  nemotron -- http://gata.local:8000/v1
  UP     laguna -- http://gata.local:8000/v1
  SKIP   gemma-cloud -- off-box, not contacted

Problems:
little is unreachable at http://127.0.0.1:49152/v1.
  ^ this breaks: scout, session_summary
nemotron points at a server that is up but serving laguna, not "nemotron".
```

`STALE` is the one worth knowing: the endpoint answers, but it is serving
something else — usually two models configured against one server that runs
one at a time. Every problem names the roles it breaks, so you can tell a dead
spare from a dead `executor`.

It exits **1** when anything is wrong, so it works in a script. It contacts
only the endpoints your config already names, never guesses ports, and never
touches off-box endpoints without `--include-remote`.

`--generate` additionally sends one tiny completion per model, which catches
what a listing cannot: whether reasoning is leaking into the reply text. It is
opt-in because it costs a round trip per model, and because the first
completion against an idle server can trigger a model load.

## See what your roles actually did

`gen-roles` assigns roles to models by reading parameter counts out of their
names, and says so in its own output: **SUGGESTIONS, not measurements**. This
is the other half — it measures.

Install the hook, which is opt-in because it writes a file as you work:

```sh
./install.sh --with-telemetry
```

```powershell
.\install.ps1 -WithTelemetry
```

From then on every finished subagent appends one line to
`~/.axon/telemetry/subagents.jsonl`. Read it back with:

```sh
tools/subagents.sh                 # every role
tools/subagents.sh --role executor # one role
tools/subagents.sh --quiet         # only problems, for a script
```

```powershell
.\tools\subagents.ps1
.\tools\subagents.ps1 -Role executor
```

```
oh-my-axon subagents -- 42 run(s) across 4 role(s) from ~/.axon/telemetry/subagents.jsonl
Smallest run recorded: 6.8k of context. That is close to the fixed cost of a spawn, before a subagent does any work.

  ROLE       MODEL      RUNS   OK/FAIL/CANC   MED DUR  TURNS/CALLS   PEAK CTX  OF WINDOW
  scout      gemma        18         18/0/0      6.1s          1/0       7.4k         6%
  executor   laguna       15         13/2/0        41s          9/6     120.0k        92%
  architect  laguna        6          6/0/0        22s          4/1      31.2k        24%
  reviewer   laguna        3          3/0/0        18s          3/2      18.4k        14%

Problems:
executor failed 2 of 15 run(s). Most recent error: connection refused
executor peaked at 120.0k of laguna's 131.1k window (92%). Axon compacts at 85%,
so this role was compacting mid-run: give it a model with more room, or split the task.
```

Two things that table is good for. **`OF WINDOW`** is the one that changes a
config: Axon compacts at 85% of the window, so a role sitting above that is
spending its turns summarising itself instead of working. And `scout` never
passing 7.4k against a floor of 6.8k says that role is almost entirely fixed
overhead — a smaller model would serve it just as well.

It exits **1** when it has something to report, so it works in a script.

**What it deliberately does not print is tokens per second.** The `tokensUsed`
Axon reports is the subagent's *final context size*, not the number of tokens
it generated: a one-word reply still reports ~6.9k, because that is the system
prompt and the tool schemas. Divide that by elapsed time and you get a figure
that looks like throughput and measures nothing — on a local 120B it comes out
near 1300 "tok/s". Context pressure and latency are what this data supports,
so those are what it reports.

## Tune it to your model class

Local doesn't mean small. oh-my-axon's defaults are safe on anything, but
what you should change depends on the class of model behind it. Three
universals first: set `context_window` in `~/.axon/config.toml` to the
server's **real** loaded/served context (never trust the 200k default —
auto-compaction triggers at 85% of this number), give each agent its
own `model:` in its frontmatter when you have more than one server (Axon
resolves one model per agent; there are no fallback chains), and — if the
model reasons — make sure it actually returns that reasoning separately:

```toml
[model.your-reasoner]
chat_template_kwargs = { enable_thinking = true }
```

vLLM's reasoning parsers stay inert without it and leave the whole
chain-of-thought in the answer, where it gets stored and re-sent as history
every turn. On a 120B local model that was the difference between 1,437 and
153 tokens for the same conversation. Prefer `enable_thinking` over the
`thinking` alias; agent-level `effort:` cannot substitute for it, and on a
non-Harmony vLLM model `effort:` does nothing at all.

**Frontier-local — 100B+ MoE on a DGX Spark / Mac Studio class box**
(Nemotron 3 Super 120B, Laguna S 2.1, …)
- Serve at 256k and set `context_window` to match (e.g. `262144`).
- Run the full pipeline; parallel executors with `isolation: "worktree"`
  are fine for independent work items.
- Split agents across servers if you have them: big model for
  executor/reviewer, something fast for scout.
- For headless/automation runs, launch with `--always-approve` — an
  unattended pipeline that hits a permission prompt is a dead run.

**Mid — 14–70B dense or mid-size MoE**
- Ship defaults as-is: full pipeline, sequential executors.
- Set `context_window` honestly (32–131k); long ultrawork runs will
  actually reach the 85% compaction line, and recovery depends on the
  saved plan file.

**Small — ≤14B**
- This class can plan but reliably fumbles exact-match edits and
  long-transcript rule-following; the skill's "iron rules" exist because
  of it. Keep `/ultrawork` for small scopes, prefer `/plan` + running the
  work items yourself, apply the `concise` persona liberally, and never
  parallelize.

(The `scout`/`architect` names are deliberately nothing like the built-in
`explore`/`plan` subagent types — models of every size substitute the
shorter familiar name when the names are near-identical.)

## Privacy stance

Inherited from Axon (no-egress axiom, loopback auto-no-auth) and kept here:
no telemetry, no cloud services, no MCP servers that leave your machine. The
secret-scan hook runs entirely locally. With only local models configured,
`[features] remote_fetch = false` makes startup fully offline.

The subagent telemetry hook is the one thing here that writes a file as you
work, which is why it is opt-in. What it records is measurements — role, model,
exit status, duration, token counts — and deliberately not the subagent's
`description`, which is derived from what you asked for. It is a plain JSONL
file at `~/.axon/telemetry/subagents.jsonl`: read it, and delete it whenever
you like. Uninstalling leaves it in place rather than throwing your data away,
and says so.

## Layout

```
home/               mirrors what lands in ~/.axon/
  agents/           *.md (YAML frontmatter + system prompt body)
  personas/         *.toml
  skills/           ultrawork/, plan/, handoff/, audit/
  hooks/            secret-scan.json + format-on-edit.json
                    + subagent-telemetry.json + bin/ (sh + ps1)
config/
  config.toml.snippet
tools/              not installed -- run these from the checkout
  gen-roles.sh / .ps1   prints a [models] + [subagents.models] block
  doctor.sh / .ps1      checks the fleet your config names is actually there
  subagents.sh / .ps1   reports what the telemetry hook recorded
  lib/                  probe.sh / Probe.ps1 -- shared catalog + endpoint probing
tests/              smoke tests (sh + ps1) and structure validation
install.sh / install.ps1
```

## Development

Every push is linted and smoke-tested: shellcheck over the POSIX scripts,
PSScriptAnalyzer over the PowerShell ones, a structure check on the agent /
skill / hook files, and a full installer lifecycle on both Ubuntu and
Windows. The same checks run locally:

```sh
sh tests/smoke-install.sh            # dry run -> install -> backup -> uninstall
sh tests/smoke-hooks.sh              # payload in, decision out
sh tests/smoke-gen-roles.sh          # role assignment, off-box exclusion, probe, determinism
sh tests/smoke-doctor.sh             # UP/STALE/AUTH/DOWN, context drift, exit codes
sh tests/smoke-subagents.sh          # telemetry records, context-pressure findings
python3 tests/validate_structure.py  # frontmatter, hook JSON, installer agreement
```

```powershell
pwsh -File tests\smoke-install.ps1
pwsh -File tests\smoke-hooks.ps1
pwsh -File tests\smoke-gen-roles.ps1
pwsh -File tests\smoke-doctor.ps1
pwsh -File tests\smoke-subagents.ps1
```

The installer tests run against a throwaway `AXON_HOME` and refuse to start
if it would resolve to a real one, so they never touch your own install. The
hook tests run the scripts through Windows PowerShell 5.1 where it exists,
because that is what the installed hook command line uses.

## License

MIT — see [LICENSE](LICENSE).
