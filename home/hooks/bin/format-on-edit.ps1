# oh-my-axon format-on-edit gate (PostToolUse), Windows variant.
# Reads the hook payload from stdin, extracts the edited file path,
# detects the project formatter (rustfmt / prettier / black) by config
# file, and runs it on that file only. Never blocks an edit — always
# exits 0.

$payload = [Console]::In.ReadToEnd()

# Extract the edited file path from the payload JSON.
function Get-EditedPath {
    param([string]$Payload)
    try {
        $obj = $Payload | ConvertFrom-Json -ErrorAction Stop
        # The tool payload nests its arguments under tool_input; check there
        # first, then fall back to top-level keys.
        foreach ($src in @($obj.tool_input, $obj)) {
            if ($null -eq $src) { continue }
            foreach ($key in @('file_path', 'path', 'file')) {
                $val = $src.$key
                if ($null -ne $val -and [string]$val -ne '') {
                    return [string]$val
                }
            }
        }
    } catch {
        # Invalid JSON or no parseable path. A formatting hook must never
        # surface an error to the user, so swallow it and format nothing.
        Write-Debug "format-on-edit: unparseable payload: $_"
    }
    return $null
}

# Does $Path exist and contain $Pattern as a literal substring?
#
# This is a helper rather than an inline `-and` on purpose: writing
# `Test-Path $p -PathType Leaf -and (Get-Content $p ...)` is valid syntax
# but binds `-and` as a *parameter* of Test-Path, so the guard never runs
# and Get-Content errors on the missing file. That bug shipped once.
function Test-FileContainsText {
    param([string]$Path, [string]$Pattern)
    if (-not (Test-Path $Path -PathType Leaf)) { return $false }
    return [bool](Get-Content $Path -Raw -ErrorAction SilentlyContinue |
        Select-String $Pattern -SimpleMatch -Quiet)
}

function Test-IsCargoProject {
    param([string]$Dir)
    return ((Test-Path (Join-Path $Dir 'rustfmt.toml') -PathType Leaf) -or
            (Test-Path (Join-Path $Dir 'Cargo.toml') -PathType Leaf))
}

function Test-IsPrettierProject {
    param([string]$Dir)
    if (Get-ChildItem (Join-Path $Dir '.prettierrc*') -File -ErrorAction SilentlyContinue) {
        return $true
    }
    return (Test-FileContainsText -Path (Join-Path $Dir 'package.json') -Pattern '"prettier"')
}

function Test-IsBlackProject {
    param([string]$Dir)
    return (Test-FileContainsText -Path (Join-Path $Dir 'pyproject.toml') -Pattern '[tool.black]')
}

# Walk up from a directory to find the project root (nearest ancestor
# with a formatter config file). Returns the root dir or null.
function Find-ProjectRoot {
    param([string]$Dir)
    for ($i = 0; $i -lt 12; $i++) {
        if (Test-IsCargoProject -Dir $Dir) { return $Dir }
        if (Test-IsPrettierProject -Dir $Dir) { return $Dir }
        if (Test-IsBlackProject -Dir $Dir) { return $Dir }
        $parent = Split-Path $Dir -Parent
        if (-not $parent -or $parent -eq $Dir) { break }
        $Dir = $parent
    }
    return $null
}

# Detect which formatter to use. Returns the tool name or null.
# The branches are exclusive, matching the sh variant: the first project
# type that matches wins outright, so a Rust project whose toolchain has
# no rustfmt does not fall through and get run through prettier.
function Get-Formatter {
    param([string]$Dir)
    $root = Find-ProjectRoot -Dir $Dir
    if (-not $root) { return $null }
    if (Test-IsCargoProject -Dir $root) {
        if (Get-Command rustfmt -ErrorAction SilentlyContinue) { return 'rustfmt' }
        return $null
    }
    if (Test-IsPrettierProject -Dir $root) {
        if (Get-Command npx -ErrorAction SilentlyContinue) { return 'prettier' }
        return $null
    }
    if (Test-IsBlackProject -Dir $root) {
        if (Get-Command black -ErrorAction SilentlyContinue) { return 'black' }
        return $null
    }
    return $null
}

$file = Get-EditedPath -Payload $payload

# No file path found — nothing to do.
if (-not $file) { exit 0 }

# Resolve to absolute path.
if (-not [System.IO.Path]::IsPathRooted($file)) {
    $file = Join-Path $PWD $file
}

# Must be a regular file.
if (-not (Test-Path $file -PathType Leaf)) { exit 0 }

$projDir = Split-Path $file -Parent
$fmtTool = Get-Formatter -Dir $projDir

switch ($fmtTool) {
    'rustfmt' {
        & rustfmt $file 2>$null
    }
    'prettier' {
        & npx --no-install prettier --write $file 2>$null
        if ($LASTEXITCODE -ne 0) {
            & npx prettier --write $file 2>$null
        }
    }
    'black' {
        & black $file 2>$null
    }
}

exit 0
