# oh-my-axon installer (Windows).
#
#   .\install.ps1              install into $env:AXON_HOME (default ~\.axon)
#   .\install.ps1 -DryRun      print what an install writes, and write nothing
#   .\install.ps1 -Uninstall   remove exactly what a previous install put there
#   .\install.ps1 -Help        list every flag
#
# The installer only ever writes files listed in its manifest and backs up
# anything it would overwrite. It never touches config.toml.
#
# PowerShell's parameter binder rejects an unknown flag before this script
# runs, so a typo cannot fall through to a real install. install.sh has to
# refuse unknown arguments by hand to reach the same behaviour.
[CmdletBinding()]
param([switch]$Uninstall, [switch]$DryRun, [switch]$WithFormatHook,
      [switch]$Version, [switch]$Help)

$ErrorActionPreference = 'Stop'
$OmaVersion = '0.1.3'

# Failures go straight to stderr rather than through Write-Error, which
# reflows a multi-line message to the console width. See tools/gen-roles.ps1.
function Write-Fail {
    param([string[]]$Line)
    foreach ($l in $Line) { [Console]::Error.WriteLine($l) }
}

if ($Version) { Write-Host "oh-my-axon $OmaVersion"; exit 0 }
if ($Help) {
    Write-Host @'
oh-my-axon installer.

  .\install.ps1                    install into ~\.axon
  .\install.ps1 -WithFormatHook    also install the opt-in format-on-edit hook
  .\install.ps1 -DryRun            show what an install does, write nothing
  .\install.ps1 -Uninstall         remove the files listed in the manifest
  .\install.ps1 -Version           print the version
  .\install.ps1 -Help              print this text

Set AXON_HOME to install somewhere other than ~\.axon.
'@
    exit 0
}
$SrcDir = $PSScriptRoot
$AxonHome = if ($env:AXON_HOME) { $env:AXON_HOME } else { Join-Path $HOME '.axon' }
$Manifest = Join-Path $AxonHome '.oh-my-axon-manifest'

if ($Uninstall) {
    if (-not (Test-Path $Manifest)) {
        Write-Host "oh-my-axon: no manifest at $Manifest. There is nothing to uninstall."
        exit 0
    }
    Get-Content $Manifest | Select-Object -Skip 1 | Where-Object { $_ } | ForEach-Object {
        $f = Join-Path $AxonHome $_
        if (Test-Path $f) { Remove-Item -Force $f }
    }
    Remove-Item -Force $Manifest
    # Children before parents: a directory is only removed when it is empty,
    # so skills\* has to go before skills itself gets a chance.
    foreach ($d in 'skills\ultrawork', 'skills\plan', 'skills\handoff', 'skills\audit', 'skills', 'hooks\bin', 'hooks', 'agents', 'personas') {
        $p = Join-Path $AxonHome $d
        if ((Test-Path $p) -and -not (Get-ChildItem $p)) { Remove-Item $p }
    }
    Write-Host "oh-my-axon: removed from $AxonHome."
    exit 0
}

$HomeSrc = Join-Path $SrcDir 'home'
if (-not (Test-Path $HomeSrc)) {
    Write-Fail @(
        "oh-my-axon: cannot find $HomeSrc.",
        "  Run this script from a checkout of the repository."
    )
    exit 1
}

