# oh-my-axon subagent telemetry smoke tests (Windows).
#
#   pwsh -File tests\smoke-subagents.ps1
#
# Drives the SubagentStop hook against real captured payloads and
# tools\subagents.ps1 against fixture logs. Checks that the hook writes valid
# JSON on every path, that it never fails a run, and that the report refuses to
# state a finding it cannot support. Exits non-zero if any assertion fails.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$TestsDir = $PSScriptRoot
$RepoRoot = Split-Path $TestsDir -Parent
$Report = Join-Path $RepoRoot 'tools\subagents.ps1'
$HookSrc = Join-Path $RepoRoot 'home\hooks\bin\subagent-telemetry.ps1'

. (Join-Path $TestsDir 'Helpers.ps1')

$Work = New-TempDir -Name 'subagents'

# Run the report and capture stdout+stderr together, the way the sh suite does.
function Invoke-Report {
    param([string[]]$ReportArgs)
    $script:Out = (& pwsh -NoProfile -File $Report @ReportArgs 2>&1 | Out-String)
    $script:Code = $LASTEXITCODE
}

# Feed one payload file to the hook under a given AXON_HOME.
function Invoke-Hook {
    param([string]$AxonHome, [string]$PayloadFile)
    $prev = $env:AXON_HOME
    $env:AXON_HOME = $AxonHome
    try {
        Get-Content -LiteralPath $PayloadFile -Raw |
            & pwsh -NoProfile -File (Join-Path $AxonHome 'hooks\bin\subagent-telemetry.ps1')
        return $LASTEXITCODE
    } finally {
        $env:AXON_HOME = $prev
    }
}

# A throwaway AXON_HOME laid out the way the installer lays one out, so the
# hook's own path resolution is what gets exercised.
$HomeDir = Join-Path $Work 'axonhome'
New-Item -ItemType Directory -Force (Join-Path $HomeDir 'hooks\bin') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $HomeDir 'hooks\lib') | Out-Null
Copy-Item $HookSrc (Join-Path $HomeDir 'hooks\bin\subagent-telemetry.ps1')
Copy-Item (Join-Path $RepoRoot 'tools\lib\Probe.ps1') (Join-Path $HomeDir 'hooks\lib\Probe.ps1')

@'
[model.big]
model = "big-70b"
base_url = "http://127.0.0.1:1/v1"
context_window = 131072

[model.small]
model = "small-12b"
base_url = "http://127.0.0.1:2/v1"

[models]
default = "big"

[subagents.models]
scout = "small"       # read-only recon, and a trailing comment to survive
'@ | Set-Content -LiteralPath (Join-Path $HomeDir 'config.toml') -Encoding ascii

$Log = Join-Path $HomeDir 'telemetry\subagents.jsonl'

Write-Host "hook: fixtures in $Work"

# --- the hook writes one valid record per firing -----------------------------
Write-Host ''
Write-Host 'hook output'

# The exact shape Axon 0.3.5 puts on the wire, including the `subagent_end`
# event name it reports even though the hook is registered as SubagentStop.
$okPayload = Join-Path $Work 'ok.json'
@'
{"hookEventName":"subagent_end","sessionId":"019f","cwd":"/w","workspaceRoot":"/w","timestamp":"2026-07-29T22:17:43.120271600+00:00","subagentId":"019f-677e","subagentType":"executor","description":"Executor agent - reply BLUE","exitCode":0,"durationMs":5193,"tokensUsed":6962,"toolCalls":0,"turns":1}
'@ | Set-Content -LiteralPath $okPayload -Encoding ascii

$code = Invoke-Hook -AxonHome $HomeDir -PayloadFile $okPayload
Assert-Equal 'the hook exits 0' $code 0
Assert-File 'the hook creates the log' $Log
$lines = @(Get-Content -LiteralPath $Log)
Assert-Match 'the record carries the role' $lines[0] '"subagentType":"executor"'
Assert-Match 'the record carries the token count' $lines[0] '"tokensUsed":6962'
Assert-Match 'the record carries the duration' $lines[0] '"durationMs":5193'
Assert-Match 'the record resolves the role to a model' $lines[0] '"model":"big"'
# The description is derived from what the user asked for. A measurements log
# has no business holding it.
Assert-NoMatch 'the prompt description is not recorded' $lines[0] 'reply BLUE'
Assert-NoMatch 'the transcript path is not recorded' $lines[0] 'transcriptPath'

