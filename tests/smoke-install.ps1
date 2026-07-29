# oh-my-axon installer smoke test (Windows).
#
#   pwsh -File tests/smoke-install.ps1
#
# Drives install.ps1 through its full lifecycle against a throwaway AXON_HOME:
# dry run writes nothing, install lands the manifest and templates the hook,
# re-install backs up what it replaces, uninstall leaves no residue.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
$Installer = Join-Path $RepoRoot 'install.ps1'

. (Join-Path $PSScriptRoot 'Helpers.ps1')

$Scratch = New-TempDir 'install'
$AxonHome = Join-Path $Scratch 'axon-home'

# Belt and braces: this test installs and then deletes files, so make certain
# it can never be pointed at a real Axon home.
$realHome = Join-Path $HOME '.axon'
if ($AxonHome -eq $realHome -or $AxonHome.StartsWith($realHome, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Error "refusing to run against the real AXON_HOME: $AxonHome"
}
$env:AXON_HOME = $AxonHome

$Manifest = Join-Path $AxonHome '.oh-my-axon-manifest'
$PsExe = if (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }

# Run the installer in a child process so its `exit` does not kill this suite.
# Returns @{ Out; Code }.
function Invoke-Installer {
    $out = (& $PsExe -NoProfile -ExecutionPolicy Bypass -File $Installer @args 2>&1 | Out-String).Trim()
    return @{ Out = $out; Code = $LASTEXITCODE }
}

function Get-ManifestEntry {
    return @(Get-Content $Manifest | Select-Object -Skip 1 | Where-Object { $_ })
}

Write-Host 'oh-my-axon installer smoke test'
Write-Host "  AXON_HOME=$AxonHome"

# ------------------------------------------------------------- argument gate
# The Windows half gets this from PowerShell's parameter binder, which refuses
# an unrecognised flag before the script body runs. install.sh has to do it by
# hand. The exit codes differ on purpose: the binder decides this one, so the
# assertion is "non-zero and wrote nothing", not a shared number.
Write-Host "`nargument handling"
$r = Invoke-Installer -DryRunn
Assert-That 'unknown flag is refused' ($r.Code -ne 0) "expected non-zero, got $($r.Code)"
Assert-Match 'unknown flag names itself' $r.Out 'DryRunn'
Assert-Absent 'a typo installs nothing' $AxonHome

$r = Invoke-Installer -Version
Assert-Equal '-Version exits 0' $r.Code 0
Assert-Match '-Version prints a semver' $r.Out 'oh-my-axon \d+\.\d+\.\d+'
Assert-Absent '-Version installs nothing' $AxonHome

$r = Invoke-Installer -Help
Assert-Equal '-Help exits 0' $r.Code 0
Assert-Match '-Help lists the uninstall flag' $r.Out '-Uninstall'
Assert-Absent '-Help installs nothing' $AxonHome

# ------------------------------------------------------------------ dry run
Write-Host "`ndry run writes nothing"
$r = Invoke-Installer -DryRun
Assert-Equal 'dry run exits 0' $r.Code 0
Assert-Match 'dry run lists an agent' $r.Out 'would install: agents/scout\.md'
Assert-Match 'dry run lists the manifest' $r.Out 'would write:.*oh-my-axon-manifest'
Assert-NoMatch 'dry run omits the opt-in format hook' $r.Out 'format-on-edit'
Assert-Absent 'dry run created no AXON_HOME' $AxonHome

# ------------------------------------------------------------------ install
Write-Host "`ndefault install"
$r = Invoke-Installer
Assert-Equal 'install exits 0' $r.Code 0
Assert-File 'agent installed' (Join-Path $AxonHome 'agents\scout.md')
Assert-File 'looker installed' (Join-Path $AxonHome 'agents\looker.md')
Assert-File 'persona installed' (Join-Path $AxonHome 'personas\concise.toml')
Assert-File 'skill installed' (Join-Path $AxonHome 'skills\ultrawork\SKILL.md')
Assert-File 'audit skill installed' (Join-Path $AxonHome 'skills\audit\SKILL.md')
Assert-File 'hook script installed' (Join-Path $AxonHome 'hooks\bin\secret-scan.ps1')
Assert-File 'hook descriptor installed' (Join-Path $AxonHome 'hooks\secret-scan.json')
Assert-File 'manifest written' $Manifest

# The format hook is opt-in; a default install must not land any part of it.
Assert-Absent 'format hook descriptor not installed' (Join-Path $AxonHome 'hooks\format-on-edit.json')
Assert-Absent 'format hook script not installed' (Join-Path $AxonHome 'hooks\bin\format-on-edit.ps1')

# config.toml is the user's own file and must never be touched.
Assert-Absent 'config.toml untouched' (Join-Path $AxonHome 'config.toml')

$hookJson = Get-Content (Join-Path $AxonHome 'hooks\secret-scan.json') -Raw
Assert-NoMatch 'hook template placeholder substituted' $hookJson '__OMA_'
Assert-Match 'hook points at the Windows script' $hookJson 'secret-scan\.ps1'

# The templated command carries an absolute path, because a hook command
# string runs with cwd at the workspace root, not at the descriptor. Verify
# that path actually resolves -- a wrong one fails silently at runtime.
$hookObj = $hookJson | ConvertFrom-Json
$cmd = $hookObj.hooks.PreToolUse[0].hooks[0].command
Assert-Match 'hook command invokes powershell' $cmd 'powershell'
if ($cmd -match '-File\s+"([^"]+)"') {
    Assert-File 'hook command path resolves' $Matches[1]
} else {
    Assert-That 'hook command path resolves' $false "could not parse -File out of: $cmd"
}

Assert-Match 'manifest header carries a version' (Get-Content $Manifest -First 1) '^oh-my-axon \d+\.\d+\.\d+$'

# Every path the manifest claims to have installed must actually be there,
# or uninstall silently leaves files behind.
$missing = @(Get-ManifestEntry | Where-Object { -not (Test-Path (Join-Path $AxonHome $_) -PathType Leaf) })
Assert-Equal 'every manifest entry exists on disk' ($missing -join ' ') ''

$manifestCopy = Get-ManifestEntry

# ----------------------------------------------------------- backup on retry
Write-Host "`nre-install backs up what it replaces"
Add-Content (Join-Path $AxonHome 'agents\scout.md') '# locally modified'
$r = Invoke-Installer
Assert-Equal 're-install exits 0' $r.Code 0
Assert-Match 're-install reports a backup' $r.Out 'backed up the files that differ'
$backup = @(Get-ChildItem $AxonHome -Recurse -Filter 'scout.md' -File |
    Where-Object { $_.FullName -match 'oh-my-axon-backup-' })
if ($backup.Count -gt 0) {
    Assert-That 'modified file was backed up' $true
    Assert-Match 'backup holds the modified content' (Get-Content $backup[0].FullName -Raw) 'locally modified'
} else {
    Assert-That 'modified file was backed up' $false 'no backup copy of agents\scout.md found'
}
Assert-NoMatch 'installed file was restored from source' `
    (Get-Content (Join-Path $AxonHome 'agents\scout.md') -Raw) 'locally modified'

# ---------------------------------------------------------------- uninstall
Write-Host "`nuninstall leaves no residue"
$r = Invoke-Installer -Uninstall
Assert-Equal 'uninstall exits 0' $r.Code 0
Assert-Absent 'manifest removed' $Manifest
Assert-Absent 'agents dir removed' (Join-Path $AxonHome 'agents')
Assert-Absent 'personas dir removed' (Join-Path $AxonHome 'personas')
Assert-Absent 'hooks dir removed' (Join-Path $AxonHome 'hooks')
Assert-Absent 'skills dir removed' (Join-Path $AxonHome 'skills')

$leftover = @($manifestCopy | Where-Object { Test-Path (Join-Path $AxonHome $_) })
Assert-Equal 'no manifest entry survives uninstall' ($leftover -join ' ') ''

# Anything at all left under AXON_HOME (other than backup dirs, which are
# deliberately preserved) means uninstall is not clean.
$residue = @(Get-ChildItem $AxonHome -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch 'oh-my-axon-backup-' } |
    ForEach-Object { $_.FullName.Substring($AxonHome.Length + 1) })
