#!/bin/sh
# oh-my-axon hook smoke tests (Linux / WSL / macOS).
#
#   ./tests/smoke-hooks.sh
#
# Exercises the hook scripts the way Axon actually invokes them: payload on
# stdin, decision on stdout, exit code as the verdict. Exits non-zero if any
# assertion fails.
set -eu

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd)
HOOK_BIN="$REPO_ROOT/home/hooks/bin"

# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"

# Run a hook with a payload on stdin. Sets OUT and CODE.
run_hook() {
    set +e
    OUT=$(printf '%s' "$2" | sh "$1" 2>&1)
    CODE=$?
    set -e
}

# Repeat $1 $2 times. Used to build credential fixtures at runtime so that no
# literal credential pattern is ever stored in this file, which would trip
# push protection and the repo's own secret scanners.
rep() {
    _i=0
    _s=''
    while [ "$_i" -lt "$2" ]; do
        _s="$_s$1"
        _i=$((_i + 1))
    done
    printf '%s' "$_s"
}

payload_cmd() { printf '{"tool_input":{"command":"%s"}}' "$1"; }
payload_file() { printf '{"tool_input":{"file_path":"%s"}}' "$1"; }

echo "oh-my-axon hook smoke tests"

# --------------------------------------------------------------- secret-scan
echo
echo "secret-scan (PreToolUse deny gate)"
SECRET_SCAN="$HOOK_BIN/secret-scan.sh"

run_hook "$SECRET_SCAN" "$(payload_cmd 'echo hello world')"
assert_eq 'benign payload is allowed (exit 0)' "$CODE" 0
assert_match 'benign payload reports allow' "$OUT" 'allow'

# AWS's own documentation example key -- allowlisted by GitHub push protection
# and by AWS, so it is safe to commit, while still matching the AKIA pattern.
run_hook "$SECRET_SCAN" "$(payload_cmd 'export KEY=AKIAIOSFODNN7EXAMPLE')"
assert_eq 'AWS access key ID is denied (exit 2)' "$CODE" 2
assert_match 'deny decision is emitted' "$OUT" '"decision"[[:space:]]*:[[:space:]]*"deny"'

check_denied() {
    # $1 = label, $2 = fixture value
    run_hook "$SECRET_SCAN" "$(payload_cmd "x=$2")"
    assert_eq "$1 is denied" "$CODE" 2
}

check_denied 'GitHub token'      "ghp_$(rep a 36)"
check_denied 'Slack token'       "xoxb-$(rep 1 10)-abc"
check_denied 'Anthropic API key' "sk-ant-$(rep A 20)"
check_denied 'Google API key'    "AIza$(rep B 35)"
check_denied 'Stripe live key'   "sk_live_$(rep c 24)"
check_denied 'private key block' '-----BEGIN RSA PRIVATE KEY-----'

# ------------------------------------------------------------ format-on-edit
echo
echo "format-on-edit (PostToolUse, must never block)"
FMT="$HOOK_BIN/format-on-edit.sh"

PLAIN=$(mktemp -d)
echo hello > "$PLAIN/a.txt"

check_quiet() {
    # $1 = label, $2 = payload. A formatting hook must never block an edit or
    # speak up, so exit 0 and total silence are both assertions.
    run_hook "$FMT" "$2"
    assert_eq "$1: exits 0" "$CODE" 0
    assert_eq "$1: stays silent" "$OUT" ''
}

check_quiet 'invalid JSON'       'not json at all'
check_quiet 'empty stdin'        ''
check_quiet 'no path key'        '{"tool_input":{"foo":"bar"}}'
check_quiet 'nonexistent file'   "$(payload_file "$PLAIN/nope.rs")"
check_quiet 'no formatter found' "$(payload_file "$PLAIN/a.txt")"

# Positive path: a Cargo project actually gets formatted.
if command -v rustfmt >/dev/null 2>&1; then
    RUST=$(mktemp -d)
    mkdir -p "$RUST/src"
    printf '[package]\nname = "smoke"\n' > "$RUST/Cargo.toml"
    printf 'fn main(){let x=1;println!("{}",x);}\n' > "$RUST/src/main.rs"
    run_hook "$FMT" "$(payload_file "$RUST/src/main.rs")"
    assert_eq 'rust project: exits 0' "$CODE" 0
    assert_match 'rust project: file was reformatted' "$(cat "$RUST/src/main.rs")" 'let x = 1;'
    rm -rf "$RUST"
else
    echo '  skip rustfmt positive case (rustfmt not on PATH)'
fi

rm -rf "$PLAIN"

# ------------------------------------------------------------------ summary
summary 'hook smoke tests passed'
