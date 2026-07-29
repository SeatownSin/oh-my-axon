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
# What it will not tell you is tokens per second. The `tokensUsed` Axon reports
# is the subagent's final context size, not the number of tokens it generated --
# dividing it by the elapsed time yields a number that looks like throughput and
# measures nothing. Context pressure and latency are what this data supports.
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
$OmaVersion = '0.1.5'
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

This does not report tokens per second. Axon's `tokensUsed` is the subagent's
final context size, not what it generated, so dividing by elapsed time measures
nothing. Context pressure and latency are what this data supports.

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

function Get-Median {
    param([long[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
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
        $rows.Add(('{0,-10} {1,-10} {2,5} {3,14} {4,9} {5,12} {6,10} {7,10}' -f
            'ROLE', 'MODEL', 'RUNS', 'OK/FAIL/CANC', 'MED DUR', 'TURNS/CALLS', 'PEAK CTX', 'OF WINDOW'))
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
            $rows.Add(('{0,-10} {1,-10} {2,5} {3,14} {4,9} {5,12} {6,10} {7,10}' -f
                $name.Substring(0, [math]::Min(10, $name.Length)),
                $label.Substring(0, [math]::Min(10, $label.Length)),
                $r.Runs,
                ('{0}/{1}/{2}' -f $r.Ok, $r.Bad, $r.Canc),
                (Format-Duration (Get-Median $r.Durations.ToArray())),
                ('{0}/{1}' -f (Format-Count (Get-Median $r.Turns.ToArray())), (Format-Count (Get-Median $r.Calls.ToArray()))),
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
