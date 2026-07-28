#!/usr/bin/env python3
"""Run one task, one model, N repetitions per prompt arm.

    python3 harness.py --task absence --model-key laguna --reps 20

The endpoint, the wire model id and any api_key come from your own
~/.axon/config.toml, resolved by catalog key, so nothing about anyone's network
is baked in here. Credentials are read at the point of the request and are
never written to the results file.

Needs a model server that is actually running. This is deliberately not wired
into CI: CI has no GPU and no server, and a test that cannot run is worse than
no test.
"""

import argparse, io, json, os, re, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import tasks                                              # noqa: E402

ARMS = ["A-slop", "B-baseline", "C-ste"]


def resolve_model(key, config_path=None):
    """Pull base_url / model / api_key for one [model.<key>] out of config.toml.

    Same shape gen-roles reads, and for the same reason: the catalog is where
    this information already lives, so there is nothing to keep in sync.
    """
    path = config_path or os.path.join(
        os.environ.get("AXON_HOME", os.path.join(os.path.expanduser("~"), ".axon")),
        "config.toml")
    if not os.path.isfile(path):
        sys.exit("harness: no config at %s" % path)
    cur, got = None, {}
    for line in io.open(path, encoding="utf-8"):
        m = re.match(r"^\s*\[model\.([^\]]+)\]", line)
        if m:
            cur = m.group(1).strip().strip('"').strip("'")
            continue
        if re.match(r"^\s*\[", line):
            cur = None
            continue
        if cur != key:
            continue
        for field in ("base_url", "model", "api_key", "no_auth"):
            m = re.match(r'^\s*%s\s*=\s*"?([^"#\n]*)"?' % field, line)
            if m:
                got[field] = m.group(1).strip()
    if not got.get("base_url"):
        sys.exit("harness: [model.%s] has no base_url in %s" % (key, path))
    return {
        "base": got["base_url"].rstrip("/"),
        "model": got.get("model") or key,
        "api_key": None if got.get("no_auth") == "true" else got.get("api_key"),
    }


def call(cfg, system, user, temperature, max_tokens, no_think, timeout=1800):
    body = {"model": cfg["model"],
            "messages": [{"role": "system", "content": system},
                         {"role": "user", "content": user}],
            "temperature": temperature, "max_tokens": max_tokens, "stream": False}
    if no_think:
        # vLLM installs a real reasoning parser only when this is present;
        # without it the chain of thought lands in `content` and pollutes
        # anything that reads the answer.
        body["chat_template_kwargs"] = {"enable_thinking": False}
    req = urllib.request.Request(cfg["base"] + "/chat/completions",
                                 data=json.dumps(body).encode("utf-8"),
                                 headers={"Content-Type": "application/json"})
    if cfg["api_key"]:
        req.add_header("Authorization", "Bearer " + cfg["api_key"])
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        payload = json.loads(r.read().decode("utf-8"))
    dt = time.time() - t0
    ch = payload["choices"][0]
    msg = ch["message"]
    # Both spellings: vLLM says `reasoning`, LM Studio and DeepSeek say
    # `reasoning_content`. A model that reasons until it runs out of room has
    # an empty `content`, and reading only `content` scores that as a format
    # failure instead of what it is.
    return ((msg.get("content") or ""),
            (msg.get("reasoning_content") or msg.get("reasoning") or ""),
            dt, (payload.get("usage") or {}).get("completion_tokens"),
            ch.get("finish_reason"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--task", required=True, choices=sorted(tasks.SPECS))
    ap.add_argument("--model-key", required=True,
                    help="a [model.<key>] section in ~/.axon/config.toml")
    ap.add_argument("--config")
    ap.add_argument("--reps", type=int, default=20)
    ap.add_argument("--temperature", type=float, default=0.2)
    ap.add_argument("--max-tokens", type=int, default=4000)
    ap.add_argument("--no-thinking", action="store_true",
                    help="send enable_thinking=false (vLLM); ignored elsewhere")
    ap.add_argument("--workers", type=int, default=3)
    ap.add_argument("--out")
    a = ap.parse_args()

    cfg = resolve_model(a.model_key, a.config)
    context, manifest = tasks.build_context(a.task, REPO)
    user = "Codebase excerpt:\n\n" + context + "\n\nTask: " + tasks.SPECS[a.task]["task"]
    prompts = {arm: io.open(os.path.join(HERE, "prompts", arm + ".md"),
                            encoding="utf-8").read() for arm in ARMS}
    out_path = a.out or os.path.join(HERE, "results", "%s.jsonl" % a.task)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    jobs = [(arm, rep) for arm in ARMS for rep in range(a.reps)]
    done = [0]

    def work(job):
        arm, rep = job
        try:
            text, reasoning, dt, ctok, fin = call(
                cfg, prompts[arm], user, a.temperature, a.max_tokens, a.no_thinking)
            checks, probes, clean, bad = tasks.score(a.task, text, manifest)
            rec = {"model": a.model_key, "arm": arm, "rep": rep,
                   "max_tokens": a.max_tokens, "checks": checks,
                   "passed": sum(checks.values()), "n_checks": len(checks),
                   "probes": probes, "bad_citations": bad[:4],
                   "no_answer": not clean.strip(), "latency_s": round(dt, 2),
                   "completion_tokens": ctok, "reasoning_chars": len(reasoning),
                   "truncated": fin == "length", "text": clean}
        except Exception as e:                            # a dead server is data
            rec = {"model": a.model_key, "arm": arm, "rep": rep, "ok": False,
                   "error": "%s: %s" % (type(e).__name__, e)}
        done[0] += 1
        sys.stderr.write("\r%d/%d" % (done[0], len(jobs)))
        sys.stderr.flush()
        return rec

    with ThreadPoolExecutor(max_workers=a.workers) as ex:
        results = list(ex.map(work, jobs))
    with io.open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        for rec in results:
            fh.write(json.dumps(rec) + "\n")
    sys.stderr.write("\n")

    trunc = sum(1 for r in results if r.get("truncated"))
    if trunc > len(results) * 0.15:
        print("WARNING: %d/%d runs hit the token ceiling. Cost numbers are "
              "censored -- raise --max-tokens and re-run, or read medians only."
              % (trunc, len(results)))
    print("wrote", out_path)


if __name__ == "__main__":
    main()
