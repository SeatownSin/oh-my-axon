# oh-my-axon subagent report (Windows).
#
#   .\tools\subagents.ps1               summarise every recorded subagent run
#   .\tools\subagents.ps1 -Role NAME    one role only
#   .\tools\subagents.ps1 -Log PATH     read a specific telemetry log
#   .\tools\subagents.ps1 -Config PATH  resolve model windows from a config
#   .\tools\subagents.ps1 -Quiet        print only problems
#   .\tools\subagents.ps1 -Help         list every flag
#
# gen-roles assigns roles to models by reading parameter counts out of their
# names, and says so: SUGGESTIONS, not measurements. This reports what actually
# happened, from the SubagentStop hook's log, so the guess can be checked.
#
# TOK/S is generated tokens over time spent in the API, both read from the
# child's own billing ledger (Axon 0.3.6+). It is never derived from
# `tokensUsed`, which is the subagent's final CONTEXT size rather than anything
# it produced -- dividing that by elapsed time yields a throughput-shaped number
# that measures nothing, and it is why this column did not exist before.
#
# Runs that generated less than 100 tokens are left out of the rate. At that size
# the API time is nearly all prefill, so the figure describes how long the prompt
# took to read, not how fast the model writes. Excluded runs are always counted
# out loud rather than dropped quietly.
#
# Exit codes: 0 nothing to flag, 1 at least one problem, 2 usage error.
[CmdletBinding()]
param(
    [string]$Log,
    [string]$Config,
    [string]$Role,
    [switch]$Quiet,
    [switch]$Version,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$OmaVersion = '0.1.6'

# Below this many generated tokens a rate is prefill, not throughput.
$MinOutputTokens = 100
. (Join-Path $PSScriptRoot 'lib/Probe.ps1')

# Failures go straight to stderr rather than through Write-Error, which reflows
# a multi-line message to the console width. See tools/gen-roles.ps1.
function Write-Fail {
    param([string[]]$Line)
    foreach ($l in $Line) { [Console]::Error.WriteLine($l) }
}

if ($Version) { Write-Host "oh-my-axon $OmaVersion"; exit 0 }
if ($Help) {
    Write-Host @'
oh-my-axon subagent report.

  .\tools\subagents.ps1               summarise every recorded subagent run
  .\tools\subagents.ps1 -Role NAME    one role only
  .\tools\subagents.ps1 -Log PATH     read a specific telemetry log
  .\tools\subagents.ps1 -Config PATH  resolve model windows from a config
  .\tools\subagents.ps1 -Quiet        print only problems
  .\tools\subagents.ps1 -Version      print the version
  .\tools\subagents.ps1 -Help         print this text

TOK/S comes from the child's own ledger (Axon 0.3.6+): generated tokens over
time spent in the API. It is never derived from `tokensUsed`, which is the
subagent's final context size rather than anything it produced. Runs that
generated too little to measure are excluded and counted out loud.

Exit codes: 0 nothing to flag, 1 at least one problem, 2 usage error.
'@
    exit 0
}

$axonHome = if ($env:AXON_HOME) { $env:AXON_HOME } else { Join-Path $HOME '.axon' }
if (-not $Log)    { $Log = Join-Path $axonHome 'telemetry\subagents.jsonl' }
if (-not $Config) { $Config = Join-Path $axonHome 'config.toml' }

if (-not (Test-Path -LiteralPath $Log -PathType Leaf)) {
    Write-Fail @(
        "subagents: no telemetry log at $Log",
        '  The SubagentStop hook writes it. Install it with:',
        '    .\install.ps1 -WithTelemetry',
        '  Then run something that spawns a subagent.'
    )
    exit 2
}

# Overflow files exist only where a hook lost a race for the main log. Reading
# them back is what keeps that fallback from being a silent data loss.
$logFiles = @($Log)
$logDir = Split-Path -Parent $Log
if ($logDir -and (Test-Path -LiteralPath $logDir)) {
    # Skip the one already being read: -Log can name an overflow file itself,
    # and counting it twice would inflate every number in the report.
    $primary = (Resolve-Path -LiteralPath $Log).Path
    $logFiles += @(Get-ChildItem -LiteralPath $logDir -Filter 'subagents-overflow-*.jsonl' -File `
            -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $primary } |
        ForEach-Object { $_.FullName })
}

# The model windows. A model in the catalog with no context_window set gets
# Axon's own assumption of 200000, the same number doctor reports against.
$win = @{}
$inCatalog = @{}
if (Test-Path -LiteralPath $Config -PathType Leaf) {
    foreach ($e in (Get-ModelCatalog -Path $Config)) {
        $inCatalog[$e.Key] = $true
        $win[$e.Key] = [long]$e.Ctx
    }
}

function Get-MedianDouble {
    param([double[]]$Values)
    # An explicit count test, never `-not $Values`: a one-element array holding 0
    # unwraps to a falsy scalar, so that form reports "no data" for a real zero.
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    $s = @($Values | Sort-Object)
    $n = $s.Count
    if ($n % 2) { return [double]$s[($n - 1) / 2] }
    return ([double]$s[$n / 2 - 1] + [double]$s[$n / 2]) / 2
}

function Get-Median {
    param([long[]]$Values)
    # See Get-MedianDouble: `-not $Values` is wrong for a lone 0, which turned a
    # role whose single run made 0 tool calls into "-" instead of "0".
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    $s = @($Values | Sort-Object)
    $n = $s.Count
    if ($n % 2) { return [double]$s[($n - 1) / 2] }
    return ([double]$s[$n / 2 - 1] + [double]$s[$n / 2]) / 2
}

function Format-Duration {
    param($Ms)
    if ($null -eq $Ms) { return '-' }
    if ($Ms -lt 10000)  { return ('{0:0.0}s' -f ($Ms / 1000)) }
    if ($Ms -lt 600000) { return ('{0}s' -f [int][math]::Round($Ms / 1000)) }
    return ('{0}m{1:00}s' -f [int][math]::Floor($Ms / 60000), [int][math]::Round(($Ms % 60000) / 1000))
}

function Format-TokenCount {
    param($T)
    if ($null -eq $T) { return '-' }
    if ($T -lt 1000) { return ('{0}' -f [int]$T) }
    return ('{0:0.0}k' -f ($T / 1000))
}

function Format-Count {
    param($V)
    if ($null -eq $V) { return '-' }
    return ('{0:0.##}' -f $V)
}

$roles = [ordered]@{}
$noModel = 0
$total = 0
$globalFloor = $null

foreach ($file in $logFiles) {
    foreach ($line in (Get-Content -LiteralPath $file -Encoding UTF8)) {
        if (-not $line.Trim()) { continue }
        try { $rec = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $name = [string]$rec.subagentType
        if (-not $name) { continue }
        if ($Role -and $name -cne $Role) { continue }

        if (-not $roles.Contains($name)) {
            $roles[$name] = [pscustomobject]@{
                Runs = 0; Ok = 0; Bad = 0; Canc = 0; Other = 0
                Models = [System.Collections.Generic.List[string]]::new()
                LastError = ''
                Durations = [System.Collections.Generic.List[long]]::new()
                Tokens = [System.Collections.Generic.List[long]]::new()
                Turns = [System.Collections.Generic.List[long]]::new()
                Calls = [System.Collections.Generic.List[long]]::new()
                Rates = [System.Collections.Generic.List[double]]::new()
                Thin = 0; NoLedger = 0; ShortBilled = 0; CfgAttr = 0; Incomplete = 0
                Peak = 0L
            }
        }
        $r = $roles[$name]
        $r.Runs++
        $total++

        if ($null -eq $rec.model -or [string]$rec.model -eq '') {
            $noModel++
        } else {
            $m = [string]$rec.model
            if (-not $r.Models.Contains($m)) { $r.Models.Add($m) }
        }

        if ($null -eq $rec.exitCode) {
            $r.Other++
        } else {
            switch ([int]$rec.exitCode) {
                0  { $r.Ok++ }
                1  {
                    $r.Bad++
                    if ([string]$rec.error) { $r.LastError = [string]$rec.error }
                }
                -1 { $r.Canc++ }
                default { $r.Other++ }
            }
        }

        if ($null -ne $rec.durationMs) { $r.Durations.Add([long]$rec.durationMs) }
        if ($null -ne $rec.toolCalls)  { $r.Calls.Add([long]$rec.toolCalls) }
        if ($null -ne $rec.turns)      { $r.Turns.Add([long]$rec.turns) }
        if ($null -ne $rec.tokensUsed) {
            $t = [long]$rec.tokensUsed
            $r.Tokens.Add($t)
            if ($t -gt $r.Peak) { $r.Peak = $t }
            if ($null -eq $globalFloor -or $t -lt $globalFloor) { $globalFloor = $t }
        }

        # Generated tokens over API time, from the child ledger. Kept as a rate
        # per run and then taken at the median, rather than one ratio of two
        # grand totals: a single long run would otherwise decide the figure for a
        # role that is mostly short ones.
        $out = if ($null -ne $rec.outputTokens) { [long]$rec.outputTokens } else { 0L }
        $api = if ($null -ne $rec.apiDurationMs) { [long]$rec.apiDurationMs } else { 0L }
        $mCount = if ($null -ne $rec.modelCount) { [int]$rec.modelCount } else { 0 }
        $shortBill = [bool]$rec.usageIncomplete
        if ($shortBill) { $r.Incomplete++ }
        if ($mCount -eq 0) {
            $r.NoLedger++
        } elseif ($shortBill) {
            # Excluded on purpose. An under-counted numerator over a full
            # denominator understates the rate, and a quietly low number is worse
            # than none.
            $r.ShortBilled++
        } elseif ($out -ge $MinOutputTokens -and $api -gt 0) {
            $r.Rates.Add(($out * 1000.0) / $api)
        } else {
            $r.Thin++
        }
        if ([string]$rec.modelSource -eq 'config') { $r.CfgAttr++ }
    }
}

$notes = [System.Collections.Generic.List[string]]::new()
$problems = [System.Collections.Generic.List[string]]::new()
$rows = [System.Collections.Generic.List[string]]::new()

if ($total -eq 0) {
    if ($Role) {
        $problems.Add("no records for role `"$Role`". Roles are recorded exactly as the task tool named them.")
    } else {
        $problems.Add("$Log holds no readable records.")
    }
} else {
    if (-not $Quiet) {
        $rows.Add(('{0,-10} {1,-10} {2,5} {3,14} {4,9} {5,12} {6,8} {7,10} {8,10}' -f
            'ROLE', 'MODEL', 'RUNS', 'OK/FAIL/CANC', 'MED DUR', 'TURNS/CALLS',
            'TOK/S', 'PEAK CTX', 'OF WINDOW'))
    }

    $notedWindow = @{}
    foreach ($name in $roles.Keys) {
        $r = $roles[$name]
        $nModels = $r.Models.Count
        $label = if ($nModels -eq 0) { '?' }
                 elseif ($nModels -eq 1) { $r.Models[0] }
                 else { '{0}+{1}' -f $r.Models[$nModels - 1], ($nModels - 1) }
        $latest = if ($nModels -ge 1) { $r.Models[$nModels - 1] } else { '' }

        # Three cases, kept apart on purpose. A window read from the config
        # supports a finding; the 200000 Axon assumes supports a note; a model
        # that is not in the catalog at all supports neither, and printing a
        # percentage against a number nobody set would dress a guess up as a
        # measurement.
        $w = 0L; $known = $false; $assumed = $false
        if ($latest) {
            if ($win.ContainsKey($latest) -and $win[$latest] -gt 0) {
                $w = $win[$latest]; $known = $true
            } elseif ($inCatalog.ContainsKey($latest)) {
                $w = 200000L; $assumed = $true
            }
        }

        $pctNum = if ($r.Peak -gt 0 -and $w -gt 0) { $r.Peak * 100.0 / $w } else { $null }
        $pct = if ($null -ne $pctNum) { '{0}%' -f [int][math]::Round($pctNum) } else { '-' }

        if (-not $Quiet) {
            $mRate = Get-MedianDouble $r.Rates.ToArray()
            $rateStr = if ($null -eq $mRate) { '-' }
                       elseif ($mRate -ge 10) { '{0}' -f [int][math]::Floor($mRate + 0.5) }
                       else { '{0:0.0}' -f $mRate }
            $rows.Add(('{0,-10} {1,-10} {2,5} {3,14} {4,9} {5,12} {6,8} {7,10} {8,10}' -f
                $name.Substring(0, [math]::Min(10, $name.Length)),
                $label.Substring(0, [math]::Min(10, $label.Length)),
                $r.Runs,
                ('{0}/{1}/{2}' -f $r.Ok, $r.Bad, $r.Canc),
                (Format-Duration (Get-Median $r.Durations.ToArray())),
                ('{0}/{1}' -f (Format-Count (Get-Median $r.Turns.ToArray())), (Format-Count (Get-Median $r.Calls.ToArray()))),
                $rateStr,
                (Format-TokenCount $(if ($r.Peak -gt 0) { $r.Peak } else { $null })),
                $pct))
        }

        # Axon compacts at 85% of the window, so a role that got that high was
        # summarising its own context instead of doing the work. Stated as a
        # finding only when the window came from the config.
        if ($null -ne $pctNum -and $pctNum -ge 85) {
            if ($known) {
                $problems.Add(("{0} peaked at {1} of {2}'s {3} window ({4}%). Axon compacts at 85%, so this role was compacting mid-run: give it a model with more room, or split the task." -f
                    $name, (Format-TokenCount $r.Peak), $label, (Format-TokenCount $w), [int][math]::Round($pctNum)))
            } else {
                $notes.Add(('{0} peaked at {1}, which would be {2}% of the 200000 Axon assumes for {3}. Set context_window on that model to find out whether it really compacted.' -f
                    $name, (Format-TokenCount $r.Peak), [int][math]::Round($pctNum), $label))
            }
        }
        if ($r.Bad -gt 0) {
            if ($r.LastError) {
                $problems.Add(('{0} failed {1} of {2} run(s). Most recent error: {3}' -f $name, $r.Bad, $r.Runs, $r.LastError))
            } else {
                $problems.Add(('{0} failed {1} of {2} run(s), with no error text recorded.' -f $name, $r.Bad, $r.Runs))
            }
        }
        if ($r.Other -gt 0) {
            $problems.Add(('{0} has {1} run(s) with no exit status. Axon reports one only for completed, failed and cancelled.' -f $name, $r.Other))
        }
        if ($nModels -gt 1) {
            $notes.Add(('{0} ran on {1} different models over this log ({2}). Its medians mix them.' -f
                $name, $nModels, ($r.Models -join ', ')))
        }
        if ($latest -and -not $inCatalog.ContainsKey($latest)) {
            $notes.Add(('{0} ran on "{1}", which is not in your catalog now, so there is no window to measure its context against. Those numbers describe a model you have since renamed or removed.' -f
                $name, $latest))
        }
        # Every run left out of TOK/S is named. A rate over an unstated subset is
        # the same failure as a rate over the wrong number.
        $excluded = $r.Thin + $r.NoLedger + $r.ShortBilled
        if ($excluded -gt 0) {
            $why = ''
            if ($r.Thin -gt 0) {
                $why += '; {0} had too little generation to time, where API time is nearly all prefill (the bar is {1} tokens)' -f $r.Thin, $MinOutputTokens
            }
            if ($r.NoLedger -gt 0) {
                $why += '; {0} with no ledger (Axon before 0.3.6)' -f $r.NoLedger
            }
            if ($r.ShortBilled -gt 0) {
                $why += '; {0} reported a short bill, which would understate the rate' -f $r.ShortBilled
            }
            if ($r.Rates.Count -eq 0) {
                $notes.Add(('{0} has no TOK/S -- every run was excluded{1}.' -f $name, $why))
            } else {
                $notes.Add(('{0} computed TOK/S from {1} of {2} run(s){3}.' -f $name, $r.Rates.Count, $r.Runs, $why))
            }
        }
        # An authoritative name comes from the child itself. A name resolved from
        # config is only as current as the config.
        if ($r.CfgAttr -gt 0) {
            $notes.Add(('{0} had the model resolved from config on {1} of {2} run(s), not reported by Axon. Those names are right only if the config has not changed since.' -f
                $name, $r.CfgAttr, $r.Runs))
        }
        if ($r.Incomplete -gt 0) {
            $notes.Add(('{0} reported an incomplete bill on {1} run(s), so its token totals are a floor rather than a count.' -f $name, $r.Incomplete))
        }
        if ($nModels -gt 1 -and $r.Rates.Count -gt 0) {
            $notes.Add(('{0} mixes {1} models, so its TOK/S is a median across different machines rather than the speed of any one of them.' -f $name, $nModels))
        }
        # Once per model, not once per role that happens to use it.
        if ($assumed -and $null -ne $pctNum -and $pctNum -lt 85 -and -not $notedWindow.ContainsKey($latest)) {
            $notedWindow[$latest] = $true
            $notes.Add(('{0} sets no context_window, so "of window" for it is against the 200000 Axon assumes. tools\doctor.ps1 reports what the server actually serves.' -f $label))
        }
    }

    if ($noModel -gt 0) {
        $notes.Add(('{0} record(s) carry no model. They predate the shared parser being installed, or were written with no config.toml present.' -f $noModel))
    }
}

if (-not $Quiet -and $total -gt 0) {
    Write-Host ("oh-my-axon subagents -- {0} run(s) across {1} role(s) from {2}" -f $total, $roles.Count, $Log)
    if ($null -ne $globalFloor) {
        Write-Host ("Smallest run recorded: {0} of context. That is close to the fixed cost of a spawn, before a subagent does any work." -f (Format-TokenCount $globalFloor))
    }
    Write-Host ''
    foreach ($row in $rows) { Write-Host "  $row" }
}

if ($notes.Count -gt 0 -and -not $Quiet) {
    Write-Host ''
    Write-Host 'Notes:'
    foreach ($n in $notes) { Write-Host $n }
}

if ($problems.Count -eq 0) {
    if (-not $Quiet) {
        Write-Host ''
        Write-Host 'No problems found.'
    }
    exit 0
}

if (-not $Quiet) { Write-Host '' }
Write-Host 'Problems:'
foreach ($p in $problems) { Write-Host $p }
exit 1
