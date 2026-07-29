# oh-my-axon doctor smoke tests (Windows).
#
#   pwsh -File tests\smoke-doctor.ps1
#
# Mirrors tests/smoke-doctor.sh: drives tools\doctor.ps1 against fixture
# configs and a throwaway server, and checks the statuses, the exit codes, the
# role-dependency reporting, and that it never writes anything.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$TestsDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $TestsDir
$Doctor = Join-Path $RepoRoot 'tools\doctor.ps1'

. (Join-Path $TestsDir 'Helpers.ps1')

$Work = New-TempDir -Name 'doctor'
Write-Host "doctor: fixtures in $Work"

# Line endings normalized to LF: Out-String yields CRLF, and in a .NET
# multiline regex `$` matches before the `\n` but AFTER the `\r`, so every
# end-anchored pattern would fail against output that is perfectly correct.
function Invoke-Doctor {
    param([string[]]$DocArgs)
    $out = & pwsh -NoProfile -File $Doctor @DocArgs 2>&1 | Out-String
    return [pscustomobject]@{ Out = ($out -replace "`r`n", "`n"); Code = $LASTEXITCODE }
}

# --- argument handling ------------------------------------------------------
Write-Host "`nargument handling"
$r = Invoke-Doctor @('-Help')
Assert-Equal '-Help exits 0' $r.Code 0
Assert-Match '-Help lists -Generate' $r.Out '-Generate'

$r = Invoke-Doctor @('-Version')
Assert-Equal '-Version exits 0' $r.Code 0
Assert-Match '-Version prints a semver' $r.Out 'oh-my-axon \d+\.\d+\.\d+'

# PowerShell's parameter binder refuses an unknown flag before the script runs.
$r = Invoke-Doctor @('-Bogus')
Assert-That 'unknown flag is refused' ($r.Code -ne 0) "expected non-zero, got $($r.Code)"

$r = Invoke-Doctor @('-Config', (Join-Path $Work 'does-not-exist.toml'))
Assert-Equal 'missing config exits 2' $r.Code 2

@'
[models]
default = "nothing"
'@ | Set-Content -LiteralPath (Join-Path $Work 'empty.toml') -Encoding UTF8
$r = Invoke-Doctor @('-Config', (Join-Path $Work 'empty.toml'))
Assert-Equal 'config with no [model.*] exits 2' $r.Code 2
Assert-Match 'empty catalog explains itself' $r.Out 'no \[model\.\*\] entries'

# --- unreachable and off-box ------------------------------------------------
# Port 1: nothing listens there and the refusal is immediate, where :1234 would
# probe whatever the developer running this happens to have loaded.
Write-Host "`nunreachable and off-box"
@'
[model.dead]
model = "dead-70b"
base_url = "http://127.0.0.1:1/v1"

[model.hosted]
model = "hosted-70b"
base_url = "https://api.example.invalid/v1"

[models]
default = "dead"
'@ | Set-Content -LiteralPath (Join-Path $Work 'down.toml') -Encoding UTF8
$down = Join-Path $Work 'down.toml'

$r = Invoke-Doctor @('-Config', $down)
Assert-Equal 'a broken fleet exits 1' $r.Code 1
Assert-Match 'unreachable model reports DOWN' $r.Out '(?m)^  DOWN   dead -- http://127\.0\.0\.1:1/v1'
Assert-Match 'unreachable model is explained' $r.Out 'dead is unreachable'
Assert-Match 'off-box entry is not contacted' $r.Out '(?m)^  SKIP   hosted -- off-box, not contacted'
Assert-Match 'a broken model names the roles it breaks' $r.Out 'this breaks: default'
Assert-NoMatch 'off-box endpoint produced no problem' $r.Out 'hosted is unreachable'

@'
[model.vendor]
model = "some-hosted-model"
'@ | Set-Content -LiteralPath (Join-Path $Work 'nourl.toml') -Encoding UTF8
$r = Invoke-Doctor @('-Config', (Join-Path $Work 'nourl.toml'))
Assert-Match 'an entry with no base_url is skipped' $r.Out 'SKIP   vendor -- no base_url'

