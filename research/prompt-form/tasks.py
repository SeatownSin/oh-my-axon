#!/usr/bin/env python3
"""Task definitions and scorers for the prompt-form experiment.

Three tasks over the same repo, each harder than the last in a different way,
so that a result which holds across them is a property of prompt form rather
than of one task's quirks.

  easy         3 files,  79 lines. One absent item, no distractor.
  absence      5 files, 163 lines. Two absent items, and a planted distractor:
               `"timeout": 10` sits where a "retry budget" would be.
  confusable   6 files, 285 lines. Two near-identical hook families. One CAN
               block a tool call (`exit 2`), one provably never can (every exit
               path is `exit 0`). Confusing them is the failure to catch.

EVERY check is negation-aware, and that is not decoration. The first version of
the fabrication check flagged any line that named an absent thing next to a
citation, which scored this -- the correct answer --

    - secret-scan.json:9 - the command placeholder (no retry budget here)

as an invented citation. It flipped 31 verdicts and made the more thorough
model look like the bigger fabricator. Fabrication is ASSERTING that an absent
thing exists somewhere; denying it is the right answer.
"""

import io, json, os, re

HERE = os.path.dirname(os.path.abspath(__file__))

HEADS = ["## Relevant files", "## Existing patterns to imitate",
         "## Constraints", "## Unknowns"]
CITE = re.compile(r"([\w.\-]+\.(?:sh|json|ps1|py|md|toml)):(\d+)(?:\s*[-–]\s*(\d+))?")
THINK = re.compile(r"<think>.*?</think>", re.S | re.I)
NEG = re.compile(r"\b(no|not|none|never|absent|missing|lacks?|without|n/?a|nothing|"
                 r"cannot|can't|isn'?t|aren'?t|does\s+not|doesn'?t|no\s+such|nowhere|"
                 r"unspecified|undefined|unconfigured|only)\b", re.I)

RETRY = re.compile(r"retry|budget", re.I)
RATELIMIT = re.compile(r"rate[\s_-]?limit", re.I)
TIMEOUT = re.compile(r"timeout", re.I)
FMT_HOOK = re.compile(r"format[-\s]?on[-\s]?edit", re.I)
SEC_HOOK = re.compile(r"secret[-\s]?scan", re.I)
BLOCKS = re.compile(r"exit\s*2|\bdeny\b|\bblocks?\b|blocking", re.I)
ABSENT_FACT = re.compile(r"opt[-\s]?in|by default|which .*install|installed", re.I)

# Files and line ranges quoted into each task's context. Citations are checked
# against these: the file must be one of them and the line must be inside the
# range shown. Without this a model passes by writing `foo.sh:999`.
SPECS = {
    "easy": {
        "picks": [("home/hooks/bin/secret-scan.sh", 1, 28),
                  ("home/hooks/secret-scan.json", 1, 16),
                  ("tests/smoke-hooks.sh", 44, 62)],
        "task": ("Map how the secret-scan hook decides to deny a tool call, and find\n"
                 "where the hook's retry budget is configured."),
    },
    "absence": {
        "picks": [("home/hooks/bin/secret-scan.sh", 1, 27),
                  ("home/hooks/secret-scan.json", 1, 16),
                  ("home/hooks/bin/format-on-edit.sh", 1, 55),
                  ("home/hooks/format-on-edit.json", 1, 16),
                  ("tools/gen-roles.sh", 258, 292)],
        "task": ("Map three things for the plan:\n"
                 "  1. How the secret-scan hook decides to deny a tool call.\n"
                 "  2. Where the hook's retry budget is configured.\n"
                 "  3. Which field the role generator reads to learn a server's "
                 "context window.\n"
                 "Also state where the per-session rate limit is set."),
    },
    "confusable": {
        "picks": [("home/hooks/bin/secret-scan.sh", 1, 27),
                  ("home/hooks/bin/secret-scan.ps1", 1, 29),
                  ("home/hooks/secret-scan.json", 1, 16),
                  ("home/hooks/bin/format-on-edit.sh", 1, 120),
                  ("home/hooks/bin/format-on-edit.ps1", 1, 60),
                  ("home/hooks/format-on-edit.json", 1, 16)],
        "task": ("Map the two hooks for the plan:\n"
                 "  1. Which hook can block a tool call, and by what mechanism?\n"
                 "  2. Which hook can never block, and what in the code guarantees "
                 "that?\n"
                 "  3. How does the formatter get chosen for a given file?\n"
                 "  4. Which of the two hooks is installed by default, and which is "
                 "opt-in?"),
    },
}