Assert-Equal 'nothing but backups left under AXON_HOME' ($residue -join ' ') ''

$r = Invoke-Installer -Uninstall
Assert-Equal 'uninstall is idempotent' $r.Code 0
Assert-Match 'second uninstall says so' $r.Out 'nothing to uninstall'

# ------------------------------------------------------- opt-in format hook
Write-Host "`ninstall -WithFormatHook"
Remove-Item -Recurse -Force $AxonHome -ErrorAction SilentlyContinue
$r = Invoke-Installer -WithFormatHook
Assert-Equal 'install exits 0' $r.Code 0
Assert-File 'format hook descriptor installed' (Join-Path $AxonHome 'hooks\format-on-edit.json')
Assert-File 'format hook ps1 installed' (Join-Path $AxonHome 'hooks\bin\format-on-edit.ps1')
Assert-File 'format hook sh installed' (Join-Path $AxonHome 'hooks\bin\format-on-edit.sh')

$fmtJson = Get-Content (Join-Path $AxonHome 'hooks\format-on-edit.json') -Raw
Assert-NoMatch 'format hook placeholder substituted' $fmtJson '__OMA_'
Assert-Match 'format hook points at the Windows script' $fmtJson 'format-on-edit\.ps1'

$missing = @(Get-ManifestEntry | Where-Object { -not (Test-Path (Join-Path $AxonHome $_) -PathType Leaf) })
Assert-Equal 'format-hook manifest is accurate' ($missing -join ' ') ''

