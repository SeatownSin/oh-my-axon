#!/bin/sh
# oh-my-axon role-generator smoke tests (Linux / WSL / macOS).
#
#   sh tests/smoke-gen-roles.sh
#
# Drives tools/gen-roles.sh against fixture configs and checks the assignments,
# the off-box exclusion, determinism, and that it never writes anything. Exits
# non-zero if any assertion fails.
#
# No EXIT trap: dash discards the exit status a trap sets, which silently turns
# a failing run green. Cleanup is explicit at the end instead.
set -eu

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd)
GEN="$REPO_ROOT/tools/gen-roles.sh"

# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"

WORK=$(mktemp -d)

# Run the generator. Sets OUT and CODE; never aborts the suite.
run_gen() {
    set +e
    OUT=$(sh "$GEN" "$@" 2>&1)
    CODE=$?
    set -e
}

echo "gen-roles: fixtures in $WORK"

# --- fixtures -------------------------------------------------------------
cat > "$WORK/mixed.toml" <<'EOF'
[models]
default = "something-else"

[model.big-box]
model = "llama-3.1-70b-instruct"
base_url = "http://192.168.1.50:8000/v1"
name = "Big (LAN)"

[model.little]
model = "qwen2.5-3b-instruct"
base_url = "http://127.0.0.1:1234/v1"

[model.eyes]
model = "llava-1.6-13b"
base_url = "http://localhost:1234/v1"

[model.hosted]
model = "gpt-nope-400b"
base_url = "https://api.example.com/v1"
name = "Hosted"
EOF

cat > "$WORK/single.toml" <<'EOF'
[model.only]
model = "qwen2.5-coder-32b-instruct"
base_url = "http://localhost:1234/v1"
EOF

cat > "$WORK/remote-only.toml" <<'EOF'
[model.hosted]
model = "something-70b"
base_url = "https://api.example.com/v1"
EOF

cat > "$WORK/empty.toml" <<'EOF'
[models]
default = "nothing"
EOF

# --- role assignment ------------------------------------------------------
echo
echo "role assignment"
run_gen --config "$WORK/mixed.toml"
assert_eq "mixed catalog exits 0" "$CODE" "0"
assert_match "biggest local model becomes the default" "$OUT" '^default = "big-box"$'
assert_match "architect gets the big model" "$OUT" '^architect = "big-box"'
assert_match "executor gets the big model" "$OUT" '^executor = "big-box"'
assert_match "reviewer gets the big model" "$OUT" '^reviewer = "big-box"'
assert_match "scout gets the small model" "$OUT" '^scout = "little"'
assert_match "session titles get the small model" "$OUT" '^session_summary = "little"'
assert_match "looker gets the vision model" "$OUT" '^looker = "eyes"'
assert_match "image description gets the vision model" "$OUT" '^image_description = "eyes"'

# The vision model is 13B -- bigger than the 3B -- and must still not be
# picked as "small", or a multimodal model ends up doing text chores.
assert_no_match "vision model is not used for text roles" "$OUT" '^(default|scout|session_summary) = "eyes"'

# --- off-box exclusion ----------------------------------------------------
echo
echo "off-box exclusion"
assert_no_match "hosted model is not assigned to any role" "$OUT" '= "hosted"'
assert_match "hosted model is reported as skipped" "$OUT" '# +hosted -- Hosted'
assert_match "usable count excludes the hosted model" "$OUT" '3 usable model'

run_gen --config "$WORK/mixed.toml" --include-remote
assert_eq "--include-remote exits 0" "$CODE" "0"
assert_match "--include-remote promotes the 400B hosted model" "$OUT" '^default = "hosted"$'

run_gen --config "$WORK/remote-only.toml"
assert_eq "all-remote catalog fails" "$CODE" "1"
assert_match "all-remote explains itself" "$OUT" 'served off-box'