# No BOM anywhere in the file: PowerShell 5.1's `-Encoding utf8` writes one,
# and a BOM mid-file is a line no JSON reader accepts.
$bytes = [System.IO.File]::ReadAllBytes($Log)
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
Assert-That 'the log starts with no byte order mark' (-not $hasBom) 'found a UTF-8 BOM'

# A pin in [subagents.models] wins over [models] default, and the trailing
# comment on that line must not become part of the value.
$scoutPayload = Join-Path $Work 'scout.json'
@'
{"hookEventName":"subagent_end","subagentType":"scout","exitCode":0,"durationMs":6100,"tokensUsed":6900,"toolCalls":0,"turns":1}
'@ | Set-Content -LiteralPath $scoutPayload -Encoding ascii
Invoke-Hook -AxonHome $HomeDir -PayloadFile $scoutPayload | Out-Null
$lines = @(Get-Content -LiteralPath $Log)
Assert-Match 'a [subagents.models] pin beats the default' $lines[-1] '"model":"small"'
Assert-NoMatch 'a trailing comment is not part of the model name' $lines[-1] 'recon'

# An agent file can pin its own model in frontmatter, as looker does with
# `model: vision`. Without that step an unpinned looker is recorded as having
# run on the default model, which measures the wrong machine.
New-Item -ItemType Directory -Force (Join-Path $HomeDir 'agents') | Out-Null
@'
---
name: looker
description: >
  Vision agent. This body mentions model: notthisone on purpose.
capabilityMode: read-only
model: vision
---
Body text, which also says model: definitelynotthisone.
'@ | Set-Content -LiteralPath (Join-Path $HomeDir 'agents\looker.md') -Encoding ascii

$lookerPayload = Join-Path $Work 'looker.json'
@'
{"hookEventName":"subagent_end","subagentType":"looker","exitCode":0,"durationMs":3000,"tokensUsed":9000,"toolCalls":0,"turns":1}
'@ | Set-Content -LiteralPath $lookerPayload -Encoding ascii
Invoke-Hook -AxonHome $HomeDir -PayloadFile $lookerPayload | Out-Null
$lines = @(Get-Content -LiteralPath $Log)
Assert-Match 'agent frontmatter beats [models] default' $lines[-1] '"model":"vision"'
Assert-NoMatch 'only the frontmatter is read, never the body' $lines[-1] 'notthisone'

# A pin still outranks frontmatter, which is Axon's own precedence.
$cfgPath = Join-Path $HomeDir 'config.toml'
$cfgSaved = Get-Content -LiteralPath $cfgPath -Raw
Add-Content -LiteralPath $cfgPath -Value 'looker = "small"'
Invoke-Hook -AxonHome $HomeDir -PayloadFile $lookerPayload | Out-Null
$lines = @(Get-Content -LiteralPath $Log)
Assert-Match 'a pin outranks agent frontmatter' $lines[-1] '"model":"small"'
Set-Content -LiteralPath $cfgPath -Value $cfgSaved -NoNewline -Encoding ascii

# --- the ledger Axon 0.3.6+ sends -------------------------------------------
Write-Host ''
Write-Host 'usageByModel'
# Two models in one subagent: the counts sum, and the attributed model is the one
# that generated the most rather than the first or last listed.
$ledgerPayload = Join-Path $Work 'ledger.json'
@'
{"hookEventName":"subagent_end","subagentType":"executor","exitCode":0,"durationMs":41000,"tokensUsed":31200,"toolCalls":6,"turns":9,"usageByModel":[{"model":"quiet","inputTokens":900,"outputTokens":40,"modelCalls":1,"apiDurationMs":300},{"model":"busy","inputTokens":30000,"outputTokens":1200,"modelCalls":9,"apiDurationMs":18000}]}
'@ | Set-Content -LiteralPath $ledgerPayload -Encoding ascii
Invoke-Hook -AxonHome $HomeDir -PayloadFile $ledgerPayload | Out-Null
$last = @(Get-Content -LiteralPath $Log)[-1]
Assert-Match 'the payload ledger wins over config attribution' $last '"model":"busy"'
Assert-Match 'attribution names its source' $last '"modelSource":"payload"'
Assert-Match 'input tokens are summed across models' $last '"inputTokens":30900'
Assert-Match 'output tokens are summed across models' $last '"outputTokens":1240'
Assert-Match 'model calls are summed' $last '"modelCalls":10'
Assert-Match 'API time is summed' $last '"apiDurationMs":18300'
Assert-Match 'the model count is recorded' $last '"modelCount":2'