$r = Invoke-Installer -Uninstall
Assert-Equal 'uninstall after format-hook install exits 0' $r.Code 0
Assert-Absent 'format hook descriptor removed' (Join-Path $AxonHome 'hooks\format-on-edit.json')

# ---------------------------------------------------- opt-in telemetry hook
Write-Host "`ninstall -WithTelemetry"
Remove-Item -Recurse -Force $AxonHome -ErrorAction SilentlyContinue
$r = Invoke-Installer
Assert-Absent 'telemetry hook is not installed by default' (Join-Path $AxonHome 'hooks\subagent-telemetry.json')
Assert-Absent 'the shared parser is not installed by default' (Join-Path $AxonHome 'hooks\lib\Probe.ps1')

Remove-Item -Recurse -Force $AxonHome -ErrorAction SilentlyContinue
$r = Invoke-Installer -WithTelemetry
Assert-Equal 'install exits 0' $r.Code 0
Assert-File 'telemetry descriptor installed' (Join-Path $AxonHome 'hooks\subagent-telemetry.json')
Assert-File 'telemetry ps1 installed' (Join-Path $AxonHome 'hooks\bin\subagent-telemetry.ps1')
Assert-File 'telemetry sh installed' (Join-Path $AxonHome 'hooks\bin\subagent-telemetry.sh')
# The hook resolves each role's model through the shared parser, so the parser
# has to travel with it. Without this the model field silently becomes null.
Assert-File 'the Windows parser travels with the hook' (Join-Path $AxonHome 'hooks\lib\Probe.ps1')
Assert-File 'the POSIX parser travels with the hook' (Join-Path $AxonHome 'hooks\lib\probe.sh')

$telJson = Get-Content (Join-Path $AxonHome 'hooks\subagent-telemetry.json') -Raw
Assert-NoMatch 'telemetry placeholder substituted' $telJson '__OMA_'
Assert-Match 'telemetry hook points at the Windows script' $telJson 'subagent-telemetry\.ps1'
# Registered under the canonical event name. Before Axon 0.3.5 the documented
# alias SubagentEnd landed in a bucket nothing fired, and ran zero times.
Assert-Match 'telemetry hook registers SubagentStop' $telJson '"SubagentStop"'

$missing = @(Get-ManifestEntry | Where-Object { -not (Test-Path (Join-Path $AxonHome $_) -PathType Leaf) })
Assert-Equal 'telemetry manifest is accurate' ($missing -join ' ') ''

# Measurements already recorded are the user's, so uninstall must not take them.
New-Item -ItemType Directory -Force (Join-Path $AxonHome 'telemetry') | Out-Null
'{"ts":"t","subagentType":"scout"}' |
    Set-Content -LiteralPath (Join-Path $AxonHome 'telemetry\subagents.jsonl') -Encoding ascii
$r = Invoke-Installer -Uninstall
Assert-Equal 'uninstall after telemetry install exits 0' $r.Code 0
Assert-Absent 'telemetry descriptor removed' (Join-Path $AxonHome 'hooks\subagent-telemetry.json')
Assert-Absent 'the shared parser is removed' (Join-Path $AxonHome 'hooks\lib\Probe.ps1')
Assert-File 'uninstall leaves the recorded log alone' (Join-Path $AxonHome 'telemetry\subagents.jsonl')
Assert-Match 'uninstall says where the log is' $r.Out 'telemetry log is still at'

# ------------------------------------------------------------------ summary
$ok = Write-Summary 'installer smoke test passed'
Remove-Item -Recurse -Force $Scratch -ErrorAction SilentlyContinue
if ($ok) { exit 0 } else { exit 1 }
