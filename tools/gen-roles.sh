#!/bin/sh
# oh-my-axon role-preset generator (Linux / WSL / macOS).
#
#   tools/gen-roles.sh                  read the catalog in ~/.axon/config.toml
#   tools/gen-roles.sh --probe          ask your servers what they are serving
#   tools/gen-roles.sh --config PATH    read a specific config file
#   tools/gen-roles.sh --include-remote consider off-box models too
#
# Prints a [models] + [subagents.models] block that maps oh-my-axon's agents
# onto the models you actually have. Writes nothing, anywhere: review the
# output and paste the parts you want into ~/.axon/config.toml yourself.
#
# Models served from outside your machine or LAN are skipped by default: a
# role quietly pointed at a hosted endpoint would send your code off-box,
# which is the one thing this distribution promises not to do.
#
# The assignments are heuristics over model names, not measurements. They are
# a starting point to edit, not an answer.
set -eu

OMA_VERSION="0.1.3"
AXON_HOME="${AXON_HOME:-$HOME/.axon}"
CONFIG="$AXON_HOME/config.toml"
PROBE=0
INCLUDE_REMOTE=0

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --probe) PROBE=1 ;;
        --include-remote) INCLUDE_REMOTE=1 ;;
        --config)
            [ $# -ge 2 ] || { echo "gen-roles: --config needs a path" >&2; exit 2; }
            CONFIG="$2"
            shift
            ;;
        --config=*) CONFIG="${1#--config=}" ;;
        -h|--help) usage ;;
        *) echo "gen-roles: unknown argument: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done

if [ ! -f "$CONFIG" ]; then
    echo "gen-roles: no config at $CONFIG" >&2
    echo "  Run \`axon\` once so the first-run wizard detects your servers," >&2
    echo "  or point at a config with --config PATH." >&2
    exit 1
fi

# Shared catalog + endpoint probing, also used by doctor. Resolved relative to
# this script so the tool still runs from any cwd inside a checkout.
TOOLS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=tools/lib/probe.sh
. "$TOOLS_DIR/lib/probe.sh"

# ---------------------------------------------------------------------------
# Parse the catalog. Emits one TAB-separated record per [model.<key>] section:
#   key <TAB> size-rank <TAB> is-vision <TAB> is-local <TAB> label
#       <TAB> base-url <TAB> wire-id <TAB> context-window
#
# Credentials are deliberately NOT carried here. `api_key` is read only inside
# the probe, by `section_value`, so no formatting or reporting path can reach a
# secret and print it into a snippet the user is about to paste somewhere.
#
# size-rank is a parameter count in billions scraped from the section key, the
# wire `model` id, or the display `name` -- whichever carries one. "8x7b" style
# MoE names multiply out. 0 means "no size found anywhere", which sorts last so
# an unlabelled model never wins the "biggest" slot by accident.
#
# is-local is decided from base_url: loopback, RFC1918, mDNS/LAN suffixes and
# bare hostnames count as local; anything else is off-box. A missing base_url
# means a vendor-hosted catalog entry, which is off-box by definition.
# ---------------------------------------------------------------------------
parse_catalog() { probe_parse_catalog "$1"; }

ALL=$(parse_catalog "$CONFIG")

if [ -z "$ALL" ]; then
    echo "gen-roles: $CONFIG defines no [model.*] entries." >&2
    echo "  Run \`axon\` once to let the wizard detect your servers, or see" >&2
    echo "  config/config.toml.snippet for hand configuration." >&2
    exit 1
fi

TAB=$(printf '\t')
field() { printf '%s\n' "$1" | cut -f "$2"; }

if [ "$INCLUDE_REMOTE" = "1" ]; then
    CATALOG="$ALL"
    SKIPPED=""
else
    CATALOG=$(printf '%s\n' "$ALL" | awk -F'\t' '$4 == 1')
    SKIPPED=$(printf '%s\n' "$ALL" | awk -F'\t' '$4 == 0')
fi

