# oh-my-axon role-generator smoke tests (Windows).
#
#   pwsh -File tests\smoke-gen-roles.ps1
#
# Mirrors tests/smoke-gen-roles.sh: drives tools\gen-roles.ps1 against fixture
# configs and checks the assignments, the off-box exclusion, determinism, and
# that it never writes anything. Exits non-zero if any assertion fails.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$TestsDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $TestsDir
$Gen = Join-Path $RepoRoot 'tools\gen-roles.ps1'

. (Join-Path $TestsDir 'Helpers.ps1')

$Work = New-TempDir -Name 'genroles'
Write-Host "gen-roles: fixtures in $Work"

# Run the generator, capturing the snippet and the exit code. Errors are
# folded into the captured text so assertions can match on them.
#
# Line endings are normalized to LF: Out-String yields CRLF, and in a .NET
# multiline regex `$` matches before the `\n` but *after* the `\r`, so every
# end-anchored pattern would fail against output that is perfectly correct.
function Invoke-Gen {
    param([string[]]$GenArgs)
    $out = & pwsh -NoProfile -File $Gen @GenArgs 2>&1 | Out-String
    return [pscustomobject]@{ Out = ($out -replace "`r`n", "`n"); Code = $LASTEXITCODE }
}

# --- fixtures -------------------------------------------------------------
@'
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
'@ | Set-Content -LiteralPath (Join-Path $Work 'mixed.toml') -Encoding UTF8

@'
[model.only]
model = "qwen2.5-coder-32b-instruct"
base_url = "http://localhost:1234/v1"
'@ | Set-Content -LiteralPath (Join-Path $Work 'single.toml') -Encoding UTF8

@'
[model.hosted]
model = "something-70b"
base_url = "https://api.example.com/v1"
'@ | Set-Content -LiteralPath (Join-Path $Work 'remote-only.toml') -Encoding UTF8

@'
[models]
default = "nothing"
'@ | Set-Content -LiteralPath (Join-Path $Work 'empty.toml') -Encoding UTF8

@'
[model.zeta]
model = "zeta-120b"
base_url = "http://box.local:8000/v1"
[model.alpha]
model = "alpha-120b"
base_url = "http://box.local:8000/v1"
'@ | Set-Content -LiteralPath (Join-Path $Work 'tie.toml') -Encoding UTF8

@'
[model.mix]
model = "mixtral-8x7b-instruct"
base_url = "http://127.0.0.1:8080/v1"
[model.dense]
model = "qwen2.5-32b"
base_url = "http://127.0.0.1:8080/v1"
'@ | Set-Content -LiteralPath (Join-Path $Work 'moe.toml') -Encoding UTF8

$mixed = Join-Path $Work 'mixed.toml'

# --- role assignment ------------------------------------------------------
Write-Host ''
Write-Host 'role assignment'
$r = Invoke-Gen @('-Config', $mixed)
Assert-Equal 'mixed catalog exits 0' $r.Code 0
Assert-Match 'biggest local model becomes the default' $r.Out '(?m)^default = "big-box"$'
Assert-Match 'architect gets the big model' $r.Out '(?m)^architect = "big-box"'
Assert-Match 'executor gets the big model' $r.Out '(?m)^executor = "big-box"'
Assert-Match 'reviewer gets the big model' $r.Out '(?m)^reviewer = "big-box"'
Assert-Match 'scout gets the small model' $r.Out '(?m)^scout = "little"'
Assert-Match 'session titles get the small model' $r.Out '(?m)^session_summary = "little"'
Assert-Match 'looker gets the vision model' $r.Out '(?m)^looker = "eyes"'
Assert-Match 'image description gets the vision model' $r.Out '(?m)^image_description = "eyes"'
# The vision model is 13B -- bigger than the 3B -- and must still not be
# picked as "small", or a multimodal model ends up doing text chores.
Assert-NoMatch 'vision model is not used for text roles' $r.Out '(?m)^(default|scout|session_summary) = "eyes"'

# --- off-box exclusion ----------------------------------------------------
Write-Host ''
Write-Host 'off-box exclusion'
Assert-NoMatch 'hosted model is not assigned to any role' $r.Out '= "hosted"'
Assert-Match 'hosted model is reported as skipped' $r.Out '#\s+hosted -- Hosted'
Assert-Match 'usable count excludes the hosted model' $r.Out '3 usable model'

$r = Invoke-Gen @('-Config', $mixed, '-IncludeRemote')
Assert-Equal '-IncludeRemote exits 0' $r.Code 0
Assert-Match '-IncludeRemote promotes the 400B hosted model' $r.Out '(?m)^default = "hosted"$'

