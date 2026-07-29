# oh-my-axon fleet doctor (Windows).
#
#   .\tools\doctor.ps1                  check every model in ~\.axon\config.toml
#   .\tools\doctor.ps1 -Config PATH     check a specific config file
#   .\tools\doctor.ps1 -Quiet           print only problems
#   .\tools\doctor.ps1 -IncludeRemote   check off-box endpoints too
#   .\tools\doctor.ps1 -Generate        also send one completion per model
#   .\tools\doctor.ps1 -Help            list every flag
#
# Answers one question before you start a long run: is the fleet your config
# describes actually there? A model that is down, swapped, or lying about its
# context window fails in the middle of a pipeline, as an inference error that
# says nothing about the real cause.
#
# Exit codes: 0 all clear, 1 at least one problem, 2 usage error.
#
# Axon ships `memory doctor` and `mcp doctor`. Neither looks at models, which
# is why this exists rather than extending one of those.
#
# Off-box endpoints are not contacted unless -IncludeRemote: this distribution
# does not reach off your machine on its own.
[CmdletBinding()]
param(
    [string]$Config,
    [switch]$Quiet,
    [switch]$IncludeRemote,
    [switch]$Generate,
    [switch]$Version,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$OmaVersion = '0.1.3'
. (Join-Path $PSScriptRoot 'lib/Probe.ps1')

# Failures go straight to stderr rather than through Write-Error, which
# reflows a multi-line message to the console width. See tools/gen-roles.ps1.
function Write-Fail {
    param([string[]]$Line)
    foreach ($l in $Line) { [Console]::Error.WriteLine($l) }
}

if ($Version) { Write-Host "oh-my-axon $OmaVersion"; exit 0 }
if ($Help) {
    Write-Host @'
oh-my-axon fleet doctor.

  .\tools\doctor.ps1                  check every model in ~\.axon\config.toml
  .\tools\doctor.ps1 -Config PATH     check a specific config file
  .\tools\doctor.ps1 -Quiet           print only problems
  .\tools\doctor.ps1 -IncludeRemote   check off-box endpoints too
  .\tools\doctor.ps1 -Generate        also send one completion per model
  .\tools\doctor.ps1 -Version         print the version
  .\tools\doctor.ps1 -Help            print this text

Exit codes: 0 all clear, 1 at least one problem, 2 usage error.
'@
    exit 0
}

if (-not $Config) {
    $axonHome = if ($env:AXON_HOME) { $env:AXON_HOME } else { Join-Path $HOME '.axon' }
    $Config = Join-Path $axonHome 'config.toml'
}
if (-not (Test-Path $Config -PathType Leaf)) {
    Write-Fail @("doctor: no config at $Config",
                 '  Run `axon` once so the first-run wizard detects your servers,',
                 '  or point at a config with -Config PATH.')
    exit 2
}

$catalog = @(Get-ModelCatalog -Path $Config)
if ($catalog.Count -eq 0) {
    Write-Fail @("doctor: $Config defines no [model.*] entries.",
                 '  Run `axon` once to let the wizard detect your servers, or see',
                 '  config/config.toml.snippet for hand configuration.')
    exit 2
}

# Which catalog keys a role actually depends on, so a broken model is reported
# as "this breaks something" rather than just "this is down".
function Get-RolesUsing {
    param([string]$Path, [string]$Key)
    $sec = ''
    $out = @()
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($line -match '^\s*\[models\]') { $sec = 'models'; continue }
        if ($line -match '^\s*\[subagents\.models\]') { $sec = 'subagents'; continue }
        if ($line -match '^\s*\[') { $sec = ''; continue }
        if (-not $sec) { continue }
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$') {
            $v = (Get-TomlValue $line)
            if ($v -ceq $Key) { $out += $Matches[1] }
        }
    }
    return ($out -join ', ')
}

$problems = @()
$rows = @()
$checked = 0