if [ -z "$CATALOG" ]; then
    echo "gen-roles: every [model.*] entry in $CONFIG is served off-box." >&2
    echo "  Nothing local to assign. Start a local server and re-run, or pass" >&2
    echo "  --include-remote to use the hosted entries anyway." >&2
    exit 1
fi

# Biggest and smallest non-vision models. Ties break on the catalog key so the
# output is stable across runs; a single-model catalog puts the same key in
# both slots, which is correct rather than a degenerate case.
NONVISION=$(printf '%s\n' "$CATALOG" | awk -F'\t' '$3 == 0')
VISION=$(printf '%s\n' "$CATALOG" | awk -F'\t' '$3 == 1' | sort -t"$TAB" -k2,2nr -k1,1 | head -n 1)

if [ -z "$NONVISION" ]; then
    # Vision-only catalog: use it for everything rather than emitting nothing.
    NONVISION="$VISION"
fi

BIG=$(printf '%s\n' "$NONVISION" | sort -t"$TAB" -k2,2nr -k1,1 | head -n 1)
SMALL=$(printf '%s\n' "$NONVISION" | sort -t"$TAB" -k2,2n -k1,1 | head -n 1)

BIG_KEY=$(field "$BIG" 1)
BIG_LABEL=$(field "$BIG" 5)
SMALL_KEY=$(field "$SMALL" 1)
SMALL_LABEL=$(field "$SMALL" 5)
VISION_KEY=$(field "$VISION" 1)
VISION_LABEL=$(field "$VISION" 5)

MODEL_COUNT=$(printf '%s\n' "$CATALOG" | wc -l | tr -d ' ')
TIERED=0
[ "$BIG_KEY" != "$SMALL_KEY" ] && TIERED=1

# ---------------------------------------------------------------------------
# Optional probe.
#
# Asks the endpoints your catalog ALREADY points at whether they are up, which
# ids they are serving right now, and what context length they report back. It
# does not guess ports: finding servers you have not configured yet belongs to
# the first-run wizard (`axon`), which sweeps the LAN as well, and a second
# detector here would only drift from it. Guessing is also simply wrong often
# enough to matter -- an LM Studio server on a high port is invisible to it,
# and so is every model served from another box.
#
# Off-box endpoints are not contacted unless --include-remote, for the same
# reason they are not assigned: this distribution does not reach off your
# machine on its own.
#
# Probing NEVER changes the assignments below. Those come from your config
# alone, so a server that happens to be down right now cannot silently rewrite
# your model mapping -- it gets reported instead.
# ---------------------------------------------------------------------------

# One value out of one [model.<key>] section, or empty. Credentials are read
# here and nowhere else, so no formatting path can reach one.
section_value() { probe_section_value "$1" "$2" "$3"; }

# The ids an endpoint reports serving, one per line. Records mentioning
# "permission" are skipped: vLLM nests a modelperm-* object carrying its own
# "id" inside every model, and counting those would invent models.
served_ids() { probe_served_ids "$1"; }

# The context length an endpoint reports for one id, or empty. vLLM answers
# with max_model_len; LM Studio and Ollama report nothing at all, which is why
# a missing value is silence rather than a complaint.
served_ctx() { probe_served_ctx "$1" "$2"; }

# GET one endpoint. Sets P_CODE (HTTP status; 000 = nothing answered) and
# P_BODY. Never aborts: an unreachable server is a result, not an error.
http_get() { probe_http_get "$1" "$2"; }

# base_url already ends in /v1 by convention; the listing hangs off it.
models_endpoint() { probe_models_endpoint "$1"; }

# The roles a catalog key is about to be handed, for reporting only.
roles_for() {
    _r=""
    if [ "$1" = "$BIG_KEY" ]; then
        _r="default, architect, executor, reviewer"
    fi
    if [ "$1" = "$SMALL_KEY" ]; then
        if [ -n "$_r" ]; then _r="$_r, "; fi
        _r="${_r}session_summary, prompt_suggestion, web_search, scout"
    fi
    if [ -n "$VISION_KEY" ] && [ "$1" = "$VISION_KEY" ]; then
        if [ -n "$_r" ]; then _r="$_r, "; fi
        _r="${_r}image_description, looker"
    fi
    printf '%s' "$_r"
}

