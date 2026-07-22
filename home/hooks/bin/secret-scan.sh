#!/bin/sh
# oh-my-axon secret-scan gate (PreToolUse).
# Reads the tool payload from stdin and denies the call if it contains
# something that looks like a real credential. Runs entirely locally.

payload=$(cat)

deny() {
    printf '{"decision":"deny","reason":"oh-my-axon secret-scan: %s detected in tool input. Keep credentials out of the repo (env var, or config outside the workspace) and retry without the secret."}\n' "$1"
    exit 2
}

match() {
    printf '%s' "$payload" | grep -Eq -e "$1"
}

match 'AKIA[0-9A-Z]{16}'                               && deny "AWS access key ID"
match '\-\-\-\-\-BEGIN [A-Z ]*PRIVATE KEY\-\-\-\-\-'   && deny "private key block"
match 'gh[pousr]_[A-Za-z0-9]{36}'                      && deny "GitHub token"
match 'xox[baprs]-[0-9A-Za-z]{10}[0-9A-Za-z-]*'        && deny "Slack token"
match 'sk-ant-[A-Za-z0-9_-]{20}'                       && deny "Anthropic API key"
match 'sk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}'      && deny "OpenAI API key"
match 'AIza[0-9A-Za-z_-]{35}'                          && deny "Google API key"
match '(sk|rk)_live_[0-9a-zA-Z]{24}'                   && deny "Stripe live key"

printf '{"decision":"allow"}\n'
exit 0
