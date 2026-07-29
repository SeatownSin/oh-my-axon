#!/bin/sh
# oh-my-axon fleet doctor (Linux / WSL / macOS).
#
#   tools/doctor.sh                  check every model in ~/.axon/config.toml
#   tools/doctor.sh --config PATH    check a specific config file
#   tools/doctor.sh --quiet          print only problems
#   tools/doctor.sh --include-remote check off-box endpoints too
#   tools/doctor.sh --generate       also send one completion per model
#   tools/doctor.sh --help           list every flag
#
# Answers one question before you start a long run: is the fleet your config
# describes actually there? A model that is down, swapped, or lying about its
# context window fails in the middle of a pipeline, as an inference error that
# says nothing about the real cause.
#
# Exit codes: 0 all clear, 1 at least one problem, 2 usage error.
#
# Axon ships `memory doctor` and `mcp doctor`. Neither looks at models, which
# is why this exists rather than extending one of those.
#
# Off-box endpoints are not contacted unless --include-remote: this
# distribution does not reach off your machine on its own.
set -eu

OMA_VERSION="0.1.5"
AXON_HOME="${AXON_HOME:-$HOME/.axon}"
CONFIG="$AXON_HOME/config.toml"
QUIET=0
INCLUDE_REMOTE=0
GENERATE=0

TOOLS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=tools/lib/probe.sh
. "$TOOLS_DIR/lib/probe.sh"

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --quiet|-q) QUIET=1 ;;
        --include-remote) INCLUDE_REMOTE=1 ;;
        --generate) GENERATE=1 ;;
        --config)
            [ $# -ge 2 ] || { echo "doctor: --config needs a path" >&2; exit 2; }
            CONFIG="$2"
            shift
            ;;
        --config=*) CONFIG="${1#--config=}" ;;
        --version) echo "oh-my-axon $OMA_VERSION"; exit 0 ;;
        -h|--help) usage ;;
        *)
            echo "doctor: unknown argument: $1" >&2
            echo "  Run tools/doctor.sh --help to see the flags this accepts." >&2
            exit 2
            ;;
    esac
    shift
done

if ! command -v curl >/dev/null 2>&1; then
    echo "doctor: curl is not on PATH. Nothing can be checked without it." >&2
    exit 2
fi
if [ ! -f "$CONFIG" ]; then
    echo "doctor: no config at $CONFIG" >&2
    echo "  Run \`axon\` once so the first-run wizard detects your servers," >&2
    echo "  or point at a config with --config PATH." >&2
    exit 2
fi

ALL=$(probe_parse_catalog "$CONFIG")
if [ -z "$ALL" ]; then
    echo "doctor: $CONFIG defines no [model.*] entries." >&2
    echo "  Run \`axon\` once to let the wizard detect your servers, or see" >&2
    echo "  config/config.toml.snippet for hand configuration." >&2
    exit 2
fi

field() { printf '%s\n' "$1" | cut -f "$2"; }

