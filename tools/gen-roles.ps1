# oh-my-axon role-preset generator (Windows).
#
#   .\tools\gen-roles.ps1                  read the catalog in ~\.axon\config.toml
#   .\tools\gen-roles.ps1 -Probe           ask your servers what they are serving
#   .\tools\gen-roles.ps1 -Config PATH     read a specific config file
#   .\tools\gen-roles.ps1 -IncludeRemote   consider off-box models too
#
# Prints a [models] + [subagents.models] block that maps oh-my-axon's agents
# onto the models you actually have. Writes nothing, anywhere: review the
# output and paste the parts you want into ~\.axon\config.toml yourself.
#
# Models served from outside your machine or LAN are skipped by default: a
# role quietly pointed at a hosted endpoint would send your code off-box,
# which is the one thing this distribution promises not to do.
#
# The assignments are heuristics over model names, not measurements. They are
# a starting point to edit, not an answer.
#
# Everything the tool emits goes to the success stream, so redirecting it to a
# file (`.\tools\gen-roles.ps1 > roles.toml`) captures the whole snippet.
[CmdletBinding()]
param(
    [string]$Config,
    [switch]$Probe,
    [switch]$IncludeRemote
)

$ErrorActionPreference = 'Stop'
$OmaVersion = '0.1.1'

# Windows PowerShell 5.1 renders a redirected success stream through the
# console's OEM code page, which flattens any non-ASCII in a model's display
# name to '?' or '-'. Model ids are usually ASCII; the names beside them are
# free text and frequently are not.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    Write-Verbose "could not set console output encoding: $_"
}

if (-not $Config) {
    $axonHome = if ($env:AXON_HOME) { $env:AXON_HOME } else { Join-Path $HOME '.axon' }
    $Config = Join-Path $axonHome 'config.toml'
}

if (-not (Test-Path $Config -PathType Leaf)) {
    Write-Error @"
gen-roles: no config at $Config
  Run ``axon`` once so the first-run wizard detects your servers,
  or point at a config with -Config PATH.
"@
    exit 1
}

# Parameter count in billions scraped from a name, or 0 when it carries none.
# "8x7b" style MoE names multiply out. 0 sorts last, so an unlabelled model
# never wins the "biggest" slot by accident.
function Get-ParamCount {
    param([string]$Text)
    $t = $Text.ToLowerInvariant()
    if ($t -match '(\d+)x(\d+(?:\.\d+)?)b(?:[^a-z0-9]|$)') {
        return [double]$Matches[1] * [double]$Matches[2]
    }
    if ($t -match '(\d+(?:\.\d+)?)b(?:[^a-z0-9]|$)') {
        return [double]$Matches[1]
    }
    return 0.0
}

function Test-VisionName {
    param([string]$Text)
    $t = $Text.ToLowerInvariant()
    if ($t -match 'vision|llava|moondream|pixtral|internvl|cogvlm|idefics|smolvlm|minicpm-v') { return $true }
    return ($t -match '(^|[^a-z])vl([^a-z]|$)')
}

# Host is on this machine or this LAN. A missing base_url means a
# vendor-hosted catalog entry, which is off-box by definition.
function Test-LocalUrl {
    param([string]$Url)
    if (-not $Url) { return $false }
    $h = $Url.ToLowerInvariant() -replace '^[a-z]+://', ''
    $h = ($h -split '[/:]')[0]
    $h = $h -replace '[\[\]]', ''
    if ($h -eq 'localhost' -or $h -eq '::1' -or $h -match '^127\.') { return $true }
    if ($h -match '^10\.' -or $h -match '^192\.168\.') { return $true }
    if ($h -match '^172\.(1[6-9]|2\d|3[01])\.') { return $true }
    if ($h -match '\.(local|lan|home|internal|localdomain)$') { return $true }
    if ($h -notmatch '\.') { return $true }   # bare hostname: a LAN box
    return $false
}

function Get-TomlValue {
    param([string]$Line)
    $v = $Line -replace '^[^=]*=\s*', ''
    $v = $v -replace '\s*(#.*)?$', ''
    return $v.Trim().Trim('"').Trim("'")
}

