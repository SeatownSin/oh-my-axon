# oh-my-axon subagent telemetry (SubagentStop), Windows variant.
#
# Appends one JSON line per finished subagent to
# $AXON_HOME\telemetry\subagents.jsonl, which tools\subagents.ps1 reads back.
# Nothing leaves this machine, and nothing here is ever sent anywhere.
#
# Never blocks, never complains, always exits 0: a hook that fails loudly at
# the end of a subagent turns a successful run into a confusing one, and a
# telemetry hook has no business doing that.
#
# The prompt text is deliberately NOT recorded. The payload carries the
# subagent's `description`, which is free text derived from what you asked
# for; keeping it out means this log holds measurements, never content.

$payload = [Console]::In.ReadToEnd()
if (-not $payload) { exit 0 }

$axonHome = if ($env:AXON_HOME) { $env:AXON_HOME } else { Join-Path $HOME '.axon' }
$outDir = Join-Path $axonHome 'telemetry'
$out = Join-Path $outDir 'subagents.jsonl'

try {
    $obj = $payload | ConvertFrom-Json -ErrorAction Stop
} catch {
    # An unparseable payload is nothing to report and nothing to complain about.
    exit 0
}

# A missing number stays null rather than becoming 0. `exitCode` is absent for
# any status Axon does not map to completed/failed/cancelled, and a silent 0
# there would read as success.
function Format-Number {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    return [string][long]$Value
}

# Quotes, backslashes and newlines are stripped rather than escaped, so every
# path produces valid JSON: a mangled message is a lesser fault than a log file
# no reader can parse. Matches the sh variant's treatment exactly.
function Format-Text {
    param($Value)
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    $s = $s -replace '[\r\n\t]', ' '
    $s = $s -replace '["\\]', ''
    if ($s.Length -gt 200) { $s = $s.Substring(0, 200) }
    return $s
}

$type = Format-Text $obj.subagentType
if (-not $type) { $type = 'unknown' }

# The child's own billing ledger, one entry per model it called (Axon 0.3.6+).
# Counts are summed, and the attributed model is whichever entry generated the
# most, since that is the one that did the work.
function ConvertTo-Long {
    param($Value)
    if ($null -eq $Value) { return 0L }
    return [long]$Value
}

$uIn = 0L; $uOut = 0L; $uCalls = 0L; $uApi = 0L; $uCount = 0
$uModel = ''
$bestOut = -1L
foreach ($entry in @($obj.usageByModel)) {
    if ($null -eq $entry -or -not $entry.model) { continue }
    $uCount++
    $o = ConvertTo-Long $entry.outputTokens
    $uIn += ConvertTo-Long $entry.inputTokens
    $uOut += $o
    $uCalls += ConvertTo-Long $entry.modelCalls
    $uApi += ConvertTo-Long $entry.apiDurationMs
    if ($o -gt $bestOut) { $bestOut = $o; $uModel = Format-Text $entry.model }
}

# A bill the child knows is short. Recorded so the reporter can call its totals a
# floor instead of a measurement.
$incomplete = if ($obj.usageIncomplete) { 'true' } else { 'false' }

# Which model this role ran on. The payload's ledger wins outright when present:
# it says what the child ACTUALLY called, where the config only says what it
# should have. Resolving from config remains the fallback for Axon before 0.3.6,
# and `modelSource` records which one answered so a reader is never left guessing
# whether a name is authoritative.
#
# Resolved from AXON_HOME rather than from the script's own location, matching
# the sh variant: the installed hook command is a path relative to the
# descriptor, and this runs with cwd at the workspace root.
$modelJson = 'null'
$modelSrcJson = 'null'
if ($uModel) {
    $modelJson = '"' + $uModel + '"'
    $modelSrcJson = '"payload"'
} else {
    $lib = Join-Path $axonHome 'hooks\lib\Probe.ps1'
    $configPath = Join-Path $axonHome 'config.toml'
    if ((Test-Path -LiteralPath $lib -PathType Leaf) -and
        (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        try {
            . $lib
            # The agents directory is passed too, because a [subagents.models] pin
            # is not the only way a role gets a model: an agent file can pin one in
            # its own frontmatter, as looker does with `model: vision`. Project
            # agents shadow the installed ones, and cwd is the workspace root, so
            # that directory wins -- an agent further up the tree is not followed.
            $agentsDir = Join-Path $axonHome 'agents'
            $projectAgent = Join-Path '.axon\agents' "$type.md"
            if (Test-Path -LiteralPath $projectAgent -PathType Leaf) { $agentsDir = '.axon\agents' }
            $model = Format-Text (Get-RoleModel -Path $configPath -Role $type -AgentsDir $agentsDir)
            if ($model) {
                $modelJson = '"' + $model + '"'
                $modelSrcJson = '"config"'
            }
        } catch {
            # No model attribution is a gap in the record, not a reason to lose it.
            $modelJson = 'null'
            $modelSrcJson = 'null'
        }
    }
}

$line = '{{"ts":"{0}","subagentType":"{1}","model":{2},"modelSource":{3},' +
        '"exitCode":{4},"durationMs":{5},"tokensUsed":{6},"toolCalls":{7},"turns":{8},' +
        '"inputTokens":{9},"outputTokens":{10},"modelCalls":{11},"apiDurationMs":{12},' +
        '"modelCount":{13},"usageIncomplete":{14},"error":"{15}"}}'
$record = ($line -f
    (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'),
    $type,
    $modelJson,
    $modelSrcJson,
    (Format-Number $obj.exitCode),
    (Format-Number $obj.durationMs),
    (Format-Number $obj.tokensUsed),
    (Format-Number $obj.toolCalls),
    (Format-Number $obj.turns),
    $uIn,
    $uOut,
    $uCalls,
    $uApi,
    $uCount,
    $incomplete,
    (Format-Text $obj.error)) + "`n"

try { New-Item -ItemType Directory -Force $outDir | Out-Null } catch { exit 0 }

# UTF8Encoding($false), never `-Encoding utf8`: PowerShell 5.1 writes a byte
# order mark, and a BOM in the middle of a JSONL file is a line no parser reads.
$enc = New-Object System.Text.UTF8Encoding($false)

# Subagents that finish together are separate processes appending to one file.
# On Windows that is a share violation rather than an interleave, so retry
# briefly; a record that still cannot land goes to its own file instead of being
# dropped, and the reporter reads those too.
$wrote = $false
for ($i = 0; $i -lt 12; $i++) {
    try {
        [System.IO.File]::AppendAllText($out, $record, $enc)
        $wrote = $true
        break
    } catch {
        Start-Sleep -Milliseconds 25
    }
}
if (-not $wrote) {
    try {
        $overflow = Join-Path $outDir ("subagents-overflow-{0}.jsonl" -f $PID)
        [System.IO.File]::AppendAllText($overflow, $record, $enc)
    } catch {
        # Out of options. Losing one measurement is acceptable; disturbing the
        # run to report it is not, so this goes to the debug stream, which is
        # silent unless somebody asked for it.
        Write-Debug "subagent-telemetry: could not append a record: $_"
    }
}

exit 0