probe_report() {
    if ! command -v curl >/dev/null 2>&1; then
        echo "# (--probe needs curl, which is not on PATH -- skipped)"
        return 0
    fi

    # url <TAB> http-code <TAB> body. One request per endpoint even when
    # several models share it, which is the normal case: a box serving two
    # models, or one serving a model under two catalog names.
    _cache=""
    _rows=""
    _problems=""

    _oldifs=$IFS
    IFS='
'
    for _rec in $ALL; do
        IFS=$_oldifs
        _k=$(field "$_rec" 1)
        _islocal=$(field "$_rec" 4)
        _url=$(field "$_rec" 6)
        _wire=$(field "$_rec" 7)
        _cfgctx=$(field "$_rec" 8)

        if [ "$INCLUDE_REMOTE" != "1" ] && [ "$_islocal" != "1" ]; then
            _rows="$_rows#   SKIP   $_k -- off-box, not contacted
"
            IFS='
'
            continue
        fi
        if [ -z "$_url" ]; then
            _rows="$_rows#   SKIP   $_k -- no base_url to probe
"
            IFS='
'
            continue
        fi

        _hit=$(printf '%s' "$_cache" | awk -F'\t' -v u="$_url" '$1 == u { print; exit }')
        if [ -n "$_hit" ]; then
            _code=$(printf '%s' "$_hit" | cut -f2)
            _body=$(printf '%s' "$_hit" | cut -f3)
        else
            _auth=""
            if [ "$(section_value "$CONFIG" "$_k" "no_auth")" != "true" ]; then
                _key=$(section_value "$CONFIG" "$_k" "api_key")
                if [ -n "$_key" ]; then
                    _auth="Authorization: Bearer $_key"
                fi
            fi
            http_get "$(models_endpoint "$_url")" "$_auth"
            _code=$P_CODE
            # Flattened so one endpoint stays one cache record; the parsers
            # above are whitespace-insensitive, so this costs nothing.
            _body=$(printf '%s' "$P_BODY" | tr '\n\t' '  ')
            _cache="$_cache$_url	$_code	$_body
"
        fi

        _ids=$(served_ids "$_body")
        case "$_code" in
            000)
                _status="DOWN "
                _note="no answer"
                ;;
            401|403)
                _status="AUTH "
                _note="up, but rejected the credentials in your config (HTTP $_code)"
                ;;
            2*)
                if [ -n "$_wire" ] && printf '%s\n' "$_ids" | grep -Fxq "$_wire"; then
                    _status="UP   "
                    _note=""
                else
                    _status="STALE"
                    _served=$(printf '%s' "$_ids" | tr '\n' ',' | sed 's/,$//; s/,/, /g')
                    if [ -n "$_served" ]; then
                        _note="up, but serving $_served -- not \"$_wire\""
                    else
                        _note="up, but serving nothing"
                    fi
                fi
                ;;
            *)
                _status="DOWN "
                _note="HTTP $_code"
                ;;
        esac

        if [ -n "$_note" ]; then
            _rows="$_rows#   $_status  $_k -- $_url ($_note)
"
        else
            _rows="$_rows#   $_status  $_k -- $_url
"
        fi

        _roles=$(roles_for "$_k")
        if [ "$_status" = "UP   " ]; then
            _srvctx=$(served_ctx "$_body" "$_wire")
            if [ -n "$_srvctx" ] && [ "$_cfgctx" = "0" ]; then
                _problems="$_problems#   $_k sets no context_window, but the server reports $_srvctx.
#     Axon assumes 200000 without it, so compaction fires at the wrong point.
"
            elif [ -n "$_srvctx" ] && [ "$_cfgctx" != "$_srvctx" ]; then
                _problems="$_problems#   $_k claims context_window = $_cfgctx; the server reports $_srvctx.
"
            fi
        elif [ -n "$_roles" ]; then
            _problems="$_problems#   $_k is assigned below ($_roles) but is not usable right now.
"
        fi
        IFS='
