#!/bin/sh
# oh-my-axon subagent telemetry smoke tests (Linux / WSL / macOS).
#
#   sh tests/smoke-subagents.sh
#
# Drives the SubagentStop hook against real captured payloads and tools/
# subagents.sh against fixture logs. Checks that the hook writes valid JSON on
# every path, that it never fails a run, and that the report refuses to state a
# finding it cannot support. Exits non-zero if any assertion fails.
#
# No EXIT trap: dash discards the exit status a trap sets, which silently turns
# a failing run green. Cleanup is explicit at the end instead.
set -eu

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd)
REPORT="$REPO_ROOT/tools/subagents.sh"
HOOK="$REPO_ROOT/home/hooks/bin/subagent-telemetry.sh"

# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"

WORK=$(mktemp -d)

run_rep() {
    set +e
    OUT=$(sh "$REPORT" "$@" 2>&1)
    CODE=$?
    set -e
}

# A throwaway AXON_HOME laid out the way the installer lays one out, so the
# hook's own path resolution is what gets exercised.
HOME_DIR="$WORK/axonhome"
mkdir -p "$HOME_DIR/hooks/bin" "$HOME_DIR/hooks/lib"
cp "$HOOK" "$HOME_DIR/hooks/bin/subagent-telemetry.sh"
cp "$REPO_ROOT/tools/lib/probe.sh" "$HOME_DIR/hooks/lib/probe.sh"

cat > "$HOME_DIR/config.toml" <<'EOF'
[model.big]
model = "big-70b"
base_url = "http://127.0.0.1:1/v1"
context_window = 131072

[model.small]
model = "small-12b"
base_url = "http://127.0.0.1:2/v1"

[models]
default = "big"

[subagents.models]
scout = "small"       # read-only recon, and a trailing comment to survive
EOF

fire() {
    # $1 = payload JSON on stdin via a file
    AXON_HOME="$HOME_DIR" sh "$HOME_DIR/hooks/bin/subagent-telemetry.sh" < "$1"
}

echo "hook: fixtures in $WORK"

# --- the hook writes one valid record per firing -----------------------------
echo
echo "hook output"
LOG="$HOME_DIR/telemetry/subagents.jsonl"

# The exact shape Axon 0.3.5 puts on the wire, including the `subagent_end`
# event name it reports even though the hook is registered as SubagentStop.
cat > "$WORK/ok.json" <<'EOF'
{"hookEventName":"subagent_end","sessionId":"019f","cwd":"/w","workspaceRoot":"/w","timestamp":"2026-07-29T22:17:43.120271600+00:00","subagentId":"019f-677e","subagentType":"executor","description":"Executor agent - reply BLUE","exitCode":0,"durationMs":5193,"tokensUsed":6962,"toolCalls":0,"turns":1}
EOF
fire "$WORK/ok.json"
assert_eq 'the hook exits 0' "$?" "0"
assert_file 'the hook creates the log' "$LOG"
LINE=$(head -n 1 "$LOG")
assert_match 'the record carries the role' "$LINE" '"subagentType":"executor"'
assert_match 'the record carries the token count' "$LINE" '"tokensUsed":6962'
assert_match 'the record carries the duration' "$LINE" '"durationMs":5193'
assert_match 'the record resolves the role to a model' "$LINE" '"model":"big"'
# The description is derived from what the user asked for. A measurements log
# has no business holding it.
assert_no_match 'the prompt description is not recorded' "$LINE" 'reply BLUE'
assert_no_match 'the transcript path is not recorded' "$LINE" 'transcriptPath'

# A pin in [subagents.models] wins over [models] default, and the trailing
# comment on that line must not become part of the value.
cat > "$WORK/scout.json" <<'EOF'
{"hookEventName":"subagent_end","subagentType":"scout","exitCode":0,"durationMs":6100,"tokensUsed":6900,"toolCalls":0,"turns":1}
EOF
fire "$WORK/scout.json"
LINE=$(tail -n 1 "$LOG")
assert_match 'a [subagents.models] pin beats the default' "$LINE" '"model":"small"'
assert_no_match 'a trailing comment is not part of the model name' "$LINE" 'recon'

# An agent file can pin its own model in frontmatter, as looker does with
# `model: vision`. Without that step an unpinned looker is recorded as having
# run on the default model, which measures the wrong machine.
mkdir -p "$HOME_DIR/agents"
cat > "$HOME_DIR/agents/looker.md" <<'EOF'
---
name: looker
description: >
  Vision agent. This body mentions model: notthisone on purpose.
