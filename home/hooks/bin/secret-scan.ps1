# oh-my-axon secret-scan gate (PreToolUse), Windows variant.
# Reads the tool payload from stdin and denies the call if it contains
# something that looks like a real credential. Runs entirely locally.

$payload = [Console]::In.ReadToEnd()

function Deny([string]$what) {
    $reason = "oh-my-axon secret-scan: $what detected in tool input. Keep credentials out of the repo (env var, or config outside the workspace) and retry without the secret."
    @{ decision = 'deny'; reason = $reason } | ConvertTo-Json -Compress | Write-Output
    exit 2
}

$patterns = [ordered]@{
    'AWS access key ID' = 'AKIA[0-9A-Z]{16}'
    'private key block' = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'GitHub token'      = 'gh[pousr]_[A-Za-z0-9]{36}'
    'Slack token'       = 'xox[baprs]-[0-9A-Za-z]{10}[0-9A-Za-z-]*'
    'Anthropic API key' = 'sk-ant-[A-Za-z0-9_-]{20}'
    'OpenAI API key'    = 'sk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}'
    'Google API key'    = 'AIza[0-9A-Za-z_-]{35}'
    'Stripe live key'   = '(sk|rk)_live_[0-9a-zA-Z]{24}'
}

foreach ($entry in $patterns.GetEnumerator()) {
    if ($payload -match $entry.Value) { Deny $entry.Key }
}

Write-Output '{"decision":"allow"}'
exit 0
