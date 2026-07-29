#!/bin/sh
# oh-my-axon doctor smoke tests (Linux / WSL / macOS).
#
#   sh tests/smoke-doctor.sh
#
# Drives tools/doctor.sh against fixture configs and a throwaway server, and
# checks the statuses, the exit codes, the role-dependency reporting, and that
# it never writes anything. Exits non-zero if any assertion fails.
#
# No EXIT trap: dash discards the exit status a trap sets, which silently turns
# a failing run green. Cleanup is explicit at the end instead.
set -eu

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd)
DOCTOR="$REPO_ROOT/tools/doctor.sh"

# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"

WORK=$(mktemp -d)

run_doc() {
    set +e
    OUT=$(sh "$DOCTOR" "$@" 2>&1)
    CODE=$?
    set -e
}

echo "doctor: fixtures in $WORK"

# --- usage and argument handling -------------------------------------------
echo
echo "argument handling"
run_doc --help
assert_eq '--help exits 0' "$CODE" "0"
assert_match '--help lists --generate' "$OUT" '\-\-generate'

run_doc --version
assert_eq '--version exits 0' "$CODE" "0"
assert_match '--version prints a semver' "$OUT" 'oh-my-axon [0-9]+\.[0-9]+\.[0-9]+'

run_doc --bogus
assert_eq 'unknown flag is refused (exit 2)' "$CODE" "2"
assert_match 'unknown flag names itself' "$OUT" 'unknown argument: --bogus'

run_doc --config "$WORK/does-not-exist.toml"
assert_eq 'missing config exits 2' "$CODE" "2"

cat > "$WORK/empty.toml" <<'EOF'
[models]
default = "nothing"
EOF
run_doc --config "$WORK/empty.toml"
assert_eq 'config with no [model.*] exits 2' "$CODE" "2"
assert_match 'empty catalog explains itself' "$OUT" 'no \[model\.\*\] entries'

# --- unreachable and off-box ------------------------------------------------
# Port 1 rather than a plausible one: nothing listens there, the refusal is
# immediate, and pointing a test at :1234 would probe whatever the developer
# running it happens to have loaded.
echo
echo "unreachable and off-box"
cat > "$WORK/down.toml" <<'EOF'
[model.dead]
model = "dead-70b"
base_url = "http://127.0.0.1:1/v1"

[model.hosted]
model = "hosted-70b"
base_url = "https://api.example.invalid/v1"

[models]
default = "dead"
EOF
run_doc --config "$WORK/down.toml"
assert_eq 'a broken fleet exits 1' "$CODE" "1"
assert_match 'unreachable model reports DOWN' "$OUT" '^  DOWN   dead -- http://127\.0\.0\.1:1/v1'
assert_match 'unreachable model is explained' "$OUT" 'dead is unreachable'
assert_match 'off-box entry is not contacted' "$OUT" '^  SKIP   hosted -- off-box, not contacted'
# The point of the tool: say what a broken model actually breaks.
assert_match 'a broken model names the roles it breaks' "$OUT" 'this breaks: default'
assert_no_match 'off-box endpoint produced no problem' "$OUT" 'hosted is unreachable'

# --- no base_url ------------------------------------------------------------
cat > "$WORK/nourl.toml" <<'EOF'
[model.vendor]
model = "some-hosted-model"
EOF
run_doc --config "$WORK/nourl.toml"
assert_match 'an entry with no base_url is skipped' "$OUT" 'SKIP   vendor -- no base_url'

# --- values containing a hash ----------------------------------------------
# TOML comment stripping must respect quotes. It did not: `api_key = "abc#def"`
# was truncated to `abc`, which reaches the server as a wrong key and comes
# back as a puzzling 401 that blames the credential rather than the parser.
echo
echo "values containing a hash"
cat > "$WORK/hash.toml" <<'EOF'
[model.served]
model = "served-70b"
base_url = "http://127.0.0.1:1/v1"
api_key = "abc#def123"
name = "GPU #2 box"
context_window = 4096  # trailing comment on a bare value
EOF
KEYVAL=$(sh -c '. "'"$REPO_ROOT"'/tools/lib/probe.sh"; probe_section_value "'"$WORK"'/hash.toml" served api_key')
assert_eq 'a hash inside a quoted api_key survives' "$KEYVAL" 'abc#def123'
NAMEVAL=$(sh -c '. "'"$REPO_ROOT"'/tools/lib/probe.sh"; probe_section_value "'"$WORK"'/hash.toml" served name')
assert_eq 'a hash inside a quoted name survives' "$NAMEVAL" 'GPU #2 box'
CTXVAL=$(sh -c '. "'"$REPO_ROOT"'/tools/lib/probe.sh"; probe_section_value "'"$WORK"'/hash.toml" served context_window')
assert_eq 'a trailing comment on a bare value is still stripped' "$CTXVAL" '4096'