# A payload with no ledger at all is every Axon before 0.3.6. The config
# fallback must still answer, and must say that it did.
$noLedger = Join-Path $Work 'noledger.json'
@'
{"hookEventName":"subagent_end","subagentType":"scout","exitCode":0,"durationMs":6100,"tokensUsed":6900,"toolCalls":0,"turns":1}
'@ | Set-Content -LiteralPath $noLedger -Encoding ascii
Invoke-Hook -AxonHome $HomeDir -PayloadFile $noLedger | Out-Null
$last = @(Get-Content -LiteralPath $Log)[-1]
Assert-Match 'no ledger falls back to config' $last '"modelSource":"config"'
Assert-Match 'no ledger still resolves a model' $last '"model":"small"'
Assert-Match 'no ledger records zero generated' $last '"outputTokens":0'
Assert-Match 'no ledger records no models' $last '"modelCount":0'

# A bill the child knows is short.
$shortBill = Join-Path $Work 'short.json'
@'
{"hookEventName":"subagent_end","subagentType":"reviewer","exitCode":0,"durationMs":900,"tokensUsed":5000,"toolCalls":0,"turns":1,"usageIncomplete":true,"usageByModel":[{"model":"big","inputTokens":4000,"outputTokens":400,"modelCalls":2,"apiDurationMs":8000}]}
'@ | Set-Content -LiteralPath $shortBill -Encoding ascii
Invoke-Hook -AxonHome $HomeDir -PayloadFile $shortBill | Out-Null
$last = @(Get-Content -LiteralPath $Log)[-1]
Assert-Match 'a short bill is recorded as such' $last '"usageIncomplete":true'

# --- a missing field stays null, and never becomes zero ----------------------
Write-Host ''
Write-Host 'absent fields'
$noStatus = Join-Path $Work 'nostatus.json'
@'
{"hookEventName":"subagent_end","subagentType":"reviewer","durationMs":100,"tokensUsed":500}
'@ | Set-Content -LiteralPath $noStatus -Encoding ascii
Invoke-Hook -AxonHome $HomeDir -PayloadFile $noStatus | Out-Null
$lines = @(Get-Content -LiteralPath $Log)
# Axon reports exitCode only for completed/failed/cancelled. A silent 0 here
# would read as success.
Assert-Match 'an absent exit code stays null' $lines[-1] '"exitCode":null'
Assert-Match 'an absent tool count stays null' $lines[-1] '"toolCalls":null'
Assert-NoMatch 'an absent field never becomes zero' $lines[-1] '"exitCode":0'

# --- a hostile error message cannot corrupt the log -------------------------
Write-Host ''
Write-Host 'error text'
# Quotes, a backslash and an escaped newline: written out verbatim this breaks
# the line for every reader that comes after it.
$badPayload = Join-Path $Work 'bad.json'
$badObj = [ordered]@{
    hookEventName = 'subagent_end'
    subagentType  = 'executor'
    exitCode      = 1
    durationMs    = 900
    tokensUsed    = 7000
    toolCalls     = 0
    turns         = 1
    error         = "boom: server said `"no`" \ then `nnewline"
}
($badObj | ConvertTo-Json -Compress) | Set-Content -LiteralPath $badPayload -Encoding ascii
Invoke-Hook -AxonHome $HomeDir -PayloadFile $badPayload | Out-Null
$lines = @(Get-Content -LiteralPath $Log)
Assert-Match 'the error is recorded' $lines[-1] 'boom: server said'
Assert-NoMatch 'no bare quote survives in the error' $lines[-1] 'said \\"no'

$bad = 0
foreach ($l in (Get-Content -LiteralPath $Log)) {
    if (-not $l.Trim()) { continue }
    try { $l | ConvertFrom-Json -ErrorAction Stop | Out-Null } catch { $bad++ }
}
Assert-Equal 'every line in the log is valid JSON' $bad 0