capabilityMode: read-only
model: vision
---
Body text, which also says model: definitelynotthisone.
EOF
cat > "$WORK/looker.json" <<'EOF'
{"hookEventName":"subagent_end","subagentType":"looker","exitCode":0,"durationMs":3000,"tokensUsed":9000,"toolCalls":0,"turns":1}
EOF
fire "$WORK/looker.json"
LINE=$(tail -n 1 "$LOG")
assert_match 'agent frontmatter beats [models] default' "$LINE" '"model":"vision"'
assert_no_match 'only the frontmatter is read, never the body' "$LINE" 'notthisone'

# A pin still outranks frontmatter, which is Axon's own precedence.
printf 'looker = "small"\n' >> "$HOME_DIR/config.toml"
fire "$WORK/looker.json"
LINE=$(tail -n 1 "$LOG")
assert_match 'a pin outranks agent frontmatter' "$LINE" '"model":"small"'
# Put the config back for the checks that follow.
sed -i.bak '$d' "$HOME_DIR/config.toml" 2>/dev/null ||
    { sed '$d' "$HOME_DIR/config.toml" > "$WORK/cfg.tmp" && mv "$WORK/cfg.tmp" "$HOME_DIR/config.toml"; }

# --- the ledger Axon 0.3.6+ sends -------------------------------------------
echo
echo "usageByModel"
# Two models in one subagent: the counts sum, and the attributed model is the one
# that generated the most rather than the first or last listed.
cat > "$WORK/ledger.json" <<'EOF'
{"hookEventName":"subagent_end","subagentType":"executor","exitCode":0,"durationMs":41000,"tokensUsed":31200,"toolCalls":6,"turns":9,"usageByModel":[{"model":"quiet","inputTokens":900,"outputTokens":40,"modelCalls":1,"apiDurationMs":300},{"model":"busy","inputTokens":30000,"outputTokens":1200,"modelCalls":9,"apiDurationMs":18000}]}
EOF
fire "$WORK/ledger.json"
LINE=$(tail -n 1 "$LOG")
assert_match 'the payload ledger wins over config attribution' "$LINE" '"model":"busy"'
assert_match 'attribution names its source' "$LINE" '"modelSource":"payload"'
assert_match 'input tokens are summed across models' "$LINE" '"inputTokens":30900'
assert_match 'output tokens are summed across models' "$LINE" '"outputTokens":1240'
assert_match 'model calls are summed' "$LINE" '"modelCalls":10'
assert_match 'API time is summed' "$LINE" '"apiDurationMs":18300'
assert_match 'the model count is recorded' "$LINE" '"modelCount":2'

# A payload with no ledger at all is every Axon before 0.3.6. The config
# fallback must still answer, and must say that it did.
cat > "$WORK/noledger.json" <<'EOF'
{"hookEventName":"subagent_end","subagentType":"scout","exitCode":0,"durationMs":6100,"tokensUsed":6900,"toolCalls":0,"turns":1}
EOF
fire "$WORK/noledger.json"
LINE=$(tail -n 1 "$LOG")
assert_match 'no ledger falls back to config' "$LINE" '"modelSource":"config"'
assert_match 'no ledger still resolves a model' "$LINE" '"model":"small"'
assert_match 'no ledger records zero generated' "$LINE" '"outputTokens":0'
assert_match 'no ledger records no models' "$LINE" '"modelCount":0'

# A bill the child knows is short.
cat > "$WORK/short.json" <<'EOF'
{"hookEventName":"subagent_end","subagentType":"reviewer","exitCode":0,"durationMs":900,"tokensUsed":5000,"toolCalls":0,"turns":1,"usageIncomplete":true,"usageByModel":[{"model":"big","inputTokens":4000,"outputTokens":400,"modelCalls":2,"apiDurationMs":8000}]}
EOF
fire "$WORK/short.json"
LINE=$(tail -n 1 "$LOG")
assert_match 'a short bill is recorded as such' "$LINE" '"usageIncomplete":true'

# --- a missing field stays null, and never becomes zero ----------------------
echo
echo "absent fields"
cat > "$WORK/nostatus.json" <<'EOF'
{"hookEventName":"subagent_end","subagentType":"reviewer","durationMs":100,"tokensUsed":500}
EOF
fire "$WORK/nostatus.json"
LINE=$(tail -n 1 "$LOG")
# Axon reports exitCode only for completed/failed/cancelled. A silent 0 here
# would read as success.
assert_match 'an absent exit code stays null' "$LINE" '"exitCode":null'
assert_match 'an absent tool count stays null' "$LINE" '"toolCalls":null'
assert_no_match 'an absent field never becomes zero' "$LINE" '"exitCode":0'