# --- values containing a hash ----------------------------------------------
# TOML comment stripping must respect quotes. It did not: `api_key = "abc#def"`
# was truncated to `abc`, which reaches the server as a wrong key and comes
# back as a puzzling 401 that blames the credential rather than the parser.
Write-Host "`nvalues containing a hash"
@'
[model.served]
model = "served-70b"
base_url = "http://127.0.0.1:1/v1"
api_key = "abc#def123"
name = "GPU #2 box"
context_window = 4096  # trailing comment on a bare value
'@ | Set-Content -LiteralPath (Join-Path $Work 'hash.toml') -Encoding UTF8
$hashCfg = Join-Path $Work 'hash.toml'
. (Join-Path $RepoRoot 'tools\lib\Probe.ps1')
Assert-Equal 'a hash inside a quoted api_key survives' `
    (Get-ProbeSectionValue -Path $hashCfg -Key 'served' -Field 'api_key') 'abc#def123'
Assert-Equal 'a hash inside a quoted name survives' `
    (Get-ProbeSectionValue -Path $hashCfg -Key 'served' -Field 'name') 'GPU #2 box'
Assert-Equal 'a trailing comment on a bare value is still stripped' `
    (Get-ProbeSectionValue -Path $hashCfg -Key 'served' -Field 'context_window') '4096'

# --- roles read from [subagents.models] -------------------------------------
Write-Host "`nrole attribution"
@'
[model.dead]
model = "dead-70b"
base_url = "http://127.0.0.1:1/v1"

[models]
default = "other"

[subagents.models]
executor = "dead"
reviewer = "dead"
'@ | Set-Content -LiteralPath (Join-Path $Work 'subagents.toml') -Encoding UTF8
$r = Invoke-Doctor @('-Config', (Join-Path $Work 'subagents.toml'))
Assert-Match 'roles are read from [subagents.models] too' $r.Out 'this breaks: executor, reviewer'

# --- against a live endpoint ------------------------------------------------
# `python` before `python3`: on Windows `python3` is often the Microsoft Store
# stub, which resolves through Get-Command and then runs nothing.
$Py = $null
foreach ($cand in @('python', 'python3')) {
    $cmd = Get-Command $cand -ErrorAction SilentlyContinue
    if (-not $cmd) { continue }
    try { $ver = & $cmd.Source '--version' 2>&1 } catch { continue }
    if ($LASTEXITCODE -eq 0 -and "$ver" -match 'Python 3') { $Py = $cmd.Source; break }
}