# --- the hook never disturbs the run ----------------------------------------
Write-Host ''
Write-Host 'the hook never fails a run'
$garbage = Join-Path $Work 'garbage.txt'
'this is not json at all' | Set-Content -LiteralPath $garbage -Encoding ascii
$prev = $env:AXON_HOME
$env:AXON_HOME = $HomeDir
$gOut = (Get-Content -LiteralPath $garbage -Raw |
    & pwsh -NoProfile -File (Join-Path $HomeDir 'hooks\bin\subagent-telemetry.ps1') 2>&1 | Out-String)
$gCode = $LASTEXITCODE
$env:AXON_HOME = $prev
Assert-Equal 'a garbage payload still exits 0' $gCode 0
Assert-Equal 'a garbage payload prints nothing' $gOut.Trim() ''

# With no config to read, the model is unknown rather than guessed.
$noCfg = Join-Path $Work 'nocfg'
New-Item -ItemType Directory -Force (Join-Path $noCfg 'hooks\bin') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $noCfg 'hooks\lib') | Out-Null
Copy-Item $HookSrc (Join-Path $noCfg 'hooks\bin\subagent-telemetry.ps1')
Copy-Item (Join-Path $RepoRoot 'tools\lib\Probe.ps1') (Join-Path $noCfg 'hooks\lib\Probe.ps1')
$nCode = Invoke-Hook -AxonHome $noCfg -PayloadFile $okPayload
Assert-Equal 'no config still exits 0' $nCode 0
# @() matters: Get-Content on a one-line file returns a string, and indexing a
# string yields its first character rather than its first line.
$nLine = @(Get-Content -LiteralPath (Join-Path $noCfg 'telemetry\subagents.jsonl'))[0]
Assert-Match 'no config means no model, not a guessed one' $nLine '"model":null'

$emptyPayload = Join-Path $Work 'empty.json'
Set-Content -LiteralPath $emptyPayload -Value '' -Encoding ascii
$eCode = Invoke-Hook -AxonHome $HomeDir -PayloadFile $emptyPayload
Assert-Equal 'an empty payload exits 0' $eCode 0

# --- the report --------------------------------------------------------------
Write-Host ''
Write-Host 'argument handling'
Invoke-Report @('-Help')
Assert-Equal '-Help exits 0' $Code 0
Assert-Match '-Help lists -Role' $Out '-Role'
Invoke-Report @('-Version')
Assert-Match '-Version prints a semver' $Out 'oh-my-axon \d+\.\d+\.\d+'
Invoke-Report @('-Log', (Join-Path $Work 'does-not-exist.jsonl'))
Assert-Equal 'a missing log exits 2' $Code 2
Assert-Match 'a missing log says how to get one' $Out '-WithTelemetry'

# --- what the report will and will not claim --------------------------------
Write-Host ''
Write-Host 'report findings'
$cfg = Join-Path $Work 'cfg.toml'
@'
[model.big]
model = "big-70b"
base_url = "http://127.0.0.1:1/v1"
context_window = 131072

[model.nowindow]
model = "nowindow-12b"
base_url = "http://127.0.0.1:2/v1"

[models]
default = "big"
'@ | Set-Content -LiteralPath $cfg -Encoding ascii

$fixLog = Join-Path $Work 'log.jsonl'
@'
{"ts":"2026-07-29T22:17:43Z","subagentType":"executor","model":"big","exitCode":0,"durationMs":41200,"tokensUsed":18400,"toolCalls":6,"turns":9,"error":""}
{"ts":"2026-07-29T22:18:43Z","subagentType":"executor","model":"big","exitCode":1,"durationMs":9000,"tokensUsed":7000,"toolCalls":0,"turns":1,"error":"connection refused"}
{"ts":"2026-07-29T22:19:43Z","subagentType":"crammed","model":"big","exitCode":0,"durationMs":60000,"tokensUsed":120000,"toolCalls":9,"turns":14,"error":""}
{"ts":"2026-07-29T22:20:43Z","subagentType":"guessy","model":"nowindow","exitCode":0,"durationMs":5000,"tokensUsed":190000,"toolCalls":1,"turns":2,"error":""}
{"ts":"2026-07-29T22:21:43Z","subagentType":"ghosted","model":"vanished","exitCode":0,"durationMs":5000,"tokensUsed":190000,"toolCalls":1,"turns":2,"error":""}
{"ts":"2026-07-29T22:22:43Z","subagentType":"unattributed","model":null,"exitCode":0,"durationMs":5000,"tokensUsed":20000,"toolCalls":1,"turns":2,"error":""}
{"ts":"2026-07-29T22:23:43Z","subagentType":"stopped","model":"big","exitCode":-1,"durationMs":2000,"tokensUsed":7000,"toolCalls":0,"turns":1,"error":""}
'@ | Set-Content -LiteralPath $fixLog -Encoding ascii