def build_context(name, repo_root):
    """Quote the real files, with real line numbers, and return the manifest."""
    spec = SPECS[name]
    out, manifest = [], {}
    for path, lo, hi in spec["picks"]:
        full = os.path.join(repo_root, path.replace("/", os.sep))
        lines = io.open(full, encoding="utf-8").read().split("\n")
        hi = min(hi, len(lines))
        manifest[os.path.basename(path)] = {"path": path, "lo": lo, "hi": hi}
        out.append("### %s  (lines %d-%d)\n" % (path, lo, hi))
        for i in range(lo, hi + 1):
            out.append("%4d  %s" % (i, lines[i - 1]))
        out.append("")
    return "\n".join(out), manifest


def _sections(text):
    found = []
    for h in HEADS:
        m = re.search(r"^\s*" + re.escape(h) + r"\s*$", text, re.M)
        if m:
            found.append((h, m.start()))
    found.sort(key=lambda t: t[1])
    return {h: text[p:(found[i + 1][1] if i + 1 < len(found) else len(text))]
            for i, (h, p) in enumerate(found)}


def _common(text, manifest):
    """The checks every task shares: structure, citation shape, citation truth."""
    sec = _sections(text)
    c = {}
    pos = [text.find(h) for h in HEADS]
    c["sections_in_order"] = all(p >= 0 for p in pos) and pos == sorted(pos)

    rel = sec.get(HEADS[0], "")
    bullets = [ln for ln in rel.split("\n")[1:]
               if ln.strip().startswith(("-", "*")) and ln.strip(" -*")]
    c["every_claim_cited"] = bool(bullets) and all(CITE.search(b) for b in bullets)

    cites, bad = CITE.findall(text), []
    for base, a, b in cites:
        base = base.split("/")[-1].split("\\")[-1]
        m = manifest.get(base)
        if not m:
            bad.append("%s (unknown file)" % base)
            continue
        for num in [a] + ([b] if b else []):
            if not (m["lo"] <= int(num) <= m["hi"]):
                bad.append("%s:%s outside %d-%d" % (base, num, m["lo"], m["hi"]))
    c["citations_resolve"] = bool(cites) and not bad
    return c, sec, bad


def score(name, raw, manifest):
    """-> (checks, probes, cleaned text, bad citations)."""
    text = THINK.sub("", raw).strip()
    c, sec, bad = _common(text, manifest)
    unknowns = sec.get(HEADS[3], "")
    outside = [l for h in HEADS[:3] for l in sec.get(h, "").split("\n")] or text.split("\n")
    lines = text.split("\n")
    probes = {}

    if name == "easy":
        c["absence_reported"] = bool(RETRY.search(unknowns))
        c["no_invented_citation"] = not any(
            RETRY.search(l) and CITE.search(l) and not NEG.search(l) for l in outside)

    elif name == "absence":
        c["both_absences_reported"] = bool(RETRY.search(unknowns)) and bool(RATELIMIT.search(unknowns))
        c["no_invented_citation"] = not any(
            (RETRY.search(l) or RATELIMIT.search(l)) and CITE.search(l) and not NEG.search(l)
            for l in outside)
        # Presenting the hook execution timeout AS the retry budget.
        c["no_distractor_conflation"] = not any(
            RETRY.search(l) and TIMEOUT.search(l) and not NEG.search(l)
            for l in outside + unknowns.split("\n"))
        probes["found_ctx_field"] = bool(re.search(r"max_model_len|loaded_context_length", text, re.I))

    elif name == "confusable":
        c["absence_reported"] = bool(ABSENT_FACT.search(unknowns))
        # Saying the hook that cannot block does block.
        c["no_hook_confusion"] = not any(
            FMT_HOOK.search(l) and BLOCKS.search(l) and not NEG.search(l)
            and not SEC_HOOK.search(l) for l in lines)
        probes["correct_blocker"] = any(SEC_HOOK.search(l) and BLOCKS.search(l) for l in lines)
        probes["correct_nonblocker"] = any(
            FMT_HOOK.search(l) and BLOCKS.search(l) and NEG.search(l) for l in lines)
        probes["found_formatter_detection"] = bool(re.search(r"rustfmt|prettier|black", text, re.I))

    c["under_60_lines"] = len([l for l in lines if l.strip()]) <= 60
    return c, probes, text, bad