# --- degenerate catalogs --------------------------------------------------
echo
echo "degenerate catalogs"
run_gen --config "$WORK/single.toml"
assert_eq "single-model catalog exits 0" "$CODE" "0"
assert_match "single model fills every role" "$OUT" '^default = "only"$'
assert_match "single model is called out" "$OUT" 'Only one usable model'
assert_match "looker is left commented out with no vision model" "$OUT" '^# looker = '
assert_no_match "no bare image_description without a vision model" "$OUT" '^image_description ='

run_gen --config "$WORK/empty.toml"
assert_eq "catalog with no [model.*] fails" "$CODE" "1"
assert_match "empty catalog explains itself" "$OUT" 'no \[model\.\*\] entries'

run_gen --config "$WORK/does-not-exist.toml"
assert_eq "missing config fails" "$CODE" "1"

# --- determinism ----------------------------------------------------------
echo
echo "determinism"
# Two same-size models must not swap places between runs; sort ties are broken
# on the catalog key precisely so this is stable.
cat > "$WORK/tie.toml" <<'EOF'
[model.zeta]
model = "zeta-120b"
base_url = "http://box.local:8000/v1"
[model.alpha]
model = "alpha-120b"
base_url = "http://box.local:8000/v1"
EOF
run_gen --config "$WORK/tie.toml"
first="$OUT"
run_gen --config "$WORK/tie.toml"
assert_eq "repeated runs agree exactly" "$OUT" "$first"
assert_match "same-size catalog says so rather than claiming one model" "$OUT" 'none reads as smaller'

# --- MoE sizing -----------------------------------------------------------
echo
echo "MoE sizing"
cat > "$WORK/moe.toml" <<'EOF'
[model.mix]
model = "mixtral-8x7b-instruct"
base_url = "http://127.0.0.1:8080/v1"
[model.dense]
model = "qwen2.5-32b"
base_url = "http://127.0.0.1:8080/v1"
EOF
run_gen --config "$WORK/moe.toml"
assert_match "8x7b multiplies out to 56B and outranks 32B" "$OUT" '^default = "mix"$'

# --- probe ----------------------------------------------------------------
# Port 1 rather than a plausible one: nothing listens there, the refusal is
# immediate, and pointing a test at :1234 or :8000 would quietly probe whatever
# the developer running it happens to have loaded.
echo
echo "probe"
cat > "$WORK/probe-down.toml" <<'EOF'
[model.big-box]
model = "big-70b"
base_url = "http://127.0.0.1:1/v1"

[model.little]
model = "small-3b"
base_url = "http://127.0.0.1:1/v1"

[model.hosted]
model = "hosted-400b"
base_url = "https://api.example.invalid/v1"
EOF

if command -v curl >/dev/null 2>&1; then
    run_gen --config "$WORK/probe-down.toml" --probe
    assert_eq "probe against a dead endpoint still exits 0" "$CODE" "0"
    assert_match "unreachable endpoint reports DOWN" "$OUT" '^#   DOWN   big-box -- http://127\.0\.0\.1:1/v1 \(no answer\)'
    assert_match "off-box entry is reported as not contacted" "$OUT" '^#   SKIP   hosted -- off-box, not contacted'
    assert_match "a dead model that holds roles is called out" "$OUT" \
        '^#   big-box is assigned below \(default, architect, executor, reviewer\) but is not usable'

    # The probe must not talk about ports nobody configured: the old version
    # guessed :1234/:11434/:8000/:8080 and reported nothing useful on a LAN.
    assert_no_match "probe does not guess ports" "$OUT" '11434|:8080'

    # Everything the probe emits is a comment, or the snippet stops being
    # pasteable -- this is the invariant that makes the whole report safe.
    assert_no_match "probe output is comment-only" "$OUT" '^[^#[:space:]#].*(UP|DOWN|STALE|SKIP)'

    run_gen --config "$WORK/probe-down.toml"
    plain=$(printf '%s\n' "$OUT" | grep -v '^#')
    run_gen --config "$WORK/probe-down.toml" --probe
    probed=$(printf '%s\n' "$OUT" | grep -v '^#')
    assert_eq "probing never changes the assignments" "$probed" "$plain"