$r = Invoke-Gen @('-Config', (Join-Path $Work 'remote-only.toml'))
Assert-Equal 'all-remote catalog fails' $r.Code 1
Assert-Match 'all-remote explains itself' $r.Out 'served off-box'

# --- degenerate catalogs --------------------------------------------------
Write-Host ''
Write-Host 'degenerate catalogs'
$r = Invoke-Gen @('-Config', (Join-Path $Work 'single.toml'))
Assert-Equal 'single-model catalog exits 0' $r.Code 0
Assert-Match 'single model fills every role' $r.Out '(?m)^default = "only"$'
Assert-Match 'single model is called out' $r.Out 'Only one usable model'
Assert-Match 'looker is left commented out with no vision model' $r.Out '(?m)^# looker = '
Assert-NoMatch 'no bare image_description without a vision model' $r.Out '(?m)^image_description ='

$r = Invoke-Gen @('-Config', (Join-Path $Work 'empty.toml'))
Assert-Equal 'catalog with no [model.*] fails' $r.Code 1
Assert-Match 'empty catalog explains itself' $r.Out 'no \[model\.\*\] entries'

$r = Invoke-Gen @('-Config', (Join-Path $Work 'does-not-exist.toml'))
Assert-Equal 'missing config fails' $r.Code 1

# --- determinism ----------------------------------------------------------
Write-Host ''
Write-Host 'determinism'
$tie = Join-Path $Work 'tie.toml'
$first = (Invoke-Gen @('-Config', $tie)).Out
$second = (Invoke-Gen @('-Config', $tie)).Out
Assert-Equal 'repeated runs agree exactly' $second $first
Assert-Match 'same-size catalog says so rather than claiming one model' $second 'none reads as smaller'

# --- MoE sizing -----------------------------------------------------------
Write-Host ''
Write-Host 'MoE sizing'
$r = Invoke-Gen @('-Config', (Join-Path $Work 'moe.toml'))
Assert-Match '8x7b multiplies out to 56B and outranks 32B' $r.Out '(?m)^default = "mix"$'

# --- probe ----------------------------------------------------------------
# Port 1 rather than a plausible one: nothing listens there, the refusal is
# immediate, and pointing a test at :1234 or :8000 would quietly probe whatever
# the developer running it happens to have loaded.
Write-Host ''
Write-Host 'probe'
@'
[model.big-box]
model = "big-70b"
base_url = "http://127.0.0.1:1/v1"

[model.little]
model = "small-3b"
base_url = "http://127.0.0.1:1/v1"

[model.hosted]
model = "hosted-400b"
base_url = "https://api.example.invalid/v1"
'@ | Set-Content -LiteralPath (Join-Path $Work 'probe-down.toml') -Encoding UTF8
$probeDown = Join-Path $Work 'probe-down.toml'

$r = Invoke-Gen @('-Config', $probeDown, '-Probe')
Assert-Equal 'probe against a dead endpoint still exits 0' $r.Code 0
Assert-Match 'unreachable endpoint reports DOWN' $r.Out `
    '(?m)^#   DOWN   big-box -- http://127\.0\.0\.1:1/v1 \(no answer\)'
Assert-Match 'off-box entry is reported as not contacted' $r.Out `
    '(?m)^#   SKIP   hosted -- off-box, not contacted'