# -DryRun: report what an install would do, then exit without writing
# anything — no copies, no manifest, no backup dir.
if ($DryRun) {
    Write-Host "oh-my-axon $OmaVersion dry run. This writes nothing to $AxonHome."
    Get-ChildItem $HomeSrc -Recurse -File | Where-Object {
        $_.Name -ne 'secret-scan.json' -and
        $_.Name -ne 'format-on-edit.json' -and
        $_.Name -ne 'format-on-edit.sh' -and
        $_.Name -ne 'format-on-edit.ps1'
    } | ForEach-Object {
        $rel = $_.FullName.Substring($HomeSrc.Length + 1) -replace '\\', '/'
        Write-Host "  would install: $rel"
        $dest = Join-Path $AxonHome ($rel -replace '/', '\')
        if ((Test-Path $dest) -and
            ((Get-FileHash $dest).Hash -ne (Get-FileHash $_.FullName).Hash)) {
            Write-Host "  would back up: $rel"
        }
    }
    Write-Host "  would install: hooks/secret-scan.json (templated for this platform)"
    if ($WithFormatHook) {
        Write-Host "  would install: hooks/format-on-edit.json (templated for this platform)"
        Write-Host "  would install: hooks/bin/format-on-edit.sh"
        Write-Host "  would install: hooks/bin/format-on-edit.ps1"
    }
    Write-Host "  would write:   .oh-my-axon-manifest"
    exit 0
}

$BackupDir = Join-Path $AxonHome ("oh-my-axon-backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$backedUp = $false
$installed = @()

function Install-OmaFile([string]$Source, [string]$Rel) {
    $dest = Join-Path $AxonHome $Rel
    $destDir = Split-Path $dest -Parent
    New-Item -ItemType Directory -Force $destDir | Out-Null
    if ((Test-Path $dest) -and
        ((Get-FileHash $dest).Hash -ne (Get-FileHash $Source).Hash)) {
        $bak = Join-Path $script:BackupDir $Rel
        New-Item -ItemType Directory -Force (Split-Path $bak -Parent) | Out-Null
        Copy-Item $dest $bak
        $script:backedUp = $true
    }
    Copy-Item $Source $dest -Force
    $script:installed += $Rel
}

# 1. Everything under home\, except the hook descriptors (templated below).
Get-ChildItem $HomeSrc -Recurse -File | Where-Object {
    $_.Name -ne 'secret-scan.json' -and
    $_.Name -ne 'format-on-edit.json' -and
    $_.Name -ne 'format-on-edit.sh' -and
    $_.Name -ne 'format-on-edit.ps1'
} | ForEach-Object {
    $rel = $_.FullName.Substring($HomeSrc.Length + 1)
    Install-OmaFile $_.FullName $rel
}

# 2. Hook descriptor: a command *string* runs via the shell with cwd at the
#    workspace root, so it must carry an absolute path to the script.
#    Forward slashes keep the JSON free of escaping headaches.
$scriptPath = (Join-Path $AxonHome 'hooks\bin\secret-scan.ps1') -replace '\\', '/'
$cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
$jsonSrc = Join-Path $HomeSrc 'hooks\secret-scan.json'
$hookDest = Join-Path $AxonHome 'hooks\secret-scan.json'
New-Item -ItemType Directory -Force (Split-Path $hookDest -Parent) | Out-Null
(Get-Content $jsonSrc -Raw) -replace '__OMA_SECRET_SCAN_CMD__', ($cmd -replace '"', '\"') |
    Set-Content -NoNewline $hookDest
$installed += 'hooks\secret-scan.json'

if ($WithFormatHook) {
    # 2b. Format-on-edit hook descriptor: same pattern as secret-scan, but
    #      the command is an absolute path because it runs from workspace root.
    $scriptPathFmt = (Join-Path $AxonHome 'hooks\bin\format-on-edit.ps1') -replace '\\', '/'
    $cmdFmt = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptPathFmt`""
    $jsonSrcFmt = Join-Path $HomeSrc 'hooks\format-on-edit.json'
    $hookDestFmt = Join-Path $AxonHome 'hooks\format-on-edit.json'
    New-Item -ItemType Directory -Force (Split-Path $hookDestFmt -Parent) | Out-Null
    (Get-Content $jsonSrcFmt -Raw) -replace '__OMA_FORMAT_CMD__', ($cmdFmt -replace '"', '\"') |
        Set-Content -NoNewline $hookDestFmt
    $installed += 'hooks\format-on-edit.json'
    Install-OmaFile (Join-Path $HomeSrc 'hooks\bin\format-on-edit.sh') 'hooks\bin\format-on-edit.sh'
    Install-OmaFile (Join-Path $HomeSrc 'hooks\bin\format-on-edit.ps1') 'hooks\bin\format-on-edit.ps1'
}

# 3. Manifest for clean uninstall (relative paths, forward slashes).
$lines = @("oh-my-axon $OmaVersion") + ($installed | ForEach-Object { $_ -replace '\\', '/' } | Sort-Object -Unique)
Set-Content -Path $Manifest -Value $lines

Write-Host "oh-my-axon $OmaVersion installed into $AxonHome"
if ($backedUp) { Write-Host "  oh-my-axon backed up the files that differ to $BackupDir." }
Write-Host @'

Next steps:
  1. Run `axon` once. The first-run wizard finds your local servers
     (LM Studio, Ollama, llama.cpp, vLLM). To configure them by hand, see
     config/config.toml.snippet.
  2. Run /ultrawork <task> to explore, plan, implement, and verify in one pass.
     Run /plan <task> to plan only. Axon writes the plan to .axon/plans/.
  3. The agents are in ~/.axon/agents: scout, architect, executor, reviewer,
     and looker. The personas are in ~/.axon/personas: concise and thorough.
     Use both from the task tool in any session.

To remove oh-my-axon, run:  .\install.ps1 -Uninstall
'@