else
    pass "probe checks skipped (no curl)"
fi

# --- probe against a live endpoint ----------------------------------------
# The UP / STALE / AUTH / context paths need something answering. A throwaway
# server keeps them deterministic instead of dependent on whatever the machine
# happens to be serving.
PY=""
for _cand in python3 python; do
    if command -v "$_cand" >/dev/null 2>&1; then PY=$_cand; break; fi
done

start_fake() {
    FAKE_LOG="$WORK/fake.log"
    rm -f "$FAKE_LOG"
    "$PY" "$TESTS_DIR/fake-openai-server.py" "$@" > "$FAKE_LOG" 2>&1 &
    FAKE_PID=$!
    FAKE_PORT=""
    _n=0
    while [ "$_n" -lt 100 ]; do
        FAKE_PORT=$(sed -n 's/^PORT \([0-9]*\)$/\1/p' "$FAKE_LOG" 2>/dev/null | head -n 1)
        if [ -n "$FAKE_PORT" ]; then break; fi
        sleep 0.1
        _n=$((_n + 1))
    done
}

stop_fake() {
    if [ -n "${FAKE_PID:-}" ]; then
        kill "$FAKE_PID" 2>/dev/null || true
        wait "$FAKE_PID" 2>/dev/null || true
        FAKE_PID=""
    fi
}

if [ -n "$PY" ] && command -v curl >/dev/null 2>&1; then
    echo
    echo "probe (live endpoint)"

    start_fake --id served-70b --ctx 262144
    if [ -z "$FAKE_PORT" ]; then
        fail "fake server starts" "no PORT line in $FAKE_LOG"
    else
        pass "fake server starts"

        # Served id matches, context agrees: UP and silent.
        cat > "$WORK/probe-up.toml" <<EOF
[model.served]
model = "served-70b"
base_url = "http://127.0.0.1:$FAKE_PORT/v1"
context_window = 262144
EOF
        run_gen --config "$WORK/probe-up.toml" --probe
        assert_match "a served model reports UP" "$OUT" '^#   UP     served -- '
        assert_no_match "an agreeing context_window says nothing" "$OUT" '# Problems:'

        # Same server, wrong id in the config: the endpoint is up but is not
        # serving what the catalog claims. This is the container-swap case.
        cat > "$WORK/probe-stale.toml" <<EOF
[model.served]
model = "some-other-model"
base_url = "http://127.0.0.1:$FAKE_PORT/v1"
EOF
        run_gen --config "$WORK/probe-stale.toml" --probe
        assert_match "an unserved id reports STALE and names what is served" "$OUT" \
            '^#   STALE  served -- .*\(up, but serving served-70b -- not "some-other-model"\)'
        assert_no_match "the nested permission id is not mistaken for a model" "$OUT" 'modelperm'

        # Context drift is the misconfiguration the footer warns about, so the
        # probe is the one thing able to actually catch it.
        cat > "$WORK/probe-ctx.toml" <<EOF
[model.served]
model = "served-70b"
base_url = "http://127.0.0.1:$FAKE_PORT/v1"
context_window = 8192
EOF
        run_gen --config "$WORK/probe-ctx.toml" --probe
        assert_match "a context_window that disagrees with the server is reported" "$OUT" \
            '^#   served claims context_window = 8192; the server reports 262144\.'

        cat > "$WORK/probe-noctx.toml" <<EOF
[model.served]
model = "served-70b"
base_url = "http://127.0.0.1:$FAKE_PORT/v1"
EOF
        run_gen --config "$WORK/probe-noctx.toml" --probe
        assert_match "a missing context_window is reported against the server" "$OUT" \
            '^#   served sets no context_window, but the server reports 262144\.'
    fi
    stop_fake

    # A server that demands a token it is not given is up, not down -- saying
    # DOWN would send you looking at the wrong thing entirely.
    start_fake --id served-70b --require-auth sekrit
    if [ -n "$FAKE_PORT" ]; then
        cat > "$WORK/probe-auth.toml" <<EOF