Assert-Match 'a dead model that holds roles is called out' $r.Out `
    '(?m)^#   big-box is assigned below \(default, architect, executor, reviewer\) but is not usable'
# The probe must not talk about ports nobody configured: the old version
# guessed :1234/:11434/:8000/:8080 and reported nothing useful on a LAN.
Assert-NoMatch 'probe does not guess ports' $r.Out '11434|:8080'
# Cheap version of the TOML parse below, so the invariant is still covered on
# a machine with no Python.
Assert-NoMatch 'probe output is comment-only' $r.Out '(?m)^[^#\s].*(UP|DOWN|STALE|SKIP)'

$plain = ((Invoke-Gen @('-Config', $probeDown)).Out -split "`n" | Where-Object { $_ -notmatch '^#' }) -join "`n"
$probed = ((Invoke-Gen @('-Config', $probeDown, '-Probe')).Out -split "`n" | Where-Object { $_ -notmatch '^#' }) -join "`n"
Assert-Equal 'probing never changes the assignments' $probed $plain

# --- probe against a live endpoint ----------------------------------------
# The UP / STALE / AUTH / context paths need something answering. A throwaway
# server keeps them deterministic instead of dependent on whatever the machine
# happens to be serving.
#
# `python` is tried before `python3` on purpose: on Windows `python3` is often
# the Microsoft Store stub, which resolves through Get-Command and then does
# not run anything. Each candidate has to actually answer --version.
$Py = $null
foreach ($cand in @('python', 'python3')) {
    $cmd = Get-Command $cand -ErrorAction SilentlyContinue
    if (-not $cmd) { continue }
    try { $ver = & $cmd.Source '--version' 2>&1 } catch { continue }
    if ($LASTEXITCODE -eq 0 -and "$ver" -match 'Python 3') { $Py = $cmd.Source; break }
}

# SupportsShouldProcess to satisfy the state-changing-verb rule, matching
# New-TempDir in Helpers.ps1.
function New-FakeServer {
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$ServerArgs)
    if (-not $PSCmdlet.ShouldProcess('fake model server', 'start')) { return $null }
    $log = Join-Path $Work 'fake.log'
    if (Test-Path $log) { Remove-Item -Force $log }
    $argList = @((Join-Path $TestsDir 'fake-openai-server.py')) + $ServerArgs
    $proc = Start-Process -FilePath $Py -ArgumentList $argList `
        -RedirectStandardOutput $log -NoNewWindow -PassThru
    $port = $null
    for ($i = 0; $i -lt 100; $i++) {
        if (Test-Path $log) {
            foreach ($line in (Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)) {
                if ($line -match '^PORT (\d+)$') { $port = $Matches[1]; break }
            }
        }
        if ($port) { break }
        Start-Sleep -Milliseconds 100
    }
    return [pscustomobject]@{ Proc = $proc; Port = $port }
}