# Parse every [model.<key>] section out of the config.
function Get-ModelCatalog {
    param([string]$Path)
    $entries = @()
    $cur = $null
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($line -match '^\s*\[model\.([^\]]+)\]') {
            $key = $Matches[1].Trim().Trim('"').Trim("'")
            $cur = [pscustomobject]@{ Key = $key; Model = ''; Label = ''; Url = ''; Ctx = 0 }
            $entries += $cur
            continue
        }
        if ($line -match '^\s*\[') { $cur = $null; continue }
        if ($null -eq $cur) { continue }
        if ($line -match '^\s*model\s*=')    { $cur.Model = Get-TomlValue $line; continue }
        if ($line -match '^\s*name\s*=')     { $cur.Label = Get-TomlValue $line; continue }
        if ($line -match '^\s*base_url\s*=') { $cur.Url   = Get-TomlValue $line; continue }
        if ($line -match '^\s*context_window\s*=') {
            $raw = Get-TomlValue $line
            if ($raw -match '^\d+$') { $cur.Ctx = [long]$raw }
            continue
        }
    }
    foreach ($e in $entries) {
        $blob = "$($e.Key) $($e.Model) $($e.Label)"
        $e | Add-Member -NotePropertyName Size    -NotePropertyValue (Get-ParamCount $blob)
        $e | Add-Member -NotePropertyName Vision  -NotePropertyValue (Test-VisionName $blob)
        $e | Add-Member -NotePropertyName IsLocal -NotePropertyValue (Test-LocalUrl $e.Url)
        $e | Add-Member -NotePropertyName Display -NotePropertyValue $(if ($e.Label) { $e.Label } else { $e.Model })
    }
    return $entries
}

$all = @(Get-ModelCatalog -Path $Config)

if ($all.Count -eq 0) {
    Write-Error @"
gen-roles: $Config defines no [model.*] entries.
  Run ``axon`` once to let the wizard detect your servers, or see
  config/config.toml.snippet for hand configuration.
"@
    exit 1
}

if ($IncludeRemote) {
    $catalog = $all
    $skipped = @()
} else {
    $catalog = @($all | Where-Object { $_.IsLocal })
    $skipped = @($all | Where-Object { -not $_.IsLocal })
}

if ($catalog.Count -eq 0) {
    Write-Error @"
gen-roles: every [model.*] entry in $Config is served off-box.
  Nothing local to assign. Start a local server and re-run, or pass
  -IncludeRemote to use the hosted entries anyway.
"@
    exit 1
}

# Ties break on the catalog key so the output is stable across runs.
$bySize = @{ Expression = 'Size'; Descending = $true }, @{ Expression = 'Key'; Descending = $false }
$bySizeAsc = @{ Expression = 'Size'; Descending = $false }, @{ Expression = 'Key'; Descending = $false }

$vision = @($catalog | Where-Object { $_.Vision } | Sort-Object $bySize) | Select-Object -First 1
$nonVision = @($catalog | Where-Object { -not $_.Vision })
if ($nonVision.Count -eq 0) { $nonVision = @($vision) }

$big = @($nonVision | Sort-Object $bySize) | Select-Object -First 1
$small = @($nonVision | Sort-Object $bySizeAsc) | Select-Object -First 1

$tiered = $big.Key -ne $small.Key

# Optional probe.
#
# Asks the endpoints your catalog ALREADY points at whether they are up, which
# ids they are serving right now, and what context length they report back. It
# does not guess ports: finding servers you have not configured yet belongs to
# the first-run wizard (`axon`), which sweeps the LAN as well, and a second
# detector here would only drift from it. Guessing is also simply wrong often
# enough to matter -- an LM Studio server on a high port is invisible to it,
# and so is every model served from another box.
#
# Off-box endpoints are not contacted unless -IncludeRemote, for the same
# reason they are not assigned: this distribution does not reach off your
# machine on its own.
#
# Probing NEVER changes the assignments below. Those come from your config
# alone, so a server that happens to be down right now cannot silently rewrite
# your model mapping -- it gets reported instead.

# One value out of one [model.<key>] section, or empty. Credentials are read
# here and nowhere else, so no formatting path can reach one.
function Get-SectionValue {
    param([string]$Path, [string]$Key, [string]$Field)
    $cur = $false
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($line -match '^\s*\[model\.([^\]]+)\]') {
            $cur = (($Matches[1].Trim().Trim('"').Trim("'")) -ceq $Key)
            continue
        }
        if ($line -match '^\s*\[') { $cur = $false; continue }
        if (-not $cur) { continue }
        if ($line -match ('^\s*' + [regex]::Escape($Field) + '\s*=')) { return (Get-TomlValue $line) }
    }
    return ''
}