Invoke-Report @('-Log', $fixLog, '-Config', $cfg)
Assert-Equal 'a log with problems exits 1' $Code 1
Assert-Match 'the table lists a role' $Out 'executor .*big'
Assert-Match 'failures are counted and explained' $Out 'executor failed 1 of 2 run\(s\)\. Most recent error: connection refused'
Assert-Match 'a cancelled run is counted apart from a failure' $Out 'stopped .*0/0/1'

# The whole point of the tool: 120000 of a 131072 window is 92%, over the 85%
# at which Axon compacts, and the window came from the config, so this is a
# finding rather than a guess.
Assert-Match 'context pressure against a known window is a problem' $Out 'crammed peaked at 120\.0k of big'
Assert-Match 'the compaction threshold is named' $Out 'Axon compacts at 85%'

# The same pressure against a window nobody set is a note, not a finding.
Assert-Match 'pressure against an assumed window is only a note' $Out 'guessy peaked at 190\.0k, which would be'
Assert-NoMatch 'an assumed window never produces a compaction finding' $Out 'guessy peaked at 190\.0k of'

# A model absent from the catalog has no window at all, so no percentage.
Assert-Match 'a vanished model is called out' $Out 'ghosted ran on "vanished", which is not in your catalog'
Assert-Match 'a role with no attribution is reported' $Out '1 record\(s\) carry no model'

# Tokens per second must never be derived from tokensUsed. These records carry no
# ledger at all, so the column has to stay empty rather than fall back to it.
Assert-Match 'the table offers a TOK/S column' $Out 'TOK/S'
Assert-NoMatch 'no rate is invented without a ledger' $Out '\d+ +18\.4k'
Assert-Match 'a ledgerless role says why it has no rate' $Out 'no ledger \(Axon before 0\.3\.6\)'

# --- the rate itself --------------------------------------------------------
Write-Host ''
Write-Host 'throughput'
$rateLog = Join-Path $Work 'rate.jsonl'
@'
{"ts":"r1","subagentType":"fast","model":"big","modelSource":"payload","exitCode":0,"durationMs":9000,"tokensUsed":8000,"toolCalls":0,"turns":1,"inputTokens":7000,"outputTokens":600,"modelCalls":1,"apiDurationMs":6000,"modelCount":1,"usageIncomplete":false,"error":""}
{"ts":"r2","subagentType":"fast","model":"big","modelSource":"payload","exitCode":0,"durationMs":9000,"tokensUsed":8000,"toolCalls":0,"turns":1,"inputTokens":7000,"outputTokens":400,"modelCalls":1,"apiDurationMs":8000,"modelCount":1,"usageIncomplete":false,"error":""}
{"ts":"r3","subagentType":"tiny","model":"big","modelSource":"payload","exitCode":0,"durationMs":3400,"tokensUsed":6641,"toolCalls":0,"turns":1,"inputTokens":6638,"outputTokens":3,"modelCalls":1,"apiDurationMs":3319,"modelCount":1,"usageIncomplete":false,"error":""}
{"ts":"r4","subagentType":"shortbill","model":"big","modelSource":"payload","exitCode":0,"durationMs":9000,"tokensUsed":8000,"toolCalls":0,"turns":1,"inputTokens":4000,"outputTokens":400,"modelCalls":2,"apiDurationMs":8000,"modelCount":1,"usageIncomplete":true,"error":""}
{"ts":"r5","subagentType":"mixed","model":"a","modelSource":"payload","exitCode":0,"durationMs":9000,"tokensUsed":8000,"toolCalls":0,"turns":1,"inputTokens":7000,"outputTokens":600,"modelCalls":1,"apiDurationMs":6000,"modelCount":2,"usageIncomplete":false,"error":""}
{"ts":"r6","subagentType":"mixed","model":"b","modelSource":"payload","exitCode":0,"durationMs":9000,"tokensUsed":8000,"toolCalls":0,"turns":1,"inputTokens":7000,"outputTokens":600,"modelCalls":1,"apiDurationMs":6000,"modelCount":2,"usageIncomplete":false,"error":""}
'@ | Set-Content -LiteralPath $rateLog -Encoding ascii

