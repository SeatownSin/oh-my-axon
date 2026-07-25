# oh-my-axon hook smoke tests (Windows).
#
#   pwsh -File tests/smoke-hooks.ps1
#
# Exercises the hook scripts the way Axon actually invokes them: payload on
# stdin, decision on stdout, exit code as the verdict. Exits non-zero if any
# assertion fails.
#
# The hooks are run under Windows PowerShell (5.1) when it is present,
# because that is what the installed hook command line uses -- `powershell`,
# not `pwsh`. Bugs that only appear under 5.1 have shipped before.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
$HookBin = Join-Path $RepoRoot 'home\hooks\bin'
$PsExe = if (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }

. (Join-Path $PSScriptRoot 'Helpers.ps1')

# Run a hook with $Payload on stdin. Returns @{ Out; Code }.
function Invoke-Hook {
    param([string]$Script, [string]$Payload)
    $out = ($Payload | & $PsExe -NoProfile -ExecutionPolicy Bypass -File $Script 2>&1 | Out-String).Trim()
    return @{ Out = $out; Code = $LASTEXITCODE }
}

function ConvertTo-PayloadJson {
    param([string]$FilePath)
    return (@{ tool_input = @{ file_path = $FilePath } } | ConvertTo-Json -Compress)
}

Write-Host "oh-my-axon hook smoke tests (hooks run under: $PsExe)"

# ---------------------------------------------------------------- secret-scan
Write-Host "`nsecret-scan (PreToolUse deny gate)"
$secretScan = Join-Path $HookBin 'secret-scan.ps1'

$r = Invoke-Hook -Script $secretScan -Payload '{"tool_input":{"command":"echo hello world"}}'
Assert-That 'benign payload is allowed (exit 0)' ($r.Code -eq 0) "exit=$($r.Code) out=$($r.Out)"
Assert-That 'benign payload reports allow' ($r.Out -match 'allow') "out=$($r.Out)"

# AWS's own documentation example key -- allowlisted by GitHub push protection
# and by AWS, so it is safe to commit, while still matching the AKIA pattern.
$awsFixture = 'AKIAIOSFODNN7EXAMPLE'
$r = Invoke-Hook -Script $secretScan -Payload (@{ tool_input = @{ command = "export KEY=$awsFixture" } } | ConvertTo-Json -Compress)
Assert-That 'AWS access key ID is denied (exit 2)' ($r.Code -eq 2) "exit=$($r.Code) out=$($r.Out)"
Assert-That 'deny decision is emitted' ($r.Out -match '"decision"\s*:\s*"deny"') "out=$($r.Out)"

# Remaining fixtures are assembled at runtime so that no literal credential
# pattern is ever stored in this file, which would trip push protection and
# the repo's own secret scanners.
$fixtures = @(
    @{ Name = 'GitHub token';      Value = 'ghp_' + ('a' * 36) }
    @{ Name = 'Slack token';       Value = 'xoxb-' + ('1' * 10) + '-abc' }
    @{ Name = 'Anthropic API key'; Value = 'sk-ant-' + ('A' * 20) }
    @{ Name = 'Google API key';    Value = 'AIza' + ('B' * 35) }
    @{ Name = 'Stripe live key';   Value = 'sk_live_' + ('c' * 24) }
    @{ Name = 'private key block'; Value = '-----BEGIN RSA PRIVATE KEY-----' }
)
foreach ($f in $fixtures) {
    $r = Invoke-Hook -Script $secretScan -Payload (@{ tool_input = @{ command = "x=$($f.Value)" } } | ConvertTo-Json -Compress)
    Assert-That "$($f.Name) is denied" ($r.Code -eq 2) "exit=$($r.Code) out=$($r.Out)"
}

# ------------------------------------------------------------ format-on-edit
Write-Host "`nformat-on-edit (PostToolUse, must never block)"
$fmt = Join-Path $HookBin 'format-on-edit.ps1'

# Regression: these all used to emit Get-Content errors and a non-zero exit,
# because `Test-Path $p -PathType Leaf -and (...)` bound -and as a Test-Path
# parameter instead of grouping two booleans. Silence is the assertion.
$plain = New-TempDir 'plain'
Set-Content (Join-Path $plain 'a.txt') 'hello'

$quiet = @(
    @{ Name = 'invalid JSON';       Payload = 'not json at all' }
    @{ Name = 'empty stdin';        Payload = '' }
    @{ Name = 'no path key';        Payload = '{"tool_input":{"foo":"bar"}}' }
    @{ Name = 'nonexistent file';   Payload = (ConvertTo-PayloadJson (Join-Path $plain 'nope.rs')) }
    @{ Name = 'no formatter found'; Payload = (ConvertTo-PayloadJson (Join-Path $plain 'a.txt')) }
)
foreach ($c in $quiet) {
    $r = Invoke-Hook -Script $fmt -Payload $c.Payload
    Assert-That "$($c.Name): exits 0" ($r.Code -eq 0) "exit=$($r.Code)"
    Assert-That "$($c.Name): stays silent" ($r.Out -eq '') "output was: $($r.Out)"
}

# Positive path: a Cargo project actually gets formatted.
if (Get-Command rustfmt -ErrorAction SilentlyContinue) {
    $rust = New-TempDir 'rust'
    New-Item -ItemType Directory -Force (Join-Path $rust 'src') | Out-Null
    Set-Content (Join-Path $rust 'Cargo.toml') "[package]`nname = `"smoke`""
    $mainRs = Join-Path $rust 'src\main.rs'
    Set-Content $mainRs 'fn main(){let x=1;println!("{}",x);}'
    $r = Invoke-Hook -Script $fmt -Payload (ConvertTo-PayloadJson $mainRs)
    $after = (Get-Content $mainRs -Raw)
    Assert-That 'rust project: exits 0' ($r.Code -eq 0) "exit=$($r.Code)"
    Assert-That 'rust project: file was reformatted' ($after -match 'let x = 1;') "after: $after"
    Remove-Item -Recurse -Force $rust
} else {
    Write-Host '  skip rustfmt positive case (rustfmt not on PATH)'
}

Remove-Item -Recurse -Force $plain

# ----------------------------------------------------------------- summary
if (Write-Summary 'hook smoke tests passed') { exit 0 } else { exit 1 }