# GET one endpoint. Returns the HTTP status (0 = nothing answered) and the
# body. Never throws: an unreachable server is a result, not an error.
function Invoke-ModelsRequest {
    param([string]$Url, [string]$Auth)
    $headers = @{}
    if ($Auth) { $headers['Authorization'] = "Bearer $Auth" }
    try {
        $r = Invoke-WebRequest -Uri $Url -Headers $headers -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        return [pscustomobject]@{ Code = [int]$r.StatusCode; Body = [string]$r.Content }
    } catch {
        $code = 0
        if ($_.Exception.Response) {
            try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = 0 }
        }
        return [pscustomobject]@{ Code = $code; Body = '' }
    }
}

function Get-ServedModelId {
    param([string]$Body)
    if (-not $Body) { return @() }
    try { $json = $Body | ConvertFrom-Json -ErrorAction Stop } catch { return @() }
    return @($json.data | ForEach-Object { $_.id } | Where-Object { $_ })
}

# vLLM answers with max_model_len; LM Studio and Ollama report nothing at all,
# which is why a missing value is silence rather than a complaint.
function Get-ServedContext {
    param([string]$Body, [string]$WireId)
    if (-not $Body) { return $null }
    try { $json = $Body | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    $m = @($json.data | Where-Object { $_.id -ceq $WireId })
    if ($m.Count -eq 0) { return $null }
    foreach ($f in @('max_model_len', 'loaded_context_length')) {
        if ($m[0].PSObject.Properties[$f] -and $m[0].$f) { return [long]$m[0].$f }
    }
    return $null
}

# The roles a catalog key is about to be handed, for reporting only.
function Get-RolesFor {
    param([string]$Key)
    $r = @()
    if ($Key -ceq $big.Key) { $r += 'default, architect, executor, reviewer' }
    if ($Key -ceq $small.Key) { $r += 'session_summary, prompt_suggestion, web_search, scout' }
    if ($vision -and $Key -ceq $vision.Key) { $r += 'image_description, looker' }
    return ($r -join ', ')
}

function Get-ProbeReport {
    $rows = @()
    $problems = @()
    # One request per endpoint even when several models share it, which is the
    # normal case: a box serving two models, or one model under two catalog
    # names.
    $cache = @{}

    foreach ($e in $all) {
        if ((-not $IncludeRemote) -and (-not $e.IsLocal)) {
            $rows += "#   SKIP   $($e.Key) -- off-box, not contacted"
            continue
        }
        if (-not $e.Url) {
            $rows += "#   SKIP   $($e.Key) -- no base_url to probe"
            continue
        }

        if ($cache.ContainsKey($e.Url)) {
            $res = $cache[$e.Url]
        } else {
            $auth = ''
            if ((Get-SectionValue -Path $Config -Key $e.Key -Field 'no_auth') -cne 'true') {
                $auth = Get-SectionValue -Path $Config -Key $e.Key -Field 'api_key'
            }
            $res = Invoke-ModelsRequest -Url (($e.Url.TrimEnd('/')) + '/models') -Auth $auth
            $cache[$e.Url] = $res
        }

        $ids = Get-ServedModelId -Body $res.Body
        if ($res.Code -eq 0) {
            $status = 'DOWN '
            $note = 'no answer'
        } elseif ($res.Code -eq 401 -or $res.Code -eq 403) {
            $status = 'AUTH '
            $note = "up, but rejected the credentials in your config (HTTP $($res.Code))"
        } elseif ($res.Code -ge 200 -and $res.Code -lt 300) {
            if ($e.Model -and ($ids -ccontains $e.Model)) {
                $status = 'UP   '
                $note = ''
            } else {
                $status = 'STALE'
                if ($ids.Count -gt 0) {
                    $note = "up, but serving $($ids -join ', ') -- not ""$($e.Model)"""
                } else {
                    $note = 'up, but serving nothing'
                }
            }
        } else {
            $status = 'DOWN '
            $note = "HTTP $($res.Code)"
        }

        if ($note) {
            $rows += "#   $status  $($e.Key) -- $($e.Url) ($note)"
        } else {
            $rows += "#   $status  $($e.Key) -- $($e.Url)"
        }

        $roles = Get-RolesFor -Key $e.Key
        if ($status -ceq 'UP   ') {
            $srvctx = Get-ServedContext -Body $res.Body -WireId $e.Model
            if ($null -ne $srvctx -and $e.Ctx -eq 0) {
                $problems += "#   $($e.Key) sets no context_window, but the server reports $srvctx."
                $problems += '#     Axon assumes 200000 without it, so compaction fires at the wrong point.'
            } elseif ($null -ne $srvctx -and $e.Ctx -ne $srvctx) {
                $problems += "#   $($e.Key) claims context_window = $($e.Ctx); the server reports $srvctx."
            }
        } elseif ($roles) {
            $problems += "#   $($e.Key) is assigned below ($roles) but is not usable right now."
        }
    }

    if ($rows.Count -eq 0) { return @('# (-Probe: no endpoint to contact)') }
    $out = @('# Probe -- what your configured endpoints are serving right now:') + $rows
    if ($problems.Count -gt 0) {
        $out += '#'
        $out += '# Problems:'
        $out += $problems
    }
    return $out
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
$out = @()
$out += '# ---------------------------------------------------------------------------'
$out += "# oh-my-axon $OmaVersion role presets"
$out += "# Generated from the $($catalog.Count) usable model(s) in $Config"
$out += '#'
$out += '# SUGGESTIONS, not measurements: the split below is inferred from parameter'
$out += '# counts in your model names. Read it, change what you disagree with, and'
$out += '# paste into ~\.axon\config.toml. Nothing has been written for you.'
$out += '#'
$out += '# Merge by hand if you already have these tables -- appending a second'
$out += '# [models] section to a TOML file is a parse error, not an override.'
$out += '# ---------------------------------------------------------------------------'

if ($Probe) {
    $out += '#'
    $out += Get-ProbeReport
    $out += '#'
}

if ($skipped.Count -gt 0) {
    $out += ''
    $out += '# Skipped as off-box (pass -IncludeRemote to use them anyway):'
    foreach ($s in $skipped) { $out += "#   $($s.Key) -- $($s.Display)" }
}

$out += ''
if ($tiered) {
    $out += "# Big:   $($big.Key) -- $($big.Display)"
    $out += "# Small: $($small.Key) -- $($small.Display)"
} elseif ($catalog.Count -eq 1) {
    $out += "# Only one usable model ($($big.Key) -- $($big.Display)), so every role points at it."
    $out += '# With a second, smaller server running, re-run this to get a real split.'
} else {
    $out += "# $($catalog.Count) local models, but none reads as smaller than the others, so"
    $out += "# every role points at $($big.Key) -- $($big.Display)."
    $out += '# Sizes are read from model names; if one of yours is genuinely lighter,'
    $out += '# put it in the scout / session_summary / prompt_suggestion slots by hand.'
}

$out += ''
$out += '[models]'
$out += "default = ""$($big.Key)"""
$out += '# Short, frequent, latency-sensitive calls. Cheap models are fine here;'
$out += '# on a single-model setup these just reuse the one you have.'
$out += "session_summary = ""$($small.Key)""      # session titles"
$out += "prompt_suggestion = ""$($small.Key)""    # tab-completion ghost text"
$out += "web_search = ""$($small.Key)""           # synthesizes search results"
if ($vision) {
    $out += "image_description = ""$($vision.Key)""   # transcribes images you paste"
} else {
    $out += '# image_description = "..."  # no multimodal model found in your catalog'
}

$out += ''
$out += '# Per-agent pins. These beat each agent''s own `model:` frontmatter, so this'
$out += '# is where you retarget oh-my-axon''s agents without editing their files.'
$out += '[subagents.models]'
$out += "scout = ""$($small.Key)""        # read-only recon: wide, shallow, high volume"
$out += "architect = ""$($big.Key)""      # planning: the reasoning-heaviest role"
$out += "executor = ""$($big.Key)""       # writes code; weakest link if under-powered"
$out += "reviewer = ""$($big.Key)""       # must catch what executor got wrong"
if ($vision) {
    $out += "looker = ""$($vision.Key)""      # $($vision.Display)"
} else {
    $out += '# looker = "..."          # needs a multimodal model; none found in your'
    $out += '                          # catalog. Its frontmatter expects a model named'
    $out += '                          # "vision" -- add [model.vision] or pin it here.'
}

$out += ''
$out += '# Reminder, because it is the single most common local-model misconfiguration:'
$out += '# set context_window on every [model.*] entry to the context the server was'
$out += '# actually started with. It defaults to 200000, and auto-compaction fires at'
$out += '# 85% of whatever you claim -- so an honest number is what keeps long runs'
$out += '# from overflowing the server.'

$out | Write-Output