Invoke-Report @('-Log', $rateLog, '-Config', $cfg)
# 600/6000ms = 100/s and 400/8000ms = 50/s; the median of the two is 75.
Assert-Match 'the rate is the median of per-run rates' $Out 'fast .* 75 '
# 3 tokens over 3.3s is prefill wearing a throughput costume.
Assert-Match 'a tiny generation yields no rate' $Out 'tiny .* - '
Assert-Match 'and the exclusion is explained' $Out 'tiny has no TOK/S -- every run was excluded; 1 had too little generation to time'
# A short bill under-counts the numerator, so the rate would read low.
Assert-Match 'a short bill is excluded from the rate' $Out 'shortbill has no TOK/S -- every run was excluded; 1 reported a short bill'
Assert-Match 'and its totals are called a floor' $Out 'shortbill reported an incomplete bill'
# Two models under one role: a rate is still shown, but not as one model's speed.
Assert-Match 'a mixed-model role warns about its rate' $Out 'mixed mixes 2 models, so its TOK/S is a median across different machines'
# The forbidden number: nothing may divide tokensUsed by a duration.
Assert-NoMatch 'tokensUsed is never used as a rate numerator' $Out 'fast .* (888|889|1333) '

Write-Host ''
Write-Host 'filtering and quiet'
Invoke-Report @('-Log', $fixLog, '-Config', $cfg, '-Role', 'stopped')
Assert-Equal 'a clean role exits 0' $Code 0
Assert-Match 'a clean role says so' $Out 'No problems found'
Assert-NoMatch 'a role filter excludes other roles' $Out 'crammed'
Invoke-Report @('-Log', $fixLog, '-Config', $cfg, '-Role', 'nosuchrole')
Assert-Equal 'an unknown role exits 1' $Code 1
Assert-Match 'an unknown role is explained' $Out 'no records for role "nosuchrole"'
Invoke-Report @('-Log', $fixLog, '-Config', $cfg, '-Quiet')
Assert-NoMatch '-Quiet prints no table' $Out 'OF WINDOW'
Assert-Match '-Quiet still prints problems' $Out 'connection refused'

# A log with no usable config still reports what it measured, and simply has
# no window to compare against.
Invoke-Report @('-Log', $fixLog, '-Config', (Join-Path $Work 'does-not-exist.toml'))
Assert-Match 'a missing config does not stop the report' $Out 'executor'
Assert-NoMatch 'a missing config invents no percentage' $Out '9\d%'

# --- overflow files are read back -------------------------------------------
Write-Host ''
Write-Host 'overflow'
$ov = Join-Path $Work 'ov'
New-Item -ItemType Directory -Force $ov | Out-Null
Copy-Item $fixLog (Join-Path $ov 'subagents.jsonl')
@'
{"ts":"2026-07-29T22:24:43Z","subagentType":"raced","model":"big","exitCode":0,"durationMs":1000,"tokensUsed":8000,"toolCalls":0,"turns":1,"error":""}
'@ | Set-Content -LiteralPath (Join-Path $ov 'subagents-overflow-1234.jsonl') -Encoding ascii
Invoke-Report @('-Log', (Join-Path $ov 'subagents.jsonl'), '-Config', $cfg)
Assert-Match 'a record in an overflow file is not lost' $Out 'raced'
Assert-Match 'the overflow record is counted once' $Out 'raced .* 1 '

# Pointing -Log straight at an overflow file must not read it twice, or every
# number in the report doubles.
Invoke-Report @('-Log', (Join-Path $ov 'subagents-overflow-1234.jsonl'), '-Config', $cfg)
Assert-Match 'an overflow file named directly is read once' $Out '1 run\(s\) across 1 role'

# --- the report writes nothing ----------------------------------------------
Write-Host ''
Write-Host 'side effects'
$before = (Get-FileHash $fixLog).Hash
Invoke-Report @('-Log', $fixLog, '-Config', $cfg)
Assert-Equal 'the report does not modify the log it reads' (Get-FileHash $fixLog).Hash $before

Remove-Item -Recurse -Force $Work
if (Write-Summary 'subagents: all checks passed') { exit 0 } else { exit 1 }