[model.served]
model = "served-70b"
base_url = "http://127.0.0.1:$FAKE_PORT/v1"
EOF
        run_gen --config "$WORK/probe-auth.toml" --probe
        assert_match "a rejected credential reports AUTH, not DOWN" "$OUT" \
            '^#   AUTH   served -- .*rejected the credentials'

        # With the key configured the same server comes back UP, which is what
        # proves the probe sends it at all.
        cat > "$WORK/probe-authok.toml" <<EOF
[model.served]
model = "served-70b"
base_url = "http://127.0.0.1:$FAKE_PORT/v1"
api_key = "sekrit"
EOF
        run_gen --config "$WORK/probe-authok.toml" --probe
        assert_match "the configured api_key is actually sent" "$OUT" '^#   UP     served -- '
        assert_no_match "the api_key never appears in the output" "$OUT" 'sekrit'
    else
        fail "fake auth server starts" "no PORT line"
    fi
    stop_fake
else
    pass "live-endpoint probe checks skipped (no python3 or curl)"
fi

# --- output shape ---------------------------------------------------------
echo
echo "output shape"
parses_as_toml() {
    # $1 = assertion name, $2 = snippet, $3 = 1 when the subagent table is
    # expected (a probe fixture with one model still emits it, so always 1)
    printf '%s\n' "$2" > "$WORK/out.toml"
    if "$PY" - "$WORK/out.toml" <<'PY'
import sys
try:
    import tomllib
except ModuleNotFoundError:
    sys.exit(0)   # Python < 3.11: nothing to check with
with open(sys.argv[1], "rb") as fh:
    d = tomllib.load(fh)
assert set(d) <= {"models", "subagents"}, d
assert "models" in d, d
PY
    then
        pass "$1"
    else
        fail "$1"
    fi
}

run_gen --config "$WORK/mixed.toml"
if [ -n "$PY" ]; then
    printf '%s\n' "$OUT" > "$WORK/out.toml"
    if "$PY" - "$WORK/out.toml" <<'PY'
import sys
try:
    import tomllib
except ModuleNotFoundError:
    sys.exit(0)   # Python < 3.11: nothing to check with
with open(sys.argv[1], "rb") as fh:
    d = tomllib.load(fh)
assert set(d) == {"models", "subagents"}, d
assert set(d["subagents"]["models"]) == {
    "scout", "architect", "executor", "reviewer", "looker"
}, d["subagents"]["models"]
PY
    then
        pass "generated snippet parses as TOML with the expected tables"
    else
        fail "generated snippet parses as TOML with the expected tables"
    fi

    # The probe report sits above the tables, so if any of it were to escape
    # its comment prefix the whole snippet would stop parsing. Checked by
    # parsing rather than by regex, because a regex is what would miss it.
    if command -v curl >/dev/null 2>&1; then
        run_gen --config "$WORK/probe-down.toml" --probe
        parses_as_toml "a probed snippet still parses as TOML" "$OUT"
    fi
else
    pass "TOML parse check skipped (no python3)"
fi

# --- writes nothing -------------------------------------------------------
echo
echo "side effects"
SANDBOX="$WORK/sandbox"
mkdir -p "$SANDBOX"
before=$(find "$SANDBOX" | sort)
# Checksum the input before the run, not after -- comparing a file to itself
# afterwards would assert nothing at all.
config_before=$(cksum < "$WORK/mixed.toml")

AXON_HOME="$SANDBOX"
export AXON_HOME
run_gen --config "$WORK/mixed.toml"
unset AXON_HOME

after=$(find "$SANDBOX" | sort)
assert_eq "generator writes nothing under AXON_HOME" "$after" "$before"
assert_eq "generator does not modify the config it reads" \
    "$(cksum < "$WORK/mixed.toml")" "$config_before"

rm -rf "$WORK"
summary "gen-roles: all checks passed"
