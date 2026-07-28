#!/usr/bin/env python3
"""Summarise one task's results.    python3 analyze.py results/absence.jsonl

Comparisons are WITHIN a model, never across. gemma reasons on every call and
cannot be told not to (chat_template_kwargs, reasoning.enabled and the default
were all tried); laguna runs with thinking off. That makes the two models'
absolute numbers incomparable while leaving arm-vs-arm inside one model clean,
because the wording of the system prompt is the only thing that differs.

Cost is reported as MEDIANS with a rank test, not means with a t-test. On the
confusable task 4-9 runs per arm hit the token ceiling even at 16k, and a mean
over censored data measures the ceiling. A median survives as long as under
half the runs are censored, and Mann-Whitney only uses ranks, so values pinned
at the cap tie at the top rank instead of inventing a magnitude.
"""

import bisect, io, json, sys
from collections import defaultdict
from math import comb, erf, sqrt
from statistics import median

ARMS = ["A-slop", "B-baseline", "C-ste"]


def fisher(a, b, c, d):
    n, r1, r2, c1 = a + b + c + d, a + b, c + d, a + c
    f = lambda x: (comb(r1, x) * comb(r2, c1 - x)) / comb(n, c1)
    obs = f(a)
    lo, hi = max(0, c1 - r2), min(c1, r1)
    return min(1.0, sum(f(x) for x in range(lo, hi + 1) if f(x) <= obs + 1e-12))


def mannwhitney(x, y):
    allv = sorted(x + y)

    def rank(v):
        return (bisect.bisect_left(allv, v) + bisect.bisect_right(allv, v) + 1) / 2.0

    n1, n2 = len(x), len(y)
    u1 = sum(rank(v) for v in x) - n1 * (n1 + 1) / 2.0
    u = min(u1, n1 * n2 - u1)
    mu, sd = n1 * n2 / 2.0, (n1 * n2 * (n1 + n2 + 1) / 12.0) ** 0.5
    return 2 * 0.5 * (1 + erf(-abs((u - mu) / sd) / sqrt(2)))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "results/absence.jsonl"
    rows = [json.loads(l) for l in io.open(path, encoding="utf-8")]
    cells = defaultdict(list)
    for r in rows:
        cells[(r["model"], r["arm"])].append(r)
    checks = list(rows[0]["checks"].keys())
    probes = list(rows[0].get("probes", {}).keys())

    print("%s   (%d checks per response)" % (path, len(checks)))
    for m in sorted({r["model"] for r in rows}):
        ns = [len(cells[(m, a)]) for a in ARMS]
        caps = sorted({r["max_tokens"] for r in cells[(m, ARMS[0])]})
        print("\n" + "=" * 84)
        print("%s   n=%s per arm   max_tokens=%s" % (m.upper(), ns[0], caps))
        print("=" * 84)
        print("%-28s %9s %10s %9s" % ("", *ARMS))
        print("-" * 84)

        def show(label, fn, pct=True):
            v = [fn(cells[(m, a)]) for a in ARMS]
            if pct:
                print("%-28s %8.0f%% %9.0f%% %8.0f%%" % (label, *[x * 100 for x in v]))
            else:
                print("%-28s %9.0f %10.0f %9.0f" % (label, *v))

        for ck in checks:
            show(ck, lambda rs, k=ck: sum(r["checks"][k] for r in rs) / len(rs))
        print("-" * 84)
        show("ALL CHECKS PASS", lambda rs: sum(1 for r in rs if r["passed"] == len(checks)) / len(rs))
        for pk in probes:
            show("probe: " + pk, lambda rs, k=pk: sum(r["probes"][k] for r in rs) / len(rs))
        show("no answer at all", lambda rs: sum(1 for r in rs if r["no_answer"]) / len(rs))
        show("hit the token ceiling", lambda rs: sum(1 for r in rs if r["truncated"]) / len(rs))
        print("-" * 84)
        for k in ["reasoning_chars", "completion_tokens", "latency_s"]:
            if max((r.get(k) or 0) for r in rows) == 0:
                continue
            show("median " + k, lambda rs, kk=k: median([r.get(kk) or 0 for r in rs]), pct=False)

        print("-" * 84)
        B = cells[(m, "B-baseline")]
        bp = sum(1 for r in B if r["passed"] == len(checks))
        print("vs B-baseline:")
        for arm in ["A-slop", "C-ste"]:
            X = cells[(m, arm)]
            xp = sum(1 for r in X if r["passed"] == len(checks))
            p = fisher(xp, len(X) - xp, bp, len(B) - bp)
            print("   %-11s adherence %2d/%2d vs %2d/%2d  Fisher p=%.4f%s"
                  % (arm, xp, len(X), bp, len(B), p, "  *" if p < 0.05 else ""))
            for k in ["reasoning_chars", "completion_tokens", "latency_s"]:
                xv = [r.get(k) or 0 for r in X]
                bv = [r.get(k) or 0 for r in B]
                if max(xv + bv) == 0:
                    continue
                mb = median(bv) or 1
                p = mannwhitney(xv, bv)
                print("       %-18s %.2fx  Mann-Whitney p=%.4f%s"
                      % (k, median(xv) / mb, p, "  *" if p < 0.05 else ""))
        print()


if __name__ == "__main__":
    main()
