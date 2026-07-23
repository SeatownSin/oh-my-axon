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
| **4 subagents** | `~/.axon/agents/` | `scout` (read-only recon), `architect` (read-only planning), `executor` (implements one work item), `reviewer` (runs checks, can't edit) — each with a tuned prompt and least-privilege capability mode, named to never collide with the built-in `explore`/`plan` types |
| **2 personas** | `~/.axon/personas/` | `concise` (small-context-friendly output), `thorough` (skeptical verification passes) |
| **`/ultrawork` skill** | `~/.axon/skills/ultrawork/` | The headline: say `ultrawork` (or `ulw`, or `/ultrawork <task>`) and Axon orchestrates explore → plan → implement → verify across the agents, persisting the plan to `.axon/plans/` in your repo |
| **`/plan` skill** | `~/.axon/skills/plan/` | Interview → recon → saved plan, no implementation; run it later with `/ultrawork run <plan-file>` |
| **secret-scan hook** | `~/.axon/hooks/` | PreToolUse gate that blocks edits/commands containing things that look like real credentials (AWS/GitHub/Slack/OpenAI/Anthropic/Google/Stripe keys, private key blocks). 100% local |
| **format-on-edit hook** (opt-in) | `~/.axon/hooks/` | PostToolUse hook that auto-formats an edited file with the project's own formatter (rustfmt / prettier / black, detected by config file). Never blocks an edit; installed only with `--with-format-hook` / `-WithFormatHook` |
| **Model config reference** | stays in this repo | `config/config.toml.snippet` — LM Studio / Ollama / LAN-server blocks with the context-window gotchas spelled out |

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

## Tune it to your model class

Local doesn't mean small. oh-my-axon's defaults are safe on anything, but
what you should change depends on the class of model behind it. Two
universals first: set `context_window` in `~/.axon/config.toml` to the
server's **real** loaded/served context (never trust the 200k default —
auto-compaction triggers at 85% of this number), and give each agent its
own `model:` in its frontmatter when you have more than one server (Axon
resolves one model per agent; there are no fallback chains).

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

## Layout

```
home/               mirrors what lands in ~/.axon/
  agents/           *.md (YAML frontmatter + system prompt body)
  personas/         *.toml
  skills/           ultrawork/, plan/
  hooks/            secret-scan.json + bin/ (sh + ps1)
config/
  config.toml.snippet
install.sh / install.ps1
```

## Roadmap

- auto-format PostToolUse hook (per-project formatter detection)
- role-level model presets generated from detected local servers
- more skills: `/handoff` (session-to-session memory), `/audit`

MIT — see [LICENSE](LICENSE).
