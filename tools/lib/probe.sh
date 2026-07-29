# shellcheck shell=sh
# Shared catalog + endpoint probing for oh-my-axon's tools.
# Sourced, never executed directly.
#
# gen-roles and doctor both need to read the [model.*] catalog, resolve one
# endpoint's credentials, ask it what it is serving, and read the context length
# it reports. That logic lives here once. A third and fourth copy of it -- one
# per tool per language -- is exactly the drift this repo already guards against
# by pinning the version string across four files.
#
# Credentials are read ONLY by probe_auth_header, at the point of the request.
# They are deliberately absent from the catalog records, so no formatting or
# reporting path can reach a secret and print it.

# One value out of one [model.<key>] section, or empty.
probe_section_value() {
    # $1 = config path, $2 = model key, $3 = field name
    awk -v want="$2" -v field="$3" '
        # A value may legitimately contain a hash. Strip a trailing comment only
        # when it sits OUTSIDE a quoted string, or an api_key of "abc#def"
        # silently becomes "abc" and the request fails as a puzzling 401.
        function unquote(s,   rest, q) {
            sub(/^[^=]*=[[:space:]]*/, "", s)
            if (substr(s, 1, 1) == "\"") {
                rest = substr(s, 2); q = index(rest, "\"")
                return (q > 0) ? substr(rest, 1, q - 1) : rest
            }
            if (substr(s, 1, 1) == "'"'"'") {
                rest = substr(s, 2); q = index(rest, "'"'"'")
                return (q > 0) ? substr(rest, 1, q - 1) : rest
            }
            sub(/[[:space:]]*#.*$/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        /^[[:space:]]*\[model\./ {
            k = $0
            sub(/^[[:space:]]*\[model\./, "", k)
            sub(/\].*$/, "", k)
            gsub(/["'"'"']/, "", k)
            cur = (k == want)
            next
        }
        /^[[:space:]]*\[/ { cur = 0; next }
        cur && $0 ~ ("^[[:space:]]*" field "[[:space:]]*=") { print unquote($0); exit }
    ' "$1"
}

# The model an agent file pins in its own frontmatter, or empty.
#
# Only the frontmatter is read, never the body: the range stops at the closing
# delimiter, so a `model:` mentioned in the prompt text below it is prose.
probe_agent_model() {
    # $1 = path to an agent .md file
    [ -f "$1" ] || return 0
    sed -n '/^---[[:space:]]*$/,/^---[[:space:]]*$/ s/^model:[[:space:]]*//p' "$1" |
        head -1 |
        sed 's/[[:space:]]*#.*$//; s/^["'"'"']//; s/["'"'"']$//; s/[[:space:]]*$//'
}

# The catalog key one role runs on, or empty when nothing resolves.
#
# Precedence, matching Axon's own: a [subagents.models] pin beats the agent
# file's own `model:` frontmatter, which beats [models] default. The middle step
# is not optional -- oh-my-axon's own `looker` pins `model: vision` in its
# frontmatter, so without it an unpinned looker run gets recorded as having run
# on the default model, which is a measurement of the wrong machine.
#
# gen-roles emits its pins with trailing comments, so stripping a comment
# outside quotes is not optional either: `scout = "small"  # recon` must not
# resolve to `small"  # recon`.
probe_role_model() {
    # $1 = config path, $2 = role name, $3 = agents dir (optional)
    _prm_row=$(probe_role_model_row "$1" "$2")
    _prm_pin=$(printf '%s' "$_prm_row" | cut -f 1)
    _prm_slot=$(printf '%s' "$_prm_row" | cut -f 2)
    _prm_dflt=$(printf '%s' "$_prm_row" | cut -f 3)

    if [ -n "$_prm_pin" ]; then printf '%s' "$_prm_pin"; return 0; fi
    if [ -n "$_prm_slot" ]; then printf '%s' "$_prm_slot"; return 0; fi
    if [ -n "${3:-}" ]; then
        _prm_fm=$(probe_agent_model "$3/$2.md")
        if [ -n "$_prm_fm" ]; then printf '%s' "$_prm_fm"; return 0; fi
    fi
    printf '%s' "$_prm_dflt"
}

# pin <TAB> slot <TAB> default, for one role. Kept apart from the precedence
# above so the frontmatter step can sit between the config lookups.
probe_role_model_row() {
    # $1 = config path, $2 = role name
    awk -v want="$2" '
        function unquote(s,   rest, q) {
            sub(/^[^=]*=[[:space:]]*/, "", s)
            if (substr(s, 1, 1) == "\"") {
                rest = substr(s, 2); q = index(rest, "\"")
                return (q > 0) ? substr(rest, 1, q - 1) : rest
            }
            if (substr(s, 1, 1) == "'"'"'") {
                rest = substr(s, 2); q = index(rest, "'"'"'")
                return (q > 0) ? substr(rest, 1, q - 1) : rest
            }
            sub(/[[:space:]]*#.*$/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        /^[[:space:]]*\[models\][[:space:]]*$/            { sec = "models";    next }
        /^[[:space:]]*\[subagents\.models\][[:space:]]*$/ { sec = "subagents"; next }
        /^[[:space:]]*\[/                                 { sec = "";          next }
        sec == "" { next }
        {
            k = $0
            if (k !~ /=/) next
            sub(/[[:space:]]*=.*$/, "", k)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            if (sec == "subagents" && k == want) { pinned = unquote($0) }
            else if (sec == "models" && k == want) { slot = unquote($0) }
            else if (sec == "models" && k == "default") { dflt = unquote($0) }
        }
        END { printf "%s\t%s\t%s\n", pinned, slot, dflt }
    ' "$1"
}

# Parse the catalog. Emits one TAB-separated record per [model.<key>] section:
#   key <TAB> size-rank <TAB> is-vision <TAB> is-local <TAB> label
#       <TAB> base-url <TAB> wire-id <TAB> context-window
#
# size-rank is a parameter count in billions scraped from the section key, the
# wire `model` id, or the display `name` -- whichever carries one. "8x7b" style
# MoE names multiply out. 0 means "no size found anywhere", which sorts last so
# an unlabelled model never wins the "biggest" slot by accident.
#
# is-local is decided from base_url: loopback, RFC1918, mDNS/LAN suffixes and
# bare hostnames count as local; anything else is off-box. A missing base_url
# means a vendor-hosted catalog entry, which is off-box by definition.
probe_parse_catalog() {
    awk '
        # A value may legitimately contain a hash. Strip a trailing comment only
        # when it sits OUTSIDE a quoted string, or an api_key of "abc#def"
        # silently becomes "abc" and the request fails as a puzzling 401.
        function unquote(s,   rest, q) {
            sub(/^[^=]*=[[:space:]]*/, "", s)
            if (substr(s, 1, 1) == "\"") {
                rest = substr(s, 2); q = index(rest, "\"")
                return (q > 0) ? substr(rest, 1, q - 1) : rest
            }
            if (substr(s, 1, 1) == "'"'"'") {
                rest = substr(s, 2); q = index(rest, "'"'"'")
                return (q > 0) ? substr(rest, 1, q - 1) : rest
            }
            sub(/[[:space:]]*#.*$/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function params(s,   t, a, b) {
            t = tolower(s)
            if (match(t, /[0-9]+x[0-9]+(\.[0-9]+)?b([^a-z0-9]|$)/)) {
                a = substr(t, RSTART, RLENGTH)
                sub(/b.*$/, "", a)
                split(a, parts, "x")
                return parts[1] * parts[2]
            }
            if (match(t, /[0-9]+(\.[0-9]+)?b([^a-z0-9]|$)/)) {
                b = substr(t, RSTART, RLENGTH)
                sub(/b.*$/, "", b)
                return b + 0
            }
            return 0
        }
        function is_vision(s,   t) {
            t = tolower(s)
            return (t ~ /vision|llava|moondream|pixtral|internvl|cogvlm|idefics|smolvlm|minicpm-v/ ||
                    t ~ /(^|[^a-z])vl([^a-z]|$)/)
        }
        function is_local(url,   h) {
            if (url == "") return 0
            h = tolower(url)
            sub(/^[a-z]+:\/\//, "", h)
            sub(/[\/:].*$/, "", h)
            gsub(/[\[\]]/, "", h)
            if (h == "localhost" || h == "::1" || h ~ /^127\./) return 1
            if (h ~ /^10\./ || h ~ /^192\.168\./) return 1
            if (h ~ /^172\.(1[6-9]|2[0-9]|3[01])\./) return 1
            if (h ~ /\.(local|lan|home|internal|localdomain)$/) return 1
            if (h !~ /\./) return 1   # bare hostname: a LAN box
            return 0
        }
        /^[[:space:]]*\[model\./ {
            key = $0
            sub(/^[[:space:]]*\[model\./, "", key)
            sub(/\].*$/, "", key)
            gsub(/["'"'"']/, "", key)
            cur = key
            n++
            order[n] = cur
            model[cur] = ""
            label[cur] = ""
            url[cur] = ""
            ctx[cur] = ""
            next
        }
        # Any other table header closes the current [model.*] section.
        /^[[:space:]]*\[/ { cur = ""; next }
        cur != "" && /^[[:space:]]*model[[:space:]]*=/    { model[cur] = unquote($0); next }
        cur != "" && /^[[:space:]]*name[[:space:]]*=/     { label[cur] = unquote($0); next }
        cur != "" && /^[[:space:]]*base_url[[:space:]]*=/ { url[cur]   = unquote($0); next }
        cur != "" && /^[[:space:]]*context_window[[:space:]]*=/ { ctx[cur] = unquote($0); next }
        END {
            for (i = 1; i <= n; i++) {
                k = order[i]
                blob = k " " model[k] " " label[k]
                p = params(blob)
                v = is_vision(blob) ? 1 : 0
                l = is_local(url[k]) ? 1 : 0
                c = (ctx[k] ~ /^[0-9]+$/) ? ctx[k] : 0
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
                    k, p, v, l, (label[k] != "" ? label[k] : model[k]), url[k], model[k], c
            }
        }
    ' "$1"
}

# The Authorization header for one catalog key, or empty when the entry sets
# no_auth or carries no api_key. This is the only function that touches a secret.
probe_auth_header() {
    # $1 = config path, $2 = model key
    if [ "$(probe_section_value "$1" "$2" "no_auth")" = "true" ]; then
        return 0
    fi
    _pk=$(probe_section_value "$1" "$2" "api_key")
    if [ -n "$_pk" ]; then
        printf 'Authorization: Bearer %s' "$_pk"
    fi
}

# base_url already ends in /v1 by convention; a listing hangs off it.
probe_models_endpoint() {
    printf '%s/models' "${1%/}"
}

# GET one URL. Sets P_CODE (HTTP status; 000 = nothing answered) and P_BODY.
# Never aborts: an unreachable server is a result, not an error.
probe_http_get() {
    # $1 = url, $2 = auth header (may be empty), $3 = timeout seconds (default 5)
    _pt=${3:-5}
    _praw=""
    if [ -n "$2" ]; then
        _praw=$(curl -sS -m "$_pt" -H "$2" -w '\n%{http_code}' "$1" 2>/dev/null) || true
    else
        _praw=$(curl -sS -m "$_pt" -w '\n%{http_code}' "$1" 2>/dev/null) || true
    fi
    if [ -z "$_praw" ]; then
        P_CODE="000"
        P_BODY=""
        return 0
    fi
    # P_CODE/P_BODY are this function's return values, read by the caller.
    # shellcheck disable=SC2034
    P_CODE=$(printf '%s' "$_praw" | tail -n 1)
    # shellcheck disable=SC2034
    P_BODY=$(printf '%s' "$_praw" | sed '$d')
}

# POST a JSON body to one URL. Same contract as probe_http_get.
probe_http_post() {
    # $1 = url, $2 = auth header (may be empty), $3 = json body, $4 = timeout
    _pt=${4:-20}
    _praw=""
    if [ -n "$2" ]; then
        _praw=$(curl -sS -m "$_pt" -H "$2" -H 'Content-Type: application/json' \
            -d "$3" -w '\n%{http_code}' "$1" 2>/dev/null) || true
    else
        _praw=$(curl -sS -m "$_pt" -H 'Content-Type: application/json' \
            -d "$3" -w '\n%{http_code}' "$1" 2>/dev/null) || true
    fi
    if [ -z "$_praw" ]; then
        P_CODE="000"
        P_BODY=""
        return 0
    fi
    # P_CODE/P_BODY are this function's return values, read by the caller.
    # shellcheck disable=SC2034
    P_CODE=$(printf '%s' "$_praw" | tail -n 1)
    # shellcheck disable=SC2034
    P_BODY=$(printf '%s' "$_praw" | sed '$d')
}

# The ids an endpoint reports serving, one per line. Records mentioning
# "permission" are skipped: vLLM nests a modelperm-* object carrying its own
# "id" inside every model, and counting those would invent models.
probe_served_ids() {
    printf '%s' "$1" | awk 'BEGIN { RS = "," }
        /"permission"/ { next }
        {
            if (match($0, /"id"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
                s = substr($0, RSTART, RLENGTH)
                sub(/^"id"[[:space:]]*:[[:space:]]*"/, "", s)
                sub(/"$/, "", s)
                if (s !~ /^modelperm-/) print s
            }
        }'
}

# The context length an endpoint reports for one id, or empty. vLLM answers
# with max_model_len; LM Studio and Ollama report nothing at all, which is why
# a missing value is silence rather than a complaint.
probe_served_ctx() {
    # $1 = response body, $2 = wire id
    printf '%s' "$1" | awk -v want="$2" 'BEGIN { RS = "," }
        /"permission"/ { next }
        {
            if (match($0, /"id"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
                s = substr($0, RSTART, RLENGTH)
                sub(/^"id"[[:space:]]*:[[:space:]]*"/, "", s)
                sub(/"$/, "", s)
                if (s !~ /^modelperm-/) cur = s
            }
            if (cur == want &&
                match($0, /"(max_model_len|loaded_context_length)"[[:space:]]*:[[:space:]]*[0-9]+/)) {
                t = substr($0, RSTART, RLENGTH)
                sub(/^.*:[[:space:]]*/, "", t)
                print t
                exit
            }
        }'
}

# The model's chat_template_kwargs as JSON, or empty. A probe request that
# omits these tests the server WITHOUT the caller's configuration, which is a
# different question and produces false alarms: a model correctly configured
# with enable_thinking looks like it is leaking when asked bare.
# TOML inline table `{ enable_thinking = true }` -> `{ "enable_thinking": true }`.
probe_chat_template_kwargs() {
    # $1 = config path, $2 = model key
    _pv=$(probe_section_value "$1" "$2" "chat_template_kwargs")
    [ -n "$_pv" ] || return 0
    printf '%s' "$_pv" | sed 's/\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=/"\1":/g'
}
