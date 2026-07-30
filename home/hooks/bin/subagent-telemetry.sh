#!/bin/sh
# oh-my-axon subagent telemetry (SubagentStop).
#
# Appends one JSON line per finished subagent to
# $AXON_HOME/telemetry/subagents.jsonl, which tools/subagents.sh reads back.
# Nothing leaves this machine, and nothing here is ever sent anywhere.
#
# Never blocks, never complains, always exits 0: a hook that fails loudly at
# the end of a subagent turns a successful run into a confusing one, and a
# telemetry hook has no business doing that.
#
# The prompt text is deliberately NOT recorded. The payload carries the
# subagent's `description`, which is free text derived from what you asked
# for; keeping it out means this log holds measurements, never content.

payload=$(cat)
[ -n "$payload" ] || exit 0

AXON_HOME="${AXON_HOME:-$HOME/.axon}"
OUT_DIR="$AXON_HOME/telemetry"
OUT="$OUT_DIR/subagents.jsonl"

# One number out of the flat payload, or empty. Every field this reads is a
# top-level scalar, so a regex is enough and a JSON parser is one more thing
# that has to be installed for a hook to work.
jnum() {
    printf '%s' "$payload" |
        sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9]\{1,\}\).*/\1/p' |
        head -1
}

jstr() {
    printf '%s' "$payload" |
        sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        head -1
}

# Delete the two characters that would break the JSON line being built: a double
# quote and a backslash. Inside single quotes `\\` is how one backslash is
# written for tr, which shellcheck reads as a mistaken quote escape -- hence the
# directive, in one place rather than at all three call sites.
strip_unsafe() {
    # shellcheck disable=SC1003
    tr -d '"\\'
}

# An error message is free text that may carry quotes, backslashes or newlines.
# Stripping those rather than escaping them keeps the output valid JSON on every
# path: a mangled message is a lesser fault than a log file no reader can parse.
jerr() {
    printf '%s' "$payload" |
        tr '\n\r\t' '   ' |
        sed -n 's/.*"error"[[:space:]]*:[[:space:]]*"//p' |
        sed 's/",".*$//; s/"}[[:space:]]*$//; s/"$//' |
        sed 's/\\[nrt]/ /g' |
        strip_unsafe |
        cut -c1-200
}

# The `usageByModel` array Axon 0.3.6+ sends: the child's own billing ledger,
# one object per model it called. Emits one TAB-separated summary line --
#   model <TAB> modelCount <TAB> inputTokens <TAB> outputTokens
#         <TAB> modelCalls <TAB> apiDurationMs
# -- with the counts summed and `model` set to whichever entry generated the
# most, since that is the one that did the work. Empty model means the payload
# carried no ledger, which is every Axon before 0.3.6.
#
# This is the one field a regex cannot read, because the keys repeat once per
# model and `jnum`'s greedy match would silently return the last occurrence
# rather than a total. awk is already required by the shared parser.
usage_summary() {
    printf '%s' "$payload" | tr '\n\r\t' '   ' | awk '
        function num(s, key,   pat, t) {
            pat = "\"" key "\"[[:space:]]*:[[:space:]]*"
            if (!match(s, pat)) return 0
            t = substr(s, RSTART + RLENGTH)
            if (match(t, /^-?[0-9]+/)) return substr(t, RSTART, RLENGTH) + 0
            return 0
        }
        function str(s, key,   pat, t, q) {
            pat = "\"" key "\"[[:space:]]*:[[:space:]]*\""
            if (!match(s, pat)) return ""
            t = substr(s, RSTART + RLENGTH)
            q = index(t, "\"")
            return (q > 0) ? substr(t, 1, q - 1) : ""
        }
        {
            if (!match($0, /"usageByModel"[[:space:]]*:[[:space:]]*\[/)) {
                print "\t0\t0\t0\t0\t0"
                exit
            }
            rest = substr($0, RSTART + RLENGTH)
            end = index(rest, "]")
            arr = (end > 0) ? substr(rest, 1, end - 1) : rest
            n = split(arr, objs, "}")
            best = ""; bestout = -1; count = 0
            for (i = 1; i <= n; i++) {
                if (objs[i] !~ /"model"/) continue
                count++
                o = num(objs[i], "outputTokens")
                inp += num(objs[i], "inputTokens")
                out += o
                calls += num(objs[i], "modelCalls")
                api += num(objs[i], "apiDurationMs")
                if (o > bestout) { bestout = o; best = str(objs[i], "model") }
            }
            printf "%s\t%d\t%d\t%d\t%d\t%d\n", best, count, inp, out, calls, api
        }
    '
}

TYPE=$(jstr subagentType)
[ -n "$TYPE" ] || TYPE="unknown"
EXIT_CODE=$(jnum exitCode)
DURATION=$(jnum durationMs)
TOKENS=$(jnum tokensUsed)
CALLS=$(jnum toolCalls)
TURNS=$(jnum turns)
ERR=$(jerr)

# Which model this role ran on, resolved now rather than at report time: a log
# outlives the config that produced it, so a record that needs a mutable file to
# be interpreted is a misattribution waiting to happen. The shared parser does
# the reading; if it is absent the field is null, which the reporter handles.
# Resolved from AXON_HOME rather than from $0: the installed hook command is a
# path relative to the descriptor, and this script runs with cwd at the
# workspace root, so anything derived from $0 could point into the project being
# worked on instead of into the install.
USAGE=$(usage_summary)
U_MODEL=$(printf '%s' "$USAGE" | cut -f 1)
U_COUNT=$(printf '%s' "$USAGE" | cut -f 2)
U_IN=$(printf '%s' "$USAGE" | cut -f 3)
U_OUT=$(printf '%s' "$USAGE" | cut -f 4)
U_CALLS=$(printf '%s' "$USAGE" | cut -f 5)
U_API=$(printf '%s' "$USAGE" | cut -f 6)

# A bill the child knows is short. Recorded so the reporter can call its totals a
# floor instead of a measurement.
INCOMPLETE=false
case "$payload" in
    *'"usageIncomplete"'*'true'*) INCOMPLETE=true ;;
