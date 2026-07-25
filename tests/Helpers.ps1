# Shared helpers for the oh-my-axon smoke tests (Windows).
# Dot-sourced, never executed directly.

$script:Checks = 0
$script:Failures = 0

function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    $script:Checks++
    if ($Condition) {
        Write-Host "  ok   $Name"
    } else {
        $script:Failures++
        Write-Host "  FAIL $Name"
        if ($Detail) { Write-Host "       $Detail" }
    }
}

function Assert-Equal {
    param([string]$Name, $Actual, $Expected)
    Assert-That $Name ($Actual -eq $Expected) "expected [$Expected], got [$Actual]"
}

function Assert-Match {
    param([string]$Name, [string]$Haystack, [string]$Pattern)
    Assert-That $Name ($Haystack -match $Pattern) "[$Haystack] does not match /$Pattern/"
}

function Assert-NoMatch {
    param([string]$Name, [string]$Haystack, [string]$Pattern)
    Assert-That $Name (-not ($Haystack -match $Pattern)) "[$Haystack] unexpectedly matches /$Pattern/"
}

function Assert-File {
    param([string]$Name, [string]$Path)
    Assert-That $Name (Test-Path $Path -PathType Leaf) "missing file: $Path"
}

function Assert-Absent {
    param([string]$Name, [string]$Path)
    Assert-That $Name (-not (Test-Path $Path)) "should not exist: $Path"
}

function New-TempDir {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name)
    $p = Join-Path ([System.IO.Path]::GetTempPath()) "oma-smoke-$Name-$PID"
    if ($PSCmdlet.ShouldProcess($p, 'create scratch directory')) {
        if (Test-Path $p) { Remove-Item -Recurse -Force $p }
        New-Item -ItemType Directory -Force $p | Out-Null
    }
    return $p
}

# Print the tally and return $true when everything passed.
function Write-Summary {
    param([string]$PassMessage)
    Write-Host ''
    Write-Host "$($script:Checks) checks, $($script:Failures) failed"
    if ($script:Failures -gt 0) { return $false }
    Write-Host $PassMessage
    return $true
}