# --- a hostile error message cannot corrupt the log -------------------------
echo
echo "error text"
# Quotes, a backslash and an escaped newline: written out verbatim this breaks
# the line for every reader that comes after it.
printf '%s\n' '{"hookEventName":"subagent_end","subagentType":"executor","exitCode":1,"durationMs":900,"tokensUsed":7000,"toolCalls":0,"turns":1,"error":"boom: server said \"no\" \\ then \nnewline"}' > "$WORK/bad.json"
fire "$WORK/bad.json"
LINE=$(tail -n 1 "$LOG")
assert_match 'the error is recorded' "$LINE" 'boom: server said'
assert_no_match 'no bare quote survives in the error' "$LINE" 'said \\"no'
if command -v python3 >/dev/null 2>&1; then
    set +e
    PYOUT=$(python3 -c '
import json, sys
bad = 0
for i, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    line = line.strip()
    if not line:
        continue
    try:
        json.loads(line)
    except Exception as e:
        bad += 1
        print("line %d: %s" % (i, e))
print("BAD=%d" % bad)
' "$LOG" 2>&1)
    set -e
    assert_match 'every line in the log is valid JSON' "$PYOUT" 'BAD=0'
else
    pass "JSON validity check skipped (no python3)"
fi

# --- the hook never disturbs the run ----------------------------------------
echo
echo "the hook never fails a run"
printf 'this is not json at all\n' > "$WORK/garbage.json"
set +e
AXON_HOME="$HOME_DIR" sh "$HOME_DIR/hooks/bin/subagent-telemetry.sh" < "$WORK/garbage.json" >"$WORK/garbage.out" 2>&1
GCODE=$?
set -e
assert_eq 'a garbage payload still exits 0' "$GCODE" "0"
assert_eq 'a garbage payload prints nothing' "$(cat "$WORK/garbage.out")" ""

: > "$WORK/empty.json"
set +e
AXON_HOME="$HOME_DIR" sh "$HOME_DIR/hooks/bin/subagent-telemetry.sh" < "$WORK/empty.json" >/dev/null 2>&1
ECODE=$?
set -e
assert_eq 'an empty payload exits 0' "$ECODE" "0"

# With no config to read, the model is unknown rather than guessed.
NOCFG="$WORK/nocfg"
mkdir -p "$NOCFG/hooks/bin" "$NOCFG/hooks/lib"
cp "$HOOK" "$NOCFG/hooks/bin/subagent-telemetry.sh"
cp "$REPO_ROOT/tools/lib/probe.sh" "$NOCFG/hooks/lib/probe.sh"
set +e
AXON_HOME="$NOCFG" sh "$NOCFG/hooks/bin/subagent-telemetry.sh" < "$WORK/ok.json" >/dev/null 2>&1
NCODE=$?
set -e
assert_eq 'no config still exits 0' "$NCODE" "0"
assert_match 'no config means no model, not a guessed one' \
    "$(head -n 1 "$NOCFG/telemetry/subagents.jsonl")" '"model":null'

# --- the report --------------------------------------------------------------
echo
echo "argument handling"
run_rep --help
assert_eq '--help exits 0' "$CODE" "0"
assert_match '--help lists --role' "$OUT" '\-\-role'
run_rep --version
assert_match '--version prints a semver' "$OUT" 'oh-my-axon [0-9]+\.[0-9]+\.[0-9]+'
run_rep --bogus
assert_eq 'unknown flag is refused (exit 2)' "$CODE" "2"
assert_match 'unknown flag names itself' "$OUT" 'unknown argument: --bogus'
run_rep --log "$WORK/does-not-exist.jsonl"
assert_eq 'a missing log exits 2' "$CODE" "2"
assert_match 'a missing log says how to get one' "$OUT" '\-\-with-telemetry'

# --- what the report will and will not claim --------------------------------
echo
echo "report findings"
cat > "$WORK/cfg.toml" <<'EOF'
[model.big]
model = "big-70b"
base_url = "http://127.0.0.1:1/v1"
context_window = 131072

[model.nowindow]
model = "nowindow-12b"
base_url = "http://127.0.0.1:2/v1"

[models]
default = "big"
EOF
cat > "$WORK/log.jsonl" <<'EOF'
{"ts":"2026-07-29T22:17:43Z","subagentType":"executor","model":"big","exitCode":0,"durationMs":41200,"tokensUsed":18400,"toolCalls":6,"turns":9,"error":""}
{"ts":"2026-07-29T22:18:43Z","subagentType":"executor","model":"big","exitCode":1,"durationMs":9000,"tokensUsed":7000,"toolCalls":0,"turns":1,"error":"connection refused"}
{"ts":"2026-07-29T22:19:43Z","subagentType":"crammed","model":"big","exitCode":0,"durationMs":60000,"tokensUsed":120000,"toolCalls":9,"turns":14,"error":""}
{"ts":"2026-07-29T22:20:43Z","subagentType":"guessy","model":"nowindow","exitCode":0,"durationMs":5000,"tokensUsed":190000,"toolCalls":1,"turns":2,"error":""}
{"ts":"2026-07-29T22:21:43Z","subagentType":"ghosted","model":"vanished","exitCode":0,"durationMs":5000,"tokensUsed":190000,"toolCalls":1,"turns":2,"error":""}
{"ts":"2026-07-29T22:22:43Z","subagentType":"unattributed","model":null,"exitCode":0,"durationMs":5000,"tokensUsed":20000,"toolCalls":1,"turns":2,"error":""}
{"ts":"2026-07-29T22:23:43Z","subagentType":"stopped","model":"big","exitCode":-1,"durationMs":2000,"tokensUsed":7000,"toolCalls":0,"turns":1,"error":""}
EOF
run_rep --log "$WORK/log.jsonl" --config "$WORK/cfg.toml"
assert_eq 'a log with problems exits 1' "$CODE" "1"
assert_match 'the table lists a role' "$OUT" 'executor .*big'
assert_match 'failures are counted and explained' "$OUT" 'executor failed 1 of 2 run\(s\). Most recent error: connection refused'
assert_match 'a cancelled run is counted apart from a failure' "$OUT" 'stopped .*0/0/1'

# The whole point of the tool: 120000 of a 131072 window is 92%, over the 85%
# at which Axon compacts, and the window came from the config, so this is a
# finding rather than a guess.
assert_match 'context pressure against a known window is a problem' "$OUT" 'crammed peaked at 120.0k of big'
assert_match 'the compaction threshold is named' "$OUT" 'Axon compacts at 85%'

# The same pressure against a window nobody set is a note, not a finding.
assert_match 'pressure against an assumed window is only a note' "$OUT" 'guessy peaked at 190.0k, which would be'
assert_no_match 'an assumed window never produces a compaction finding' "$OUT" 'guessy peaked at 190.0k of'

# A model absent from the catalog has no window at all, so no percentage.
assert_match 'a vanished model is called out' "$OUT" 'ghosted ran on "vanished", which is not in your catalog'
assert_match 'a role with no attribution is reported' "$OUT" '1 record\(s\) carry no model'

# Tokens per second must never be derived from tokensUsed. These records carry no
# ledger at all, so the column has to stay empty rather than fall back to it.
assert_match 'the table offers a TOK/S column' "$OUT" 'TOK/S'
assert_no_match 'no rate is invented without a ledger' "$OUT" '[0-9]+ +18\.4k'
assert_match 'a ledgerless role says why it has no rate' "$OUT" 'no ledger \(Axon before 0\.3\.6\)'

# --- the rate itself --------------------------------------------------------
echo
echo "throughput"
cat > "$WORK/rate.jsonl" <<'EOF'
{"ts":"r1","subagentType":"fast","model":"big","modelSource":"payload","exitCode":0,"durationMs":9000,"tokensUsed":8000,"toolCalls":0,"turns":1,"inputTokens":7000,"outputTokens":600,"modelCalls":1,"apiDurationMs":6000,"modelCount":1,"usageIncomplete":false,"error":""}
{"ts":"r2","subagentType":"fast","model":"big","modelSource":"payload","exitCode":0,"durationMs":9000,"tokensUsed":8000,"toolCalls":0,"turns":1,"inputTokens":7000,"outputTokens":400,"modelCalls":1,"apiDurationMs":8000,"modelCount":1,"usageIncomplete":false,"error":""}
{"ts":"r3","subagentType":"tiny","model":"big","modelSource":"payload","exitCode":0,"durationMs":3400,"tokensUsed":6641,"toolCalls":0,"turns":1,"inputTokens":6638,"outputTokens":3,"modelCalls":1,"apiDurationMs":3319,"modelCount":1,"usageIncomplete":false,"error":""}
{"ts":"r4","subagentType":"shortbill","model":"big","modelSource":"payload","exitCode":0,"durationMs":9000,"tokensUsed":8000,"toolCalls":0,"turns":1,"inputTokens":4000,"outputTokens":400,"modelCalls":2,"apiDurationMs":8000,"modelCount":1,"usageIncomplete":true,"error":""}
{"ts":"r5","subagentType":"mixed","model":"a","modelSource":"payload","exitCode":0,"durationMs":9000,"tokensUsed":8000,"toolCalls":0,"turns":1,"inputTokens":7000,"outputTokens":600,"modelCalls":1,"apiDurationMs":6000,"modelCount":2,"usageIncomplete":false,"error":""}
{"ts":"r6","subagentType":"mixed","model":"b","modelSource":"payload","exitCode":0,"durationMs":9000,"tokensUsed":8000,"toolCalls":0,"turns":1,"inputTokens":7000,"outputTokens":600,"modelCalls":1,"apiDurationMs":6000,"modelCount":2,"usageIncomplete":false,"error":""}
EOF
run_rep --log "$WORK/rate.jsonl" --config "$WORK/cfg.toml"
# 600/6000ms = 100/s and 400/8000ms = 50/s; the median of the two is 75.
assert_match 'the rate is the median of per-run rates' "$OUT" 'fast .* 75 '
# 3 tokens over 3.3s is prefill wearing a throughput costume.
assert_match 'a tiny generation yields no rate' "$OUT" 'tiny .* - '
assert_match 'and the exclusion is explained' "$OUT" 'tiny has no TOK/S -- every run was excluded; 1 had too little generation to time'
# A short bill under-counts the numerator, so the rate would read low.
assert_match 'a short bill is excluded from the rate' "$OUT" 'shortbill has no TOK/S -- every run was excluded; 1 reported a short bill'
assert_match 'and its totals are called a floor' "$OUT" 'shortbill reported an incomplete bill'
# Two models under one role: a rate is still shown, but not as one model's speed.
assert_match 'a mixed-model role warns about its rate' "$OUT" 'mixed mixes 2 models, so its TOK/S is a median across different machines'
# The forbidden number: nothing may divide tokensUsed by a duration.
assert_no_match 'tokensUsed is never used as a rate numerator' "$OUT" 'fast .* (888|889|1333) '

echo
echo "filtering and quiet"
run_rep --log "$WORK/log.jsonl" --config "$WORK/cfg.toml" --role stopped
assert_eq 'a clean role exits 0' "$CODE" "0"
assert_match 'a clean role says so' "$OUT" 'No problems found'
assert_no_match 'a role filter excludes other roles' "$OUT" 'crammed'
run_rep --log "$WORK/log.jsonl" --config "$WORK/cfg.toml" --role nosuchrole
assert_eq 'an unknown role exits 1' "$CODE" "1"
assert_match 'an unknown role is explained' "$OUT" 'no records for role "nosuchrole"'
run_rep --log "$WORK/log.jsonl" --config "$WORK/cfg.toml" --quiet
assert_no_match '--quiet prints no table' "$OUT" 'OF WINDOW'
assert_match '--quiet still prints problems' "$OUT" 'connection refused'

# A log with no usable config still reports what it measured, and simply has
# no window to compare against.
run_rep --log "$WORK/log.jsonl" --config "$WORK/does-not-exist.toml"
assert_match 'a missing config does not stop the report' "$OUT" 'executor'
assert_no_match 'a missing config invents no percentage' "$OUT" '9[0-9]%'

# --- overflow files are read back -------------------------------------------
echo
echo "overflow"
mkdir -p "$WORK/ov"
cp "$WORK/log.jsonl" "$WORK/ov/subagents.jsonl"
cat > "$WORK/ov/subagents-overflow-1234.jsonl" <<'EOF'
{"ts":"2026-07-29T22:24:43Z","subagentType":"raced","model":"big","exitCode":0,"durationMs":1000,"tokensUsed":8000,"toolCalls":0,"turns":1,"error":""}
EOF
run_rep --log "$WORK/ov/subagents.jsonl" --config "$WORK/cfg.toml"
assert_match 'a record in an overflow file is not lost' "$OUT" 'raced'
assert_match 'the overflow record is counted once' "$OUT" 'raced .* 1 '

# Pointing --log straight at an overflow file must not read it twice, or every
# number in the report doubles.
run_rep --log "$WORK/ov/subagents-overflow-1234.jsonl" --config "$WORK/cfg.toml"
assert_match 'an overflow file named directly is read once' "$OUT" '1 run\(s\) across 1 role'

# --- the report writes nothing ----------------------------------------------
echo
echo "side effects"
before=$(cksum < "$WORK/log.jsonl")
run_rep --log "$WORK/log.jsonl" --config "$WORK/cfg.toml"
assert_eq 'the report does not modify the log it reads' "$(cksum < "$WORK/log.jsonl")" "$before"

rm -rf "$WORK"
summary "subagents: all checks passed"