'
    done
    IFS=$_oldifs

    if [ -z "$_rows" ]; then
        echo "# (--probe: no endpoint to contact)"
        return 0
    fi
    echo "# Probe -- what your configured endpoints are serving right now:"
    printf '%s' "$_rows"
    if [ -n "$_problems" ]; then
        echo "#"
        echo "# Problems:"
        printf '%s' "$_problems"
    fi
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
cat <<EOF
# ---------------------------------------------------------------------------
# oh-my-axon $OMA_VERSION role presets
# Generated from the $MODEL_COUNT usable model(s) in $CONFIG
#
# SUGGESTIONS, not measurements: the split below is inferred from parameter
# counts in your model names. Read it, change what you disagree with, and
# paste into ~/.axon/config.toml. Nothing has been written for you.
#
# Merge by hand if you already have these tables -- appending a second
# [models] section to a TOML file is a parse error, not an override.
# ---------------------------------------------------------------------------
EOF

if [ "$PROBE" = "1" ]; then
    echo "#"
    probe_report
    echo "#"
fi

if [ -n "$SKIPPED" ]; then
    echo
    echo "# Skipped as off-box (pass --include-remote to use them anyway):"
    # The trailing catch-all matters: `read` hands every remaining field to the
    # last variable, so without it the label would swallow url/id/context.
    printf '%s\n' "$SKIPPED" | while IFS="$TAB" read -r k _ _ _ lbl _; do
        echo "#   $k -- $lbl"
    done
fi

if [ "$TIERED" = "1" ]; then
    cat <<EOF

# Big:   $BIG_KEY -- $BIG_LABEL
# Small: $SMALL_KEY -- $SMALL_LABEL
EOF
elif [ "$MODEL_COUNT" = "1" ]; then
    cat <<EOF

# Only one usable model ($BIG_KEY -- $BIG_LABEL), so every role points at it.
# With a second, smaller server running, re-run this to get a real split.
EOF
else
    cat <<EOF

# $MODEL_COUNT local models, but none reads as smaller than the others, so
# every role points at $BIG_KEY -- $BIG_LABEL.
# Sizes are read from model names; if one of yours is genuinely lighter,
# put it in the scout / session_summary / prompt_suggestion slots by hand.
EOF
fi

echo
echo "[models]"
echo "default = \"$BIG_KEY\""
echo "# Short, frequent, latency-sensitive calls. Cheap models are fine here;"
echo "# on a single-model setup these just reuse the one you have."
echo "session_summary = \"$SMALL_KEY\"      # session titles"
echo "prompt_suggestion = \"$SMALL_KEY\"    # tab-completion ghost text"
echo "web_search = \"$SMALL_KEY\"           # synthesizes search results"
if [ -n "$VISION_KEY" ]; then
    echo "image_description = \"$VISION_KEY\"   # transcribes images you paste"
else
    echo "# image_description = \"...\"  # no multimodal model found in your catalog"
fi

cat <<EOF

# Per-agent pins. These beat each agent's own \`model:\` frontmatter, so this
# is where you retarget oh-my-axon's agents without editing their files.
[subagents.models]
EOF
echo "scout = \"$SMALL_KEY\"        # read-only recon: wide, shallow, high volume"
echo "architect = \"$BIG_KEY\"      # planning: the reasoning-heaviest role"
echo "executor = \"$BIG_KEY\"       # writes code; weakest link if under-powered"
echo "reviewer = \"$BIG_KEY\"       # must catch what executor got wrong"
if [ -n "$VISION_KEY" ]; then
    echo "looker = \"$VISION_KEY\"      # $VISION_LABEL"
else
    cat <<'EOF'
# looker = "..."          # needs a multimodal model; none found in your
                          # catalog. Its frontmatter expects a model named
                          # "vision" -- add [model.vision] or pin it here.
EOF
fi

cat <<'EOF'

# Reminder, because it is the single most common local-model misconfiguration:
# set context_window on every [model.*] entry to the context the server was
# actually started with. It defaults to 200000, and auto-compaction fires at
# 85% of whatever you claim -- so an honest number is what keeps long runs
# from overflowing the server.
EOF
