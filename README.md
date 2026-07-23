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
| **4 subagents** | `~/.axon/agents/` | `scout` (read-only recon), `architect` (read-only planning), `executor` (implements one work item), `reviewer` (runs checks, can't edit) — each with a tuned prompt and least-privilege capability mode. Named to never collide with the built-in `explore`/`plan` types, which small local models otherwise confuse |
| **2 personas** | `~/.axon/personas/` | `concise` (small-context-friendly output), `thorough` (skeptical verification passes) |
| **`/ultrawork` skill** | `~/.axon/skills/ultrawork/` | The headline: say `ultrawork` (or `ulw`, or `/ultrawork <task>`) and Axon orchestrates explore → plan → implement → verify across the agents, persisting the plan to `.axon/plans/` in your repo |
| **`/plan` skill** | `~/.axon/skills/plan/` | Interview → recon → saved plan, no implementation; run it later with `/ultrawork run <plan-file>` |
| **secret-scan hook** | `~/.axon/hooks/` | PreToolUse gate that blocks edits/commands containing things that look like real credentials (AWS/GitHub/Slack/OpenAI/Anthropic/Google/Stripe keys, private key blocks). 100% local |
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
`config.toml`**. Uninstall cleanly with `./install.sh --uninstall` /
`.\install.ps1 -Uninstall`.

Test installation with `./install.sh --dry-run` /
`.\install.ps1 -DryRun` to see what would be installed/backed up without making changes.

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

## Why local models change the design

- **Small contexts**: every subagent prompt is self-contained and minimal —
  an executor gets exactly one work item, never the whole plan.
- **Conservative fan-out**: concurrency is capped at 2; sequential is the
  default, not the fallback.
- **One model per agent**: Axon resolves one model per session/agent (no
  fallback chains), so agents inherit your default model unless you set
  `model:` in an agent's frontmatter.
- **Format discipline**: agent prompts demand fixed output shapes, which
  small models follow far more reliably than open-ended asks.
- **Collision-free names**: `scout`/`architect` instead of anything
  resembling the built-in `explore`/`plan` subagent types — a 9B model
  will substitute the shorter name if you let it.

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
