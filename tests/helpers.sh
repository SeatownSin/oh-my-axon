# shellcheck shell=sh
# Shared helpers for the oh-my-axon smoke tests.
# Sourced, never executed directly.

checks=0
failures=0

pass() {
    checks=$((checks + 1))
    echo "  ok   $1"
}

fail() {
    checks=$((checks + 1))
    failures=$((failures + 1))
    echo "  FAIL $1"
    if [ -n "${2:-}" ]; then
        echo "       $2"
    fi
    return 0
}

assert_eq() {
    # $1 = name, $2 = actual, $3 = expected
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1" "expected [$3], got [$2]"
    fi
}

assert_match() {
    # $1 = name, $2 = haystack, $3 = extended regex
    if printf '%s' "$2" | grep -Eq "$3"; then
        pass "$1"
    else
        fail "$1" "[$2] does not match /$3/"
    fi
}

assert_no_match() {
    # $1 = name, $2 = haystack, $3 = extended regex
    if printf '%s' "$2" | grep -Eq "$3"; then
        fail "$1" "[$2] unexpectedly matches /$3/"
    else
        pass "$1"
    fi
}

assert_file() {
    # $1 = name, $2 = path that must exist as a regular file
    if [ -f "$2" ]; then
        pass "$1"
    else
        fail "$1" "missing file: $2"
    fi
}

assert_absent() {
    # $1 = name, $2 = path that must not exist at all
    if [ -e "$2" ]; then
        fail "$1" "should not exist: $2"
    else
        pass "$1"
    fi
}

# Print the tally. Returns 1 if anything failed, so callers can `exit`.
summary() {
    echo
    echo "$checks checks, $failures failed"
    if [ "$failures" -gt 0 ]; then
        return 1
    fi
    echo "$1"
    return 0
}