# SupportsShouldProcess to satisfy the state-changing-verb rule, matching
# New-TempDir in Helpers.ps1.
$script:FakeSeq = 0
function New-FakeServer {
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$ServerArgs)
    if (-not $PSCmdlet.ShouldProcess('fake model server', 'start')) { return $null }
    # A unique log per server: Stop-Process is asynchronous, so reusing one
    # filename races the OS releasing the handle and fails the next start with
    # "the file is being used by another process" -- an intermittent CI red.
    $script:FakeSeq++
    $log = Join-Path $Work ("fake-{0}.log" -f $script:FakeSeq)
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
    Write-Host "`nlive endpoint"
    $fake = New-FakeServer -ServerArgs @('--id', 'served-70b', '--ctx', '262144')
    if (-not $fake.Port) {
        Assert-That 'fake server starts' $false 'no PORT line'
    } else {
        Assert-That 'fake server starts' $true
        $base = "http://127.0.0.1:$($fake.Port)/v1"

        @"
[model.served]
model = "served-70b"
base_url = "$base"
context_window = 262144
"@ | Set-Content -LiteralPath (Join-Path $Work 'ok.toml') -Encoding UTF8
        $ok = Join-Path $Work 'ok.toml'
        $r = Invoke-Doctor @('-Config', $ok)
        Assert-Equal 'a healthy fleet exits 0' $r.Code 0
        Assert-Match 'a served model reports UP' $r.Out '(?m)^  UP     served -- '
        Assert-Match 'a healthy fleet says so' $r.Out 'No problems found'

        @"
[model.served]
model = "some-other-model"
base_url = "$base"
"@ | Set-Content -LiteralPath (Join-Path $Work 'stale.toml') -Encoding UTF8
        $r = Invoke-Doctor @('-Config', (Join-Path $Work 'stale.toml'))
        Assert-Equal 'a stale endpoint exits 1' $r.Code 1
        Assert-Match 'an unserved id reports STALE' $r.Out '(?m)^  STALE  served -- '
        Assert-Match 'STALE names what is actually served' $r.Out 'serving served-70b, not "some-other-model"'

        @"
[model.served]
model = "served-70b"
base_url = "$base"
context_window = 8192
"@ | Set-Content -LiteralPath (Join-Path $Work 'ctx.toml') -Encoding UTF8
        $r = Invoke-Doctor @('-Config', (Join-Path $Work 'ctx.toml'))
        Assert-Equal 'context drift exits 1' $r.Code 1
        Assert-Match 'context drift is reported' $r.Out 'claims context_window = 8192; the server reports 262144'

        @"
[model.served]
model = "served-70b"
base_url = "$base"
"@ | Set-Content -LiteralPath (Join-Path $Work 'noctx.toml') -Encoding UTF8
        $r = Invoke-Doctor @('-Config', (Join-Path $Work 'noctx.toml'))
        Assert-Match 'a missing context_window is reported' $r.Out 'sets no context_window; the server reports 262144'

        $r = Invoke-Doctor @('-Config', $ok, '-Quiet')
        Assert-Equal '-Quiet on a healthy fleet exits 0' $r.Code 0
        Assert-Equal '-Quiet prints nothing when all is well' $r.Out.Trim() ''
    }
    if ($fake.Proc -and -not $fake.Proc.HasExited) {
        Stop-Process -Id $fake.Proc.Id -Force -ErrorAction SilentlyContinue
        [void]$fake.Proc.WaitForExit(5000)
    }

    $fake = New-FakeServer -ServerArgs @('--id', 'served-70b', '--require-auth', 'sekrit')
    if ($fake.Port) {
        $base = "http://127.0.0.1:$($fake.Port)/v1"
        @"
[model.served]
model = "served-70b"
base_url = "$base"
"@ | Set-Content -LiteralPath (Join-Path $Work 'auth.toml') -Encoding UTF8
        $r = Invoke-Doctor @('-Config', (Join-Path $Work 'auth.toml'))
        Assert-Match 'a rejected credential reports AUTH, not DOWN' $r.Out '(?m)^  AUTH   served -- '
        Assert-Match 'AUTH suggests the fix' $r.Out 'Check api_key, or set no_auth'

        @"
[model.served]
model = "served-70b"
base_url = "$base"
api_key = "sekrit"
"@ | Set-Content -LiteralPath (Join-Path $Work 'authok.toml') -Encoding UTF8
        $r = Invoke-Doctor @('-Config', (Join-Path $Work 'authok.toml'))
        Assert-Match 'the configured api_key is actually sent' $r.Out '(?m)^  UP     served -- '
        Assert-NoMatch 'the api_key never appears in the output' $r.Out 'sekrit'
    } else {
        Assert-That 'fake auth server starts' $false 'no PORT line'
    }
    if ($fake.Proc -and -not $fake.Proc.HasExited) {
        Stop-Process -Id $fake.Proc.Id -Force -ErrorAction SilentlyContinue
        [void]$fake.Proc.WaitForExit(5000)
    }
} else {
    Assert-That 'live-endpoint checks skipped (no python3)' $true
}

# --- writes nothing ---------------------------------------------------------
Write-Host "`nside effects"
$sandbox = Join-Path $Work 'sandbox'
New-Item -ItemType Directory -Force $sandbox | Out-Null
$before = @(Get-ChildItem -Recurse -Force $sandbox | ForEach-Object { $_.FullName }) -join "`n"
$configBefore = (Get-FileHash -LiteralPath $down -Algorithm SHA256).Hash

$prevHome = $env:AXON_HOME
$env:AXON_HOME = $sandbox
try { [void](Invoke-Doctor @('-Config', $down)) }
finally {
    if ($null -eq $prevHome) { Remove-Item Env:\AXON_HOME -ErrorAction SilentlyContinue }
    else { $env:AXON_HOME = $prevHome }
}

$after = @(Get-ChildItem -Recurse -Force $sandbox | ForEach-Object { $_.FullName }) -join "`n"
Assert-Equal 'doctor writes nothing under AXON_HOME' $after $before
Assert-Equal 'doctor does not modify the config it reads' `
    (Get-FileHash -LiteralPath $down -Algorithm SHA256).Hash $configBefore

Remove-Item -Recurse -Force $Work
if (Write-Summary 'doctor: all checks passed') { exit 0 } else { exit 1 }
