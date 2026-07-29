# Shared catalog + endpoint probing for oh-my-axon's tools (Windows).
# Dot-sourced, never executed directly. Mirrors tools/lib/probe.sh.
#
# Credentials are read ONLY by Get-ProbeAuthKey, at the point of the request.
# They are deliberately absent from the catalog objects, so no formatting or
# reporting path can reach a secret and print it.

function Get-TomlValue {
    param([string]$Line)
    $v = $Line -replace '^[^=]*=\s*', ''
    # A value may legitimately contain a hash. Strip a trailing comment only
    # when it sits outside a quoted string, or an api_key of "abc#def"
    # silently becomes "abc" and the request fails as a puzzling 401.
    if ($v -match '^"([^"]*)"') { return $Matches[1] }
    if ($v -match "^'([^']*)'") { return $Matches[1] }
    return (($v -replace '\s*#.*$', '').Trim())
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
    if ($t -match '(\d+(?:\.\d+)?)b(?:[^a-z0-9]|$)') { return [double]$Matches[1] }
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

# The model an agent file pins in its own frontmatter, or empty.
#
# Only the frontmatter is read, never the body: scanning stops at the closing
# delimiter, so a `model:` mentioned in the prompt text below it is prose.
function Get-AgentModel {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $seenOpen = $false
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($line -match '^---\s*$') {
            if ($seenOpen) { break }
            $seenOpen = $true
            continue
        }
        if (-not $seenOpen) { continue }
        if ($line -match '^model:\s*(.*)$') {
            $v = $Matches[1] -replace '\s*#.*$', ''
            return $v.Trim().Trim('"').Trim("'")
        }
    }
    return ''
}

# The catalog key one role runs on, or empty when nothing resolves.
#
# Precedence, matching Axon's own: a [subagents.models] pin beats the agent
# file's own `model:` frontmatter, which beats [models] default. The middle step
# is not optional -- oh-my-axon's own `looker` pins `model: vision` in its
# frontmatter, so without it an unpinned looker run gets recorded as having run
# on the default model, which is a measurement of the wrong machine.
#
# gen-roles emits its pins with trailing comments, so Get-TomlValue (which
# strips a comment only outside quotes) does the reading -- `scout = "small"
# # recon` must not resolve to `small"  # recon`.
function Get-RoleModel {
    param([string]$Path, [string]$Role, [string]$AgentsDir)
    $sec = ''
    $pinned = ''
    $slot = ''
    $dflt = ''
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($line -match '^\s*\[models\]\s*$')            { $sec = 'models';    continue }
        if ($line -match '^\s*\[subagents\.models\]\s*$') { $sec = 'subagents'; continue }
        if ($line -match '^\s*\[')                        { $sec = '';          continue }
        if (-not $sec) { continue }
        if ($line -notmatch '=') { continue }
        $k = ($line -replace '\s*=.*$', '').Trim()
        if ($sec -eq 'subagents' -and $k -ceq $Role)   { $pinned = Get-TomlValue $line }
        elseif ($sec -eq 'models' -and $k -ceq $Role)  { $slot   = Get-TomlValue $line }
        elseif ($sec -eq 'models' -and $k -ceq 'default') { $dflt = Get-TomlValue $line }
    }
    if ($pinned) { return $pinned }
    if ($slot)   { return $slot }
    if ($AgentsDir) {
        $fm = Get-AgentModel -Path (Join-Path $AgentsDir "$Role.md")
        if ($fm) { return $fm }
    }
    return $dflt
}

# Every [model.<key>] section, with the derived fields both tools need.
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

# One value out of one [model.<key>] section, or empty.
function Get-ProbeSectionValue {
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

# The bearer token for one catalog key, or empty. Only function touching a secret.
function Get-ProbeAuthKey {
    param([string]$Path, [string]$Key)
    if ((Get-ProbeSectionValue -Path $Path -Key $Key -Field 'no_auth') -ceq 'true') { return '' }
    return (Get-ProbeSectionValue -Path $Path -Key $Key -Field 'api_key')
}

# The model's chat_template_kwargs as JSON, or empty. A probe that omits these
# tests the server WITHOUT the caller's configuration, which is a different
# question and produces false alarms: a model correctly configured with
# enable_thinking looks like it is leaking when asked bare.
function Get-ProbeTemplateKwargJson {
    param([string]$Path, [string]$Key)
    $v = Get-ProbeSectionValue -Path $Path -Key $Key -Field 'chat_template_kwargs'
    if (-not $v) { return '' }
    return ($v -replace '([A-Za-z_][A-Za-z0-9_]*)\s*=', '"$1":')
}

# GET or POST one endpoint. Returns Code (0 = nothing answered) and Body.
# Never throws: an unreachable server is a result, not an error.
function Invoke-ProbeRequest {
    param([string]$Url, [string]$AuthKey, [string]$Body, [int]$TimeoutSec = 5)
    $headers = @{}
    if ($AuthKey) { $headers['Authorization'] = "Bearer $AuthKey" }
    try {
        if ($Body) {
            $r = Invoke-WebRequest -Uri $Url -Method Post -Headers $headers -Body $Body `
                -ContentType 'application/json' -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        } else {
            $r = Invoke-WebRequest -Uri $Url -Headers $headers -TimeoutSec $TimeoutSec `
                -UseBasicParsing -ErrorAction Stop
        }
        return [pscustomobject]@{ Code = [int]$r.StatusCode; Body = [string]$r.Content }
    } catch {
        $code = 0
        if ($_.Exception.Response) {
            try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = 0 }
        }
        return [pscustomobject]@{ Code = $code; Body = '' }
    }
}

function Get-ProbeModelsEndpoint {
    param([string]$Url)
    return (($Url.TrimEnd('/')) + '/models')
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