esac

# Which model this role ran on. The payload's ledger wins outright when present:
# it says what the child ACTUALLY called, where the config only says what it
# should have. Resolving from config remains the fallback for Axon before 0.3.6,
# and `modelSource` records which one answered so a reader is never left guessing
# whether a name is authoritative.
#
# The agents directory matters to that fallback, because a [subagents.models] pin
# is not the only way a role gets a model: an agent file can pin one in its own
# frontmatter, as looker does with `model: vision`. Project agents shadow the
# installed ones, and cwd is the workspace root, so that directory is offered
# first -- an agent further up the tree is not followed.
MODEL=""
MODEL_SRC=""
if [ -n "$U_MODEL" ]; then
    MODEL="$U_MODEL"
    MODEL_SRC="payload"
else
    _lib="$AXON_HOME/hooks/lib/probe.sh"
    if [ -f "$_lib" ] && [ -f "$AXON_HOME/config.toml" ]; then
        # shellcheck source=tools/lib/probe.sh
        . "$_lib" 2>/dev/null || true
        if command -v probe_role_model >/dev/null 2>&1; then
            _agents="$AXON_HOME/agents"
            [ -f "./.axon/agents/$TYPE.md" ] && _agents="./.axon/agents"
            MODEL=$(probe_role_model "$AXON_HOME/config.toml" "$TYPE" "$_agents" 2>/dev/null || true)
            [ -n "$MODEL" ] && MODEL_SRC="config"
        fi
    fi
fi
if [ -n "$MODEL" ]; then
    MODEL_JSON="\"$(printf '%s' "$MODEL" | strip_unsafe)\""
else
    MODEL_JSON="null"
fi
if [ -n "$MODEL_SRC" ]; then
    MODEL_SRC_JSON="\"$MODEL_SRC\""
else
    MODEL_SRC_JSON="null"
fi

# A missing number stays null rather than becoming 0. `exitCode` is absent for
# any status Axon does not map to completed/failed/cancelled, and a silent 0
# there would read as success.
n() { if [ -n "$1" ]; then printf '%s' "$1"; else printf 'null'; fi; }

mkdir -p "$OUT_DIR" 2>/dev/null || exit 0

# A single write of a short line is atomic on an O_APPEND descriptor, so
# subagents finishing together interleave records, never characters.
printf '{"ts":"%s","subagentType":"%s","model":%s,"modelSource":%s,"exitCode":%s,"durationMs":%s,"tokensUsed":%s,"toolCalls":%s,"turns":%s,"inputTokens":%s,"outputTokens":%s,"modelCalls":%s,"apiDurationMs":%s,"modelCount":%s,"usageIncomplete":%s,"error":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(printf '%s' "$TYPE" | strip_unsafe)" \
    "$MODEL_JSON" \
    "$MODEL_SRC_JSON" \
    "$(n "$EXIT_CODE")" \
    "$(n "$DURATION")" \
    "$(n "$TOKENS")" \
    "$(n "$CALLS")" \
    "$(n "$TURNS")" \
    "$(n "$U_IN")" \
    "$(n "$U_OUT")" \
    "$(n "$U_CALLS")" \
    "$(n "$U_API")" \
    "$(n "$U_COUNT")" \
    "$INCOMPLETE" \
    "$ERR" \
    >> "$OUT" 2>/dev/null || true

exit 0