foreach ($e in $catalog) {
    $used = Get-RolesUsing -Path $Config -Key $e.Key
    if (-not $e.Url) {
        $rows += "  SKIP   $($e.Key) -- no base_url, nothing to contact"
        continue
    }
    if ((-not $IncludeRemote) -and (-not $e.IsLocal)) {
        $rows += "  SKIP   $($e.Key) -- off-box, not contacted"
        continue
    }

    $checked++
    $key = Get-ProbeAuthKey -Path $Config -Key $e.Key
    $res = Invoke-ProbeRequest -Url (Get-ProbeModelsEndpoint $e.Url) -AuthKey $key -TimeoutSec 5
    $ids = Get-ServedModelId -Body $res.Body

    if ($res.Code -eq 0) {
        $status = 'DOWN'
        $problems += "$($e.Key) is unreachable at $($e.Url)."
    } elseif ($res.Code -eq 401 -or $res.Code -eq 403) {
        $status = 'AUTH'
        $problems += "$($e.Key) refused the credentials in your config (HTTP $($res.Code)). Check api_key, or set no_auth = true."
    } elseif ($res.Code -ge 200 -and $res.Code -lt 300) {
        if ($e.Model -and ($ids -ccontains $e.Model)) {
            $status = 'UP'
        } else {
            $status = 'STALE'
            if ($ids.Count -gt 0) {
                $problems += "$($e.Key) points at a server that is up but serving $($ids -join ', '), not ""$($e.Model)""."
            } else {
                $problems += "$($e.Key) points at a server that is up but serving nothing."
            }
        }
    } else {
        $status = 'DOWN'
        $problems += "$($e.Key) returned HTTP $($res.Code) from $($e.Url)."
    }

    if ($used -and $status -cne 'UP') { $problems += "  ^ this breaks: $used" }

    # Context window: the single most common local-model misconfiguration.
    # Axon assumes 200000 when unset and compacts at 85% of whatever is
    # claimed, so a wrong number compacts at the wrong time.
    if ($status -ceq 'UP') {
        $srv = Get-ServedContext -Body $res.Body -WireId $e.Model
        if ($null -ne $srv -and $e.Ctx -eq 0) {
            $problems += "$($e.Key) sets no context_window; the server reports $srv. Axon assumes 200000."
        } elseif ($null -ne $srv -and $e.Ctx -ne $srv) {
            $problems += "$($e.Key) claims context_window = $($e.Ctx); the server reports $srv."
        }
    }

    if ($status -ceq 'UP' -and $Generate) {
        # Send the request the way Axon would -- with this model's configured
        # chat_template_kwargs. Asking bare tests a configuration nobody uses.
        $kw = Get-ProbeTemplateKwargJson -Path $Config -Key $e.Key
        $body = if ($kw) {
            '{"model":"' + $e.Model + '","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":64,"stream":false,"chat_template_kwargs":' + $kw + '}'
        } else {
            '{"model":"' + $e.Model + '","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":64,"stream":false}'
        }
        # 120s, because the first completion against an idle server can trigger
        # a model load. A timeout here means "slow or loading", not "broken".
        $gen = Invoke-ProbeRequest -Url (($e.Url.TrimEnd('/')) + '/chat/completions') `
            -AuthKey $key -Body $body -TimeoutSec 120
        if ($gen.Code -ge 200 -and $gen.Code -lt 300) {
            if ($gen.Body -match '</?think>') {
                $problems += "$($e.Key) leaks reasoning into the reply text even with its configured chat_template_kwargs. Set enable_thinking on [model.$($e.Key)] so the server parses it out."
            }
        } elseif ($gen.Code -eq 0) {
            $problems += "$($e.Key) served /models but did not finish a completion within 120s. That is usually a cold model load, not a fault -- re-run once it is warm."
        } else {
            $problems += "$($e.Key) served /models but returned HTTP $($gen.Code) from /chat/completions."
        }
    }

    $rows += ("  {0,-5}  {1} -- {2}" -f $status, $e.Key, $e.Url)
}

if (-not $Quiet) {
    Write-Host "oh-my-axon doctor -- $checked endpoint(s) contacted from $Config"
    Write-Host ''
    foreach ($r in $rows) { Write-Host $r }
    Write-Host ''
}

if ($problems.Count -eq 0) {
    if (-not $Quiet) { Write-Host 'No problems found.' }
    exit 0
}
Write-Host 'Problems:'
foreach ($p in $problems) { Write-Host $p }
exit 1
