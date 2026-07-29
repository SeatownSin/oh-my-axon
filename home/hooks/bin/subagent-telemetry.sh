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
# The agents directory is passed too, because a [subagents.models] pin is not
# the only way a role gets a model: an agent file can pin one in its own
# frontmatter, as looker does with `model: vision`. Project agents shadow the
# installed ones, and cwd is the workspace root, so that directory is offered
# first -- an agent further up the tree is not followed.
MODEL=""
_lib="$AXON_HOME/hooks/lib/probe.sh"
if [ -f "$_lib" ] && [ -f "$AXON_HOME/config.toml" ]; then
    # shellcheck source=tools/lib/probe.sh
    . "$_lib" 2>/dev/null || true
    if command -v probe_role_model >/dev/null 2>&1; then
        _agents="$AXON_HOME/agents"
        [ -f "./.axon/agents/$TYPE.md" ] && _agents="./.axon/agents"
        MODEL=$(probe_role_model "$AXON_HOME/config.toml" "$TYPE" "$_agents" 2>/dev/null || true)
    fi
fi
if [ -n "$MODEL" ]; then
    MODEL_JSON="\"$(printf '%s' "$MODEL" | strip_unsafe)\""
else
    MODEL_JSON="null"
fi

# A missing number stays null rather than becoming 0. `exitCode` is absent for
# any status Axon does not map to completed/failed/cancelled, and a silent 0
# there would read as success.
n() { if [ -n "$1" ]; then printf '%s' "$1"; else printf 'null'; fi; }

mkdir -p "$OUT_DIR" 2>/dev/null || exit 0

# A single write of a short line is atomic on an O_APPEND descriptor, so
# subagents finishing together interleave records, never characters.
printf '{"ts":"%s","subagentType":"%s","model":%s,"exitCode":%s,"durationMs":%s,"tokensUsed":%s,"toolCalls":%s,"turns":%s,"error":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(printf '%s' "$TYPE" | strip_unsafe)" \
    "$MODEL_JSON" \
    "$(n "$EXIT_CODE")" \
    "$(n "$DURATION")" \
    "$(n "$TOKENS")" \
    "$(n "$CALLS")" \
    "$(n "$TURNS")" \
    "$ERR" \
    >> "$OUT" 2>/dev/null || true

exit 0