# --- roles read from [subagents.models] -------------------------------------
echo
echo "role attribution"
cat > "$WORK/subagents.toml" <<'EOF'
[model.dead]
model = "dead-70b"
base_url = "http://127.0.0.1:1/v1"

[models]
default = "other"

[subagents.models]
executor = "dead"
reviewer = "dead"
EOF
run_doc --config "$WORK/subagents.toml"
assert_match 'roles are read from [subagents.models] too' "$OUT" 'this breaks: executor, reviewer'

# --- against a live endpoint ------------------------------------------------
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
    echo "live endpoint"
    start_fake --id served-70b --ctx 262144
    if [ -z "$FAKE_PORT" ]; then
        fail "fake server starts" "no PORT line in $FAKE_LOG"
    else
        pass "fake server starts"

        cat > "$WORK/ok.toml" <<EOF
[model.served]
model = "served-70b"
base_url = "http://127.0.0.1:$FAKE_PORT/v1"
context_window = 262144
EOF
        run_doc --config "$WORK/ok.toml"
        assert_eq 'a healthy fleet exits 0' "$CODE" "0"
        assert_match 'a served model reports UP' "$OUT" '^  UP     served -- '
        assert_match 'a healthy fleet says so' "$OUT" 'No problems found'

        # The endpoint is up but serving something else -- the container-swap case.
        cat > "$WORK/stale.toml" <<EOF
[model.served]
model = "some-other-model"
base_url = "http://127.0.0.1:$FAKE_PORT/v1"
EOF
        run_doc --config "$WORK/stale.toml"
        assert_eq 'a stale endpoint exits 1' "$CODE" "1"
        assert_match 'an unserved id reports STALE' "$OUT" '^  STALE  served -- '
        assert_match 'STALE names what is actually served' "$OUT" 'serving served-70b, not "some-other-model"'

        # Context drift: the misconfiguration that makes compaction fire early.
        cat > "$WORK/ctx.toml" <<EOF
[model.served]
model = "served-70b"
base_url = "http://127.0.0.1:$FAKE_PORT/v1"
context_window = 8192
EOF
        run_doc --config "$WORK/ctx.toml"
        assert_eq 'context drift exits 1' "$CODE" "1"
        assert_match 'context drift is reported' "$OUT" 'claims context_window = 8192; the server reports 262144'

        cat > "$WORK/noctx.toml" <<EOF
[model.served]
model = "served-70b"
base_url = "http://127.0.0.1:$FAKE_PORT/v1"
EOF
        run_doc --config "$WORK/noctx.toml"
        assert_match 'a missing context_window is reported' "$OUT" 'sets no context_window; the server reports 262144'

        run_doc --config "$WORK/ok.toml" --quiet
        assert_eq '--quiet on a healthy fleet exits 0' "$CODE" "0"
        assert_eq '--quiet prints nothing when all is well' "$OUT" ""
    fi
    stop_fake

    # A server demanding a token it is not given is up, not down.
    start_fake --id served-70b --require-auth sekrit
    if [ -n "$FAKE_PORT" ]; then
        cat > "$WORK/auth.toml" <<EOF
[model.served]
model = "served-70b"
base_url = "http://127.0.0.1:$FAKE_PORT/v1"
EOF
        run_doc --config "$WORK/auth.toml"
        assert_match 'a rejected credential reports AUTH, not DOWN' "$OUT" '^  AUTH   served -- '
        assert_match 'AUTH suggests the fix' "$OUT" 'Check api_key, or set no_auth'

        cat > "$WORK/authok.toml" <<EOF
[model.served]
model = "served-70b"
base_url = "http://127.0.0.1:$FAKE_PORT/v1"
api_key = "sekrit"
context_window = 0
EOF
        run_doc --config "$WORK/authok.toml"
        assert_match 'the configured api_key is actually sent' "$OUT" '^  UP     served -- '
        assert_no_match 'the api_key never appears in the output' "$OUT" 'sekrit'
    else
        fail "fake auth server starts" "no PORT line"
    fi
    stop_fake
else
    pass "live-endpoint checks skipped (no python3 or curl)"
fi

# --- writes nothing ---------------------------------------------------------
echo
echo "side effects"
SANDBOX="$WORK/sandbox"
mkdir -p "$SANDBOX"
before=$(find "$SANDBOX" | sort)
config_before=$(cksum < "$WORK/down.toml")

AXON_HOME="$SANDBOX"
export AXON_HOME
run_doc --config "$WORK/down.toml"
unset AXON_HOME

after=$(find "$SANDBOX" | sort)
assert_eq 'doctor writes nothing under AXON_HOME' "$after" "$before"
assert_eq 'doctor does not modify the config it reads' \
    "$(cksum < "$WORK/down.toml")" "$config_before"

rm -rf "$WORK"
summary "doctor: all checks passed"
