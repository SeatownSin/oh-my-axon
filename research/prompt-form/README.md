# Does the FORM of a system prompt change how a local model behaves?

oh-my-axon's agents are system prompts. The premise worth testing is that
writing them in tight, controlled prose — the mechanical half of
[ASD-STE100](https://asd-ste100.org) Simplified Technical English — makes a
small local model follow them better. Small models are the ones that fumble
long instructions, and this distribution exists to run on them.

That premise is **wrong on correctness and right on cost**.

- **Rule-following does not change.** Across three tasks, two models and ~420
  calls, no prompt form followed the rules measurably better than another.
- **Cost changes a lot, on the small model only.** Slop-form instructions cost
  the 12B up to **2.9× the reasoning and 2.1× the wall-clock** for the same
  answer. The 120B barely moves.
- **Tightening past oh-my-axon's current prompts is free-to-beneficial.** Zero
  difference on easy work, **0.27–0.77× the cost** on hard work, at identical
  adherence.

## Design

Three arms carry an **identical rule set** in different prose. Only the wording
changes, so anything that moves is attributable to form.

| Arm | What it is | ste-lint score |
|---|---|---|
| `A-slop` | the rules as an unguided model would write them | 13.68 /100w |
| `B-baseline` | oh-my-axon's real `home/agents/scout.md` | 1.18 |
| `C-ste` | a strict STE rewrite of the same rules | 2.30 |

Three tasks over this repo's own source, each hard in a different way, so a
result that survives all three is not an artifact of one:

| Task | Context | Hard because |
|---|---|---|
| `easy` | 3 files, 79 lines | one absent item, no distractor |
| `absence` | 5 files, 163 lines | two absent items, and `"timeout": 10` planted where a "retry budget" would be |
| `confusable` | 6 files, 285 lines | two near-identical hook families; one can block (`exit 2`), one provably cannot (every path `exit 0`) |

Scoring is **mechanical** — no LLM judge, so no judge bias. Citations are
checked against a manifest: the file must be one that was quoted and the line
must fall inside the range shown. Models: `gemma-4-12b-qat` (small) and a
120B (large), both local.

## Results

`C-ste` against `B-baseline` on the small model — the question that decides
whether the agent files are worth rewriting:

| Task | reasoning | tokens | latency | adherence |
|---|---|---|---|---|
| easy | 1.10× (p=0.52) | 1.11× (p=0.43) | 1.05× (p=0.46) | no change |
| absence | **0.27×** (p=0.0002) | **0.41×** (p=0.0002) | **0.63×** (p<0.0001) | 20/20 both |
| confusable | **0.73×** (p=0.020) | **0.77×** (p=0.048) | **0.50×** (p=0.0013) | no change |

Null when the work is easy, materially cheaper when it is hard, never worse.
Two independent hard tasks agree.

`A-slop` against `B-baseline`, same model — the cost of writing instructions
badly:

| Task | reasoning | tokens | latency |
|---|---|---|---|
| easy | **2.86×** (p<0.0001) | 2.18× (p<0.0001) | 2.06× (p<0.0001) |
| absence | **1.33×** (p=0.0013) | 1.30× (p=0.0008) | 1.37× (p=0.088) |
| confusable | 0.81× (p=0.39) | 0.86× (p=0.40) | 0.70× (p=0.031) |

Replicated on two of three tasks. It **fails to replicate on `confusable`**,
and the reason is visible in the data rather than guessed: that task pushes the
12B into a runaway-generation mode where 4–9 runs per arm never produce an
answer at all. When the model is failing on its own, prompt form stops
mattering. Reported as regime-dependent, not universal.

On the 120B every cost contrast is 0.90–1.14× and mostly non-significant.
**This is a small-model effect.**

## What did not move

Adherence. On every task, on both models, every arm-vs-baseline comparison is
non-significant — except one, which is an artifact (see below). Three tasks
were built with escalating traps specifically to break that ceiling, including
a planted distractor and a pair of near-identical subsystems, and none of them
separated the arms. If prompt form changes whether rules get followed, the
effect is smaller than this design can see.

## Honest limits

- **One agent (`scout`), one small model, one large.** Effect sizes vary a lot
  by task; treat the direction as the finding, not the multiplier.
- **`A-slop` is exaggerated** — 13.68/100w against the ~4.4 an unguided model
  actually produces. Slop-penalty numbers are upper bounds.
- **`citations_resolve` is brittle on the `easy` task.** 26 of its 28 failures
  there are a single off-by-one past EOF (`secret-scan.json:17` in a 16-line
  file), which is a counting slip, not an invention. It is the sole reason
  laguna's `easy` adherence comparison reads as significant (baseline 0/10).
  **That result is an artifact and should not be cited.** The other two tasks
  produce almost no bad citations at all.
- **The `confusable` task is censored even at 16k tokens** (4–9 runs per arm
  hit the ceiling). Cost there is reported as medians with Mann-Whitney, which
  survive censoring below 50%; means would measure the ceiling.
- Comparisons are **within-model only**. gemma reasons on every call and cannot
  be told not to (`chat_template_kwargs`, `reasoning.enabled` and the default
  were all tried); the 120B runs with thinking off.

## Four measurement bugs this found — the useful part

Every one produced a plausible, publishable, wrong number.

1. **Truncation read as format violation.** A report cut off at the token cap
   loses its last heading, which scores as "ignored the format". Fixed by
   recording `finish_reason` separately.
2. **The answer was in a field nobody read.** gemma returns thoughts in
   `reasoning_content`, and under the slop prompt it once spent the entire
   budget there and returned empty `content` — scored as five format failures
   when the truth was "never got as far as answering". Axon hit the same
   dual-spelling problem (`reasoning` vs `reasoning_content`).
3. **The fabrication check was backwards.** It flagged any citation near an
   absent term, so this — the *correct* answer — scored as invention:

       - secret-scan.json:9 - the command placeholder (no retry budget here)

   It punished the more thorough model and flipped **31 verdicts**. Fabrication
   is *asserting* an absent thing exists; denying it is right. Every check here
   is now negation-aware.
4. **Censored cost data.** On `confusable`, 8–9 of 20 runs hit a 5000-token
   cap. Both arms clipped at the same ceiling, so the comparison measured the
   cap and showed the slop penalty "vanishing". Raising the cap to 16k and
   switching to medians fixed the analysis; the runaway rate is now its own
   reported outcome.

Bugs 2–4 were caught by reading raw responses, not by looking at aggregates.
That is the argument for storing full text: three of the four were invisible in
the summary statistics and each one, left alone, would have produced a
confident and false conclusion.

## Reproducing

Needs a running local model. Nothing here is installed by `install.sh`, and
none of it runs in CI, because CI has no model server.

```sh
python3 harness.py --task absence --model-key laguna --reps 20
python3 analyze.py results/absence.jsonl
```

`--model-key` resolves `base_url`, the wire id and any `api_key` from your own
`~/.axon/config.toml`, so no endpoint is hard-coded here. Credentials are read
at the point of the request and never written to results.

`results/*.jsonl` carries one record per call — every check, token count and
latency behind the tables above — with the response text stripped for size. Re-run
the harness to regenerate full text.

| File | What it is |
|---|---|
| `harness.py` | runs one task × one model × N reps |
| `tasks.py` | the three task definitions and their scorers |
| `analyze.py` | medians, Fisher exact, Mann-Whitney |
| `prompts/` | the three arms |
| `results/` | every call behind the numbers above |