# Which catalog keys a role actually depends on, so a broken model can be
# reported as "this breaks something" rather than just "this is down".
# Read from [models] and [subagents.models]; a key nobody references is
# reported, but does not by itself fail the run.
roles_using() {
    awk -v want="$1" '
        /^[[:space:]]*\[models\]/            { sec = "models";    next }
        /^[[:space:]]*\[subagents\.models\]/ { sec = "subagents"; next }
        /^[[:space:]]*\[/                    { sec = "";          next }
        sec != "" && /=/ {
            line = $0
            sub(/[[:space:]]*#.*$/, "", line)
            split(line, kv, "=")
            k = kv[1]; v = kv[2]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            gsub(/^[[:space:]]*["'"'"']|["'"'"'][[:space:]]*$/, "", v)
            gsub(/[[:space:]]/, "", v)
            if (v == want && k != "") out = (out == "" ? k : out ", " k)
        }
        END { print out }
    ' "$2"
}

PROBLEMS=""
ROWS=""
CHECKED=0

note() { PROBLEMS="$PROBLEMS$1
"; }

OLDIFS=$IFS
IFS='
'
for REC in $ALL; do
    IFS=$OLDIFS
    KEY=$(field "$REC" 1)
    ISLOCAL=$(field "$REC" 4)
    URL=$(field "$REC" 6)
    WIRE=$(field "$REC" 7)
    CFGCTX=$(field "$REC" 8)
    USED=$(roles_using "$KEY" "$CONFIG")

    if [ -z "$URL" ]; then
        ROWS="$ROWS  SKIP   $KEY -- no base_url, nothing to contact
"
        IFS='
'
        continue
    fi
    if [ "$INCLUDE_REMOTE" != "1" ] && [ "$ISLOCAL" != "1" ]; then
        ROWS="$ROWS  SKIP   $KEY -- off-box, not contacted
"
        IFS='
'
        continue
    fi

    CHECKED=$((CHECKED + 1))
    AUTH=$(probe_auth_header "$CONFIG" "$KEY")
    probe_http_get "$(probe_models_endpoint "$URL")" "$AUTH"
    CODE=$P_CODE
    BODY=$P_BODY
    IDS=$(probe_served_ids "$BODY")

    STATUS=""
    case "$CODE" in
        000) STATUS="DOWN"
             note "$KEY is unreachable at $URL." ;;
        401|403)
             STATUS="AUTH"
             note "$KEY refused the credentials in your config (HTTP $CODE). Check api_key, or set no_auth = true." ;;
        2*)  if [ -n "$WIRE" ] && printf '%s\n' "$IDS" | grep -Fxq "$WIRE"; then
                 STATUS="UP"
             else
                 STATUS="STALE"
                 SERVED=$(printf '%s' "$IDS" | tr '\n' ',' | sed 's/,$//; s/,/, /g')
                 if [ -n "$SERVED" ]; then
                     note "$KEY points at a server that is up but serving $SERVED, not \"$WIRE\"."
                 else
                     note "$KEY points at a server that is up but serving nothing."
                 fi
             fi ;;
        *)   STATUS="DOWN"
             note "$KEY returned HTTP $CODE from $URL." ;;
    esac

    if [ -n "$USED" ] && [ "$STATUS" != "UP" ]; then
        note "  ^ this breaks: $USED"
    fi

    # Context window: the single most common local-model misconfiguration.
    # Axon assumes 200000 when unset and compacts at 85% of whatever is
    # claimed, so a wrong number compacts at the wrong time.
    if [ "$STATUS" = "UP" ]; then
        SRVCTX=$(probe_served_ctx "$BODY" "$WIRE")
        if [ -n "$SRVCTX" ] && [ "$CFGCTX" = "0" ]; then
            note "$KEY sets no context_window; the server reports $SRVCTX. Axon assumes 200000."
        elif [ -n "$SRVCTX" ] && [ "$CFGCTX" != "$SRVCTX" ]; then
            note "$KEY claims context_window = $CFGCTX; the server reports $SRVCTX."
        fi
    fi

    # Reasoning leak: if the model's thoughts arrive inside `content` instead
    # of a field of their own, every stored turn carries the whole chain of
    # thought. One tiny completion is enough to tell.
    if [ "$STATUS" = "UP" ] && [ "$GENERATE" = "1" ]; then
        # Send the request the way Axon would -- with this model's configured
        # chat_template_kwargs. Asking bare tests a configuration nobody uses.
        KW=$(probe_chat_template_kwargs "$CONFIG" "$KEY")
        if [ -n "$KW" ]; then
            REQ=$(printf '{"model":"%s","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":64,"stream":false,"chat_template_kwargs":%s}' "$WIRE" "$KW")
        else
            REQ=$(printf '{"model":"%s","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":64,"stream":false}' "$WIRE")
        fi
        # 120s, because the first completion against an idle server can trigger
        # a model load. A timeout here means "slow or loading", not "broken".
        probe_http_post "${URL%/}/chat/completions" "$AUTH" "$REQ" 120
        case "$P_CODE" in
            2*) if printf '%s' "$P_BODY" | grep -q '</think>\|<think>'; then
                    note "$KEY leaks reasoning into the reply text even with its configured chat_template_kwargs. Set enable_thinking on [model.$KEY] so the server parses it out."
                fi ;;
            000) note "$KEY served /models but did not finish a completion within 120s. That is usually a cold model load, not a fault -- re-run once it is warm." ;;
            *)  note "$KEY served /models but returned HTTP $P_CODE from /chat/completions." ;;
        esac
    fi

    ROWS="$ROWS  $(printf '%-5s' "$STATUS")  $KEY -- $URL
"
    IFS='
'
done
IFS=$OLDIFS

if [ "$QUIET" != "1" ]; then
    echo "oh-my-axon doctor -- $CHECKED endpoint(s) contacted from $CONFIG"
    echo
    printf '%s' "$ROWS"
    echo
fi

if [ -z "$PROBLEMS" ]; then
    [ "$QUIET" = "1" ] || echo "No problems found."
    exit 0
fi

echo "Problems:"
printf '%s' "$PROBLEMS"
exit 1
