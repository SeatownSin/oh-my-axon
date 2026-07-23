# oh-my-axon format-on-edit gate (PostToolUse), Windows variant.
# Reads the hook payload from stdin, extracts the edited file path,
# detects the project formatter (rustfmt / prettier / black) by config
# file, and runs it on that file only. Never blocks an edit — always
# exits 0.

$payload = [Console]::In.ReadToEnd()

# Extract the edited file path from the payload JSON.
function Extract-Path {
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
        # Invalid JSON or no parseable path — return nothing.
    }
    return $null
}

# Walk up from a directory to find the project root (nearest ancestor
# with a formatter config file). Returns the root dir or null.
function Find-Root {
    param([string]$Dir)
    $i = 0
    while ($i -lt 12) {
        if (Test-Path "$Dir\rustfmt.toml" -PathType Leaf) { return $Dir }
        if (Test-Path "$Dir\Cargo.toml" -PathType Leaf) { return $Dir }
        if ((Get-ChildItem "$Dir\.prettierrc*" -File -ErrorAction SilentlyContinue)) { return $Dir }
        $pkg = Join-Path $Dir 'package.json'
        if (Test-Path $pkg -PathType Leaf -and (Get-Content $pkg -Raw | Select-String '"prettier"' -SimpleMatch)) { return $Dir }
        $py = Join-Path $Dir 'pyproject.toml'
        if (Test-Path $py -PathType Leaf -and (Get-Content $py -Raw | Select-String '[tool.black]' -SimpleMatch)) { return $Dir }
        $parent = Split-Path $Dir -Parent
        if ($parent -eq $Dir) { break }
        $Dir = $parent
        $i++
    }
    return $null
}

# Detect which formatter to use. Returns the tool name or null.
function Detect-Formatter {
    param([string]$Dir)
    $root = Find-Root -Dir $Dir
    if (-not $root) { return $null }
    if (Test-Path "$root\rustfmt.toml" -PathType Leaf -or (Test-Path "$root\Cargo.toml" -PathType Leaf)) {
        if (Get-Command rustfmt -ErrorAction SilentlyContinue) { return 'rustfmt' }
    }
    $hasPrettier = (Get-ChildItem "$root\.prettierrc*" -File -ErrorAction SilentlyContinue) -or `
        (Test-Path "$root\package.json" -PathType Leaf -and `
         (Get-Content "$root\package.json" -Raw | Select-String '"prettier"' -SimpleMatch))
    if ($hasPrettier -and (Get-Command npx -ErrorAction SilentlyContinue)) { return 'prettier' }
    if (Test-Path "$root\pyproject.toml" -PathType Leaf -and `
        (Get-Content "$root\pyproject.toml" -Raw | Select-String '[tool.black]' -SimpleMatch)) {
        if (Get-Command black -ErrorAction SilentlyContinue) { return 'black' }
    }
    return $null
}

$file = Extract-Path -Payload $payload

# No file path found — nothing to do.
if (-not $file) { exit 0 }

# Resolve to absolute path.
if (-not [System.IO.Path]::IsPathRooted($file)) {
    $file = Join-Path $PWD $file
}

# Must be a regular file.
if (-not (Test-Path $file -PathType Leaf)) { exit 0 }

$projDir = Split-Path $file -Parent
$fmtTool = Detect-Formatter -Dir $projDir

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
