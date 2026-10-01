#!/usr/bin/env python3
"""Save a finished subagent's final message to a file, without a model re-typing it.

    python3 save_subagent_report.py <subagent_id> <out.md>

Used by /ultrawork in file-handoff mode. The default handoff makes the
orchestrator paste a scout's report into the architect's prompt and re-type the
architect's plan into the plan file. Every pasted token is a generated token:
on a local model that costs minutes per handoff, and a long report can push the
orchestrator's reply past the server's per-reply output cap, which ends the run.

This reads the subagent's own transcript from disk instead:
    $AXON_HOME/sessions/<project>/<subagent_id>/chat_history.jsonl
(AXON_HOME defaults to ~/.axon) and writes the last non-empty assistant message.

Prints one line. Exit 0 = saved; 1 = nothing saved (no or ambiguous transcript,
or no final text); 2 = usage. Stdlib only.
"""

import json
import os
import sys
from pathlib import Path


def axon_home():
    env = os.environ.get("AXON_HOME")
    return Path(env) if env else Path.home() / ".axon"


def final_message(transcript):
    last = None
    with transcript.open(encoding="utf-8") as f:
        for line in f:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            content = rec.get("content")
            if rec.get("type") == "assistant" and isinstance(content, str) and content.strip():
                last = content
    return last


def main(argv):
    if len(argv) != 3:
        print("usage: save_subagent_report.py <subagent_id> <out.md>")
        return 2
    sid, out = argv[1].strip(), Path(argv[2])
    sessions = axon_home() / "sessions"
    hits = sorted(sessions.glob("*/" + sid + "/chat_history.jsonl"))
    if len(hits) != 1:
        print("ERROR: expected 1 transcript for %s under %s, found %d" % (sid, sessions, len(hits)))
        return 1
    text = final_message(hits[0])
    if not text:
        print("ERROR: no final assistant text in %s (did the subagent fail?)" % hits[0])
        return 1
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8", newline="\n") as f:
        f.write(text.strip() + "\n")
    print("OK: %d lines, %d chars -> %s" % (len(text.strip().splitlines()), len(text), out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