if ($Py) {
    Write-Host ''
    Write-Host 'probe (live endpoint)'

    $fake = New-FakeServer -ServerArgs @('--id', 'served-70b', '--ctx', '262144')
    if (-not $fake.Port) {
        Assert-That 'fake server starts' $false 'no PORT line'
    } else {
        Assert-That 'fake server starts' $true
        $base = "http://127.0.0.1:$($fake.Port)/v1"

        # Served id matches, context agrees: UP and silent.
        @"
[model.served]
model = "served-70b"
base_url = "$base"
context_window = 262144
"@ | Set-Content -LiteralPath (Join-Path $Work 'probe-up.toml') -Encoding UTF8
        $r = Invoke-Gen @('-Config', (Join-Path $Work 'probe-up.toml'), '-Probe')
        Assert-Match 'a served model reports UP' $r.Out '(?m)^#   UP     served -- '
        Assert-NoMatch 'an agreeing context_window says nothing' $r.Out '# Problems:'

        # Same server, wrong id in the config: the endpoint is up but is not
        # serving what the catalog claims. This is the container-swap case.
        @"
[model.served]
model = "some-other-model"
base_url = "$base"
"@ | Set-Content -LiteralPath (Join-Path $Work 'probe-stale.toml') -Encoding UTF8
        $r = Invoke-Gen @('-Config', (Join-Path $Work 'probe-stale.toml'), '-Probe')
        Assert-Match 'an unserved id reports STALE and names what is served' $r.Out `
            '(?m)^#   STALE  served -- .*\(up, but serving served-70b -- not "some-other-model"\)'
        Assert-NoMatch 'the nested permission id is not mistaken for a model' $r.Out 'modelperm'

        # Context drift is the misconfiguration the footer warns about, so the
        # probe is the one thing able to actually catch it.
        @"
[model.served]
model = "served-70b"
base_url = "$base"
context_window = 8192
"@ | Set-Content -LiteralPath (Join-Path $Work 'probe-ctx.toml') -Encoding UTF8
        $r = Invoke-Gen @('-Config', (Join-Path $Work 'probe-ctx.toml'), '-Probe')
        Assert-Match 'a context_window that disagrees with the server is reported' $r.Out `
            '(?m)^#   served claims context_window = 8192; the server reports 262144\.'

        @"
[model.served]
model = "served-70b"
base_url = "$base"
"@ | Set-Content -LiteralPath (Join-Path $Work 'probe-noctx.toml') -Encoding UTF8
        $r = Invoke-Gen @('-Config', (Join-Path $Work 'probe-noctx.toml'), '-Probe')
        Assert-Match 'a missing context_window is reported against the server' $r.Out `
            '(?m)^#   served sets no context_window, but the server reports 262144\.'
    }
    if ($fake.Proc -and -not $fake.Proc.HasExited) {
        Stop-Process -Id $fake.Proc.Id -Force -ErrorAction SilentlyContinue
    }

    # A server that demands a token it is not given is up, not down -- saying
    # DOWN would send you looking at the wrong thing entirely.
    $fake = New-FakeServer -ServerArgs @('--id', 'served-70b', '--require-auth', 'sekrit')
    if ($fake.Port) {
        $base = "http://127.0.0.1:$($fake.Port)/v1"
        @"
[model.served]
model = "served-70b"
base_url = "$base"
"@ | Set-Content -LiteralPath (Join-Path $Work 'probe-auth.toml') -Encoding UTF8
        $r = Invoke-Gen @('-Config', (Join-Path $Work 'probe-auth.toml'), '-Probe')
        Assert-Match 'a rejected credential reports AUTH, not DOWN' $r.Out `
            '(?m)^#   AUTH   served -- .*rejected the credentials'

        # With the key configured the same server comes back UP, which is what
        # proves the probe sends it at all.
        @"
[model.served]
model = "served-70b"
base_url = "$base"
api_key = "sekrit"
"@ | Set-Content -LiteralPath (Join-Path $Work 'probe-authok.toml') -Encoding UTF8
        $r = Invoke-Gen @('-Config', (Join-Path $Work 'probe-authok.toml'), '-Probe')
        Assert-Match 'the configured api_key is actually sent' $r.Out '(?m)^#   UP     served -- '
        Assert-NoMatch 'the api_key never appears in the output' $r.Out 'sekrit'
    } else {
        Assert-That 'fake auth server starts' $false 'no PORT line'
    }
    if ($fake.Proc -and -not $fake.Proc.HasExited) {
        Stop-Process -Id $fake.Proc.Id -Force -ErrorAction SilentlyContinue
    }

    # Everything the probe emits is a comment, or the snippet stops being
    # pasteable. Checked by parsing rather than by regex, because a regex is
    # what would miss it.
    $r = Invoke-Gen @('-Config', $probeDown, '-Probe')
    Set-Content -LiteralPath (Join-Path $Work 'probed.toml') -Value $r.Out -Encoding UTF8
    $parseScript = Join-Path $Work 'parse.py'
    @'
import sys
try:
    import tomllib
except ModuleNotFoundError:
    sys.exit(0)
with open(sys.argv[1], "rb") as fh:
    d = tomllib.load(fh)
assert set(d) <= {"models", "subagents"}, d
assert "models" in d, d
'@ | Set-Content -LiteralPath $parseScript -Encoding UTF8
    & $Py $parseScript (Join-Path $Work 'probed.toml')
    Assert-That 'a probed snippet still parses as TOML' ($LASTEXITCODE -eq 0) `
        'the probe report escaped its comment prefix'
} else {
    Assert-That 'live-endpoint probe checks skipped (no python3)' $true
}

# --- redirection ----------------------------------------------------------
Write-Host ''
Write-Host 'redirection'
# Write-Host would not survive a redirect; the snippet has to be on the
# success stream or `gen-roles.ps1 > roles.toml` silently yields an empty file.
$redirected = Join-Path $Work 'redirected.toml'
& pwsh -NoProfile -File $Gen -Config $mixed > $redirected
Assert-That 'redirecting to a file captures the snippet' `
    ((Get-Content -LiteralPath $redirected -Raw) -match '(?m)^\[subagents\.models\]') `
    'the success stream is empty -- output went to the host instead'

# --- writes nothing -------------------------------------------------------
Write-Host ''
Write-Host 'side effects'
$sandbox = Join-Path $Work 'sandbox'
New-Item -ItemType Directory -Force $sandbox | Out-Null
$before = @(Get-ChildItem -Recurse -Force $sandbox | ForEach-Object { $_.FullName }) -join "`n"
$configBefore = (Get-FileHash -LiteralPath $mixed -Algorithm SHA256).Hash

$prevHome = $env:AXON_HOME
$env:AXON_HOME = $sandbox
try {
    [void](Invoke-Gen @('-Config', $mixed))
} finally {
    if ($null -eq $prevHome) { Remove-Item Env:\AXON_HOME -ErrorAction SilentlyContinue }
    else { $env:AXON_HOME = $prevHome }
}

$after = @(Get-ChildItem -Recurse -Force $sandbox | ForEach-Object { $_.FullName }) -join "`n"
Assert-Equal 'generator writes nothing under AXON_HOME' $after $before
Assert-Equal 'generator does not modify the config it reads' `
    (Get-FileHash -LiteralPath $mixed -Algorithm SHA256).Hash $configBefore

Remove-Item -Recurse -Force $Work
if (Write-Summary 'gen-roles: all checks passed') { exit 0 } else { exit 1 }
