<#
.SYNOPSIS
    Install the Universal Agent Engine into an existing codebase - Windows.

.DESCRIPTION
    Copies the engine's agent definitions, skills, docs and helper scripts into a
    target repository, then merges the few files that a host repo may already own
    (.claude/settings.json, CLAUDE.md, .gitattributes) instead of clobbering them.

    Source resolution:

      Mode      How it is picked
      -------   -------------------------------------------------------------
      local     $PSScriptRoot holds .claude\UAE.md and .claude\agents\
                orchestrator.md (you cloned or downloaded the engine repo)
      remote    anything else - downloads
                https://github.com/One-Uncle/universal-agent-engine/archive/refs/heads/<Ref>.zip
                into a temp dir, which is deleted on the way out

    Engine-owned files are skip-if-exists: a file that is missing gets installed,
    a file that is byte-identical is reported up-to-date, and a file that differs
    is skipped unless -Force is given. Nothing the host repo owns is ever
    rewritten - the merge steps only add what is missing.

    Safe to re-run: every step is idempotent. Mirrors install.sh exactly, so a
    repo installed by either script ends up with the same structure.

.PARAMETER TargetDir
    Repository to install into. Defaults to the current directory. Must exist.

.PARAMETER Force
    Overwrite engine-owned files that exist but differ from the engine version.

.PARAMETER DryRun
    Print every planned action and write nothing.

.PARAMETER Ref
    Branch or tag to download in remote mode. Defaults to 'main'.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1 -TargetDir C:\code\my-site
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1 -DryRun
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1 -TargetDir . -Force -Ref main
#>
param(
    [string]$TargetDir = '.',
    [switch]$Force,
    [switch]$DryRun,
    [string]$Ref = 'main'
)

$ErrorActionPreference = 'Stop'

$RepoSlug = 'One-Uncle/universal-agent-engine'

# Engine-owned files, copied verbatim. README.md, install.sh, install.ps1 and
# .gitattributes are deliberately NOT in this list - the host repo owns those.
$EngineFiles = @(
    '.claude/UAE.md'
    '.claude/agents/orchestrator.md'
    '.claude/agents/swarm-worker.md'
    '.claude/agents/chat-responder.md'
    '.claude/agents/skill-manager.md'
    '.claude/agents/agent-builder.md'
    '.claude/skills/init-project/SKILL.md'
    'docs/orchestration-playbook.md'
    'docs/token-efficiency.md'
    'project-details/README.md'
    'scripts/install-rtk.sh'
    'scripts/install-rtk.ps1'
)

# Project variables the engine expects in settings.json -> env.
$EnvKeys = @(
    'UAE_PROJECT_NAME'
    'UAE_PROJECT_TYPE'
    'UAE_STACK'
    'UAE_HOSTING'
    'UAE_SOURCE_OF_TRUTH'
    'UAE_EXCLUSIVE_RESOURCES'
    'UAE_COMPONENTS_PATH'
    'UAE_CONTENT_PATH'
    'UAE_TOKENS_PATH'
    'UAE_AUDITS_PATH'
    'UAE_DESIGN_SYSTEM'
    'UAE_BRAND_VOICE'
    'UAE_DEPLOY_MODEL'
)

$ClaudeMdDirective = '@.claude/UAE.md'
$ClaudeMdHeading   = '# Universal Agent Engine'
$GitAttributesLine = '*.sh text eol=lf'

$script:TempDir      = $null
$script:SkippedFiles = @()
$script:Counts       = @{ Installed = 0; UpToDate = 0; Skipped = 0; Merged = 0 }

# --- Helpers ----------------------------------------------------------------

function Write-Log([string]$Message) { Write-Host "[uae-install] $Message" }

function Write-Action([string]$Message) {
    if ($DryRun) { Write-Log "DRY RUN: $Message" } else { Write-Log $Message }
}

function ConvertTo-NativePath([string]$Relative) {
    ($Relative -split '/') -join [System.IO.Path]::DirectorySeparatorChar
}

function New-ParentDirectory([string]$Path) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    New-ParentDirectory $Path
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Add-Utf8NoBom([string]$Path, [string]$Content) {
    [System.IO.File]::AppendAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-FileText([string]$Path) {
    # Not Get-Content -Raw: Windows PowerShell 5.1 reads BOM-less files with the
    # ANSI code page, which mangles any non-ASCII text the host repo owns.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Test-SameFile([string]$A, [string]$B) {
    (Get-FileHash -LiteralPath $A -Algorithm SHA256).Hash -eq
    (Get-FileHash -LiteralPath $B -Algorithm SHA256).Hash
}

function Test-JsonProperty($Object, [string]$Name) {
    if ($null -eq $Object) { return $false }
    return [bool]($Object.PSObject.Properties.Name -contains $Name)
}

# Windows PowerShell 5.1 escapes <, >, &, ' and every non-ASCII character as
# \uXXXX, and pretty-prints JSON with wide, column-aligned indentation. All of
# that is legal JSON but none of it matches what install.sh (jq) writes, so
# re-render: unescape what does not need escaping, then indent with two spaces.
function ConvertFrom-JsonUnicodeEscape([string]$Json) {
    $evaluator = {
        param($match)
        $code = [Convert]::ToInt32($match.Groups[2].Value, 16)
        # Control chars, " and \ must stay escaped; surrogate halves are left
        # alone rather than risk emitting an unpaired one.
        if ($code -lt 0x20 -or $code -eq 0x22 -or $code -eq 0x5C -or
            ($code -ge 0xD800 -and $code -le 0xDFFF)) {
            return $match.Value
        }
        # Group 1 carries any preceding escaped backslashes, so a literal
        # "\\u003c" in the host's data is matched as data and left untouched.
        return $match.Groups[1].Value + [char]$code
    }
    return [regex]::Replace($Json, '(?<!\\)((?:\\\\)*)\\u([0-9a-fA-F]{4})', $evaluator)
}

function Format-Json([string]$CompactJson) {
    $sb = New-Object System.Text.StringBuilder
    $indent = 0
    $inString = $false
    $escaped = $false

    for ($i = 0; $i -lt $CompactJson.Length; $i++) {
        $ch = $CompactJson[$i]

        if ($inString) {
            [void]$sb.Append($ch)
            if ($escaped) { $escaped = $false }
            elseif ($ch -eq '\') { $escaped = $true }
            elseif ($ch -eq '"') { $inString = $false }
            continue
        }

        if ($ch -eq '{' -or $ch -eq '[') {
            $closer = if ($ch -eq '{') { '}' } else { ']' }
            # Empty container: keep {} and [] on one line, the way jq prints them.
            if (($i + 1) -lt $CompactJson.Length -and $CompactJson[$i + 1] -eq $closer) {
                [void]$sb.Append($ch).Append($closer)
                $i++
                continue
            }
            $indent++
            [void]$sb.Append($ch).Append("`n").Append(' ' * (2 * $indent))
            continue
        }

        switch -CaseSensitive ($ch) {
            '"' { $inString = $true; [void]$sb.Append($ch) }
            '}' { $indent--; [void]$sb.Append("`n").Append(' ' * (2 * $indent)).Append($ch) }
            ']' { $indent--; [void]$sb.Append("`n").Append(' ' * (2 * $indent)).Append($ch) }
            ',' { [void]$sb.Append($ch).Append("`n").Append(' ' * (2 * $indent)) }
            ':' { [void]$sb.Append(': ') }
            default { [void]$sb.Append($ch) }
        }
    }

    return $sb.ToString()
}

# --- Source resolution ------------------------------------------------------

function Resolve-EngineSource([string]$Ref) {
    $marker1 = ConvertTo-NativePath '.claude/UAE.md'
    $marker2 = ConvertTo-NativePath '.claude/agents/orchestrator.md'

    # $PSScriptRoot is empty when the script is piped through iex - remote mode.
    if ($PSScriptRoot -and
        (Test-Path -LiteralPath (Join-Path $PSScriptRoot $marker1) -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $PSScriptRoot $marker2) -PathType Leaf)) {
        Write-Log "Engine source: local copy at $PSScriptRoot"
        return $PSScriptRoot
    }

    $url = "https://github.com/$RepoSlug/archive/refs/heads/$Ref.zip"
    Write-Log "Engine source: downloading ref '$Ref' from GitHub..."

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) "uae-install-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Path $temp | Out-Null
    $script:TempDir = $temp

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
        # Older .NET without Tls12 in the enum - nothing to do but try anyway.
    }

    $zip = Join-Path $temp 'engine.zip'
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    }
    catch {
        throw "Download failed for $url : $($_.Exception.Message)"
    }
    finally {
        $ProgressPreference = $previousProgress
    }

    Expand-Archive -Path $zip -DestinationPath $temp -Force

    $extracted = Get-ChildItem -LiteralPath $temp -Directory |
        Where-Object { $_.Name -like 'universal-agent-engine-*' } |
        Select-Object -First 1
    if (-not $extracted) { throw "Downloaded archive did not contain a universal-agent-engine-* directory." }

    return $extracted.FullName
}

# --- Engine-owned files -----------------------------------------------------

function Copy-EngineFile([string]$Relative, [string]$SourceRoot, [string]$TargetRoot) {
    $native = ConvertTo-NativePath $Relative
    $src = Join-Path $SourceRoot $native
    $dst = Join-Path $TargetRoot $native

    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
        throw "Engine file missing from source: $Relative (looked in $SourceRoot)"
    }

    if (-not (Test-Path -LiteralPath $dst)) {
        Write-Action "installed $Relative"
        if (-not $DryRun) {
            New-ParentDirectory $dst
            Copy-Item -LiteralPath $src -Destination $dst
        }
        $script:Counts.Installed++
        return
    }

    if (Test-SameFile $src $dst) {
        Write-Action "up-to-date $Relative"
        $script:Counts.UpToDate++
        return
    }

    if ($Force) {
        Write-Action "overwrote $Relative"
        if (-not $DryRun) { Copy-Item -LiteralPath $src -Destination $dst -Force }
        $script:Counts.Installed++
    }
    else {
        Write-Action "skipped (differs - rerun with -Force to overwrite) $Relative"
        $script:Counts.Skipped++
        $script:SkippedFiles += $Relative
    }
}

# --- Merge: .claude/settings.json -------------------------------------------

function Merge-SettingsJson([string]$SourceRoot, [string]$TargetRoot) {
    $relative = '.claude/settings.json'
    $native = ConvertTo-NativePath $relative
    $src = Join-Path $SourceRoot $native
    $dst = Join-Path $TargetRoot $native

    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
        throw "Engine file missing from source: $relative (looked in $SourceRoot)"
    }

    if (-not (Test-Path -LiteralPath $dst)) {
        Write-Action "installed $relative"
        if (-not $DryRun) {
            New-ParentDirectory $dst
            Copy-Item -LiteralPath $src -Destination $dst
        }
        $script:Counts.Installed++
        return
    }

    $raw = Get-FileText $dst
    if ($raw.Trim().Length -eq 0) {
        $settings = [pscustomobject]@{}
    }
    else {
        try { $settings = $raw | ConvertFrom-Json }
        catch { throw "Could not parse $dst as JSON - fix or move it, then re-run. ($($_.Exception.Message))" }
    }
    if ($null -eq $settings) { $settings = [pscustomobject]@{} }

    # (a) rtk PreToolUse hook -------------------------------------------------
    if (-not (Test-JsonProperty $settings 'hooks')) {
        Add-Member -InputObject $settings -NotePropertyName 'hooks' -NotePropertyValue ([pscustomobject]@{})
    }
    $hooks = $settings.hooks
    if ($hooks -isnot [System.Management.Automation.PSCustomObject]) {
        throw "$dst has a 'hooks' key that is not an object - merge it by hand, then re-run."
    }
    if (-not (Test-JsonProperty $hooks 'PreToolUse')) {
        Add-Member -InputObject $hooks -NotePropertyName 'PreToolUse' -NotePropertyValue @()
    }

    $preToolUse = @($hooks.PreToolUse)
    $hookPresent = $false
    foreach ($entry in $preToolUse) {
        foreach ($inner in @($entry.hooks)) {
            if ($inner -and (Test-JsonProperty $inner 'command') -and
                ("$($inner.command)").Contains('rtk hook claude')) {
                $hookPresent = $true
            }
        }
    }

    $hookState = 'hook already present'
    if (-not $hookPresent) {
        $newEntry = [pscustomobject]@{
            matcher = 'Bash'
            hooks   = [object[]]@(
                [pscustomobject]@{
                    type    = 'command'
                    command = 'rtk hook claude || exit 0'
                }
            )
        }
        $hooks.PreToolUse = [object[]](@($preToolUse) + @($newEntry))
        $hookState = 'hook added'
    }

    # (b) UAE_* env keys ------------------------------------------------------
    if (-not (Test-JsonProperty $settings 'env')) {
        Add-Member -InputObject $settings -NotePropertyName 'env' -NotePropertyValue ([pscustomobject]@{})
    }
    if ($settings.env -isnot [System.Management.Automation.PSCustomObject]) {
        throw "$dst has an 'env' key that is not an object - merge it by hand, then re-run."
    }

    $addedKeys = 0
    foreach ($key in $EnvKeys) {
        if (-not (Test-JsonProperty $settings.env $key)) {
            # Existing values are never touched; only missing keys are seeded.
            Add-Member -InputObject $settings.env -NotePropertyName $key -NotePropertyValue 'UNSET'
            $addedKeys++
        }
    }

    if ($addedKeys -eq 0 -and $hookState -eq 'hook already present') {
        Write-Action "up-to-date $relative"
        $script:Counts.UpToDate++
        return
    }

    Write-Action "merged $relative (added $addedKeys env keys, $hookState)"
    if (-not $DryRun) {
        $json = $settings | ConvertTo-Json -Depth 16 -Compress
        $json = Format-Json (ConvertFrom-JsonUnicodeEscape $json)
        Write-Utf8NoBom $dst ($json.TrimEnd("`r", "`n") + "`n")
    }
    $script:Counts.Merged++
}

# --- Merge: CLAUDE.md -------------------------------------------------------

function Merge-ClaudeMd([string]$TargetRoot) {
    $relative = 'CLAUDE.md'
    $dst = Join-Path $TargetRoot $relative
    $fresh = "$ClaudeMdHeading`n`n$ClaudeMdDirective`n"

    if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) {
        Write-Action "installed $relative"
        if (-not $DryRun) { Write-Utf8NoBom $dst $fresh }
        $script:Counts.Installed++
        return
    }

    $raw = Get-FileText $dst

    if ($raw.Trim().Length -eq 0) {
        Write-Action "installed $relative"
        if (-not $DryRun) { Write-Utf8NoBom $dst $fresh }
        $script:Counts.Installed++
        return
    }

    if ($raw.Contains($ClaudeMdDirective)) {
        Write-Action "up-to-date $relative"
        $script:Counts.UpToDate++
        return
    }

    # Append only - the host's existing bytes are left exactly as they are.
    $prefix = ''
    if (-not $raw.EndsWith("`n")) { $prefix = "`n" }
    $append = "$prefix`n$ClaudeMdHeading`n`n$ClaudeMdDirective`n"

    Write-Action "merged $relative (added $ClaudeMdDirective include)"
    if (-not $DryRun) { Add-Utf8NoBom $dst $append }
    $script:Counts.Merged++
}

# --- Merge: .gitattributes --------------------------------------------------

function Merge-GitAttributes([string]$TargetRoot) {
    $relative = '.gitattributes'
    $dst = Join-Path $TargetRoot $relative

    if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) {
        Write-Action "installed $relative"
        if (-not $DryRun) { Write-Utf8NoBom $dst "$GitAttributesLine`n" }
        $script:Counts.Installed++
        return
    }

    $raw = Get-FileText $dst
    $lines = $raw -split "`n"
    foreach ($line in $lines) {
        if ($line.Trim() -eq $GitAttributesLine) {
            Write-Action "up-to-date $relative"
            $script:Counts.UpToDate++
            return
        }
    }

    $prefix = ''
    if ($raw.Length -gt 0 -and -not $raw.EndsWith("`n")) { $prefix = "`n" }

    Write-Action "merged $relative (added '$GitAttributesLine')"
    if (-not $DryRun) { Add-Utf8NoBom $dst "$prefix$GitAttributesLine`n" }
    $script:Counts.Merged++
}

# --- Summary ----------------------------------------------------------------

function Write-Summary([string]$TargetRoot) {
    Write-Log ''
    Write-Log ("Summary: {0} installed, {1} up-to-date, {2} skipped, {3} merged" -f `
        $script:Counts.Installed, $script:Counts.UpToDate, $script:Counts.Skipped, $script:Counts.Merged)

    if ($script:SkippedFiles.Count -gt 0) {
        Write-Log 'Skipped because the target version differs (rerun with -Force to overwrite):'
        foreach ($file in $script:SkippedFiles) { Write-Log "  - $file" }
    }

    if ($DryRun) { Write-Log 'DRY RUN: nothing was written.' }

    Write-Log ''
    Write-Log 'Next steps:'
    Write-Host ''
    Write-Host '  1. Optional but recommended: run'
    Write-Host '     powershell -ExecutionPolicy Bypass -File scripts\install-rtk.ps1'
    Write-Host '     This installs rtk, which compresses shell output by 60-90% before an agent'
    Write-Host '     reads it. The engine works fine without rtk; it just costs more tokens.'
    Write-Host ''
    Write-Host '  2. Drop whatever project documents you already have (briefs, specs, brand or'
    Write-Host '     voice guides, design exports, deployment notes) into project-details/.'
    Write-Host '     The intake skill reads every file in that folder.'
    Write-Host ''
    Write-Host '  3. Open Claude Code in this repository and say "initialize project". The engine'
    Write-Host '     runs its intake, fills the UAE_* variables in .claude/settings.json from your'
    Write-Host '     documents, and reports which ones are still UNSET so you can answer them.'
    Write-Host ''
    Write-Host '  4. Review the new files and commit them, so everyone working in the repository'
    Write-Host '     gets the same engine.'
    Write-Host ''
}

# --- Main -------------------------------------------------------------------

try {
    if (-not (Test-Path -LiteralPath $TargetDir -PathType Container)) {
        throw "Target directory does not exist: $TargetDir"
    }
    $targetRoot = (Resolve-Path -LiteralPath $TargetDir).Path

    $sourceRoot = (Resolve-Path -LiteralPath (Resolve-EngineSource -Ref $Ref)).Path

    if ($targetRoot -eq $sourceRoot) {
        throw 'cannot install engine into itself - pass -TargetDir pointing at the repository you want the engine installed into.'
    }

    if (-not (Test-Path -LiteralPath (Join-Path $targetRoot '.git'))) {
        Write-Log "Warning: $targetRoot is not a git repository (no .git found) - installing anyway."
    }

    Write-Log "Installing Universal Agent Engine into $targetRoot"
    if ($DryRun) { Write-Log 'DRY RUN: planning only, no files will be written.' }

    foreach ($relative in $EngineFiles) {
        Copy-EngineFile -Relative $relative -SourceRoot $sourceRoot -TargetRoot $targetRoot
    }

    Merge-SettingsJson -SourceRoot $sourceRoot -TargetRoot $targetRoot
    Merge-ClaudeMd -TargetRoot $targetRoot
    Merge-GitAttributes -TargetRoot $targetRoot

    Write-Summary -TargetRoot $targetRoot
}
finally {
    if ($script:TempDir -and (Test-Path -LiteralPath $script:TempDir)) {
        Remove-Item -Recurse -Force -LiteralPath $script:TempDir -ErrorAction SilentlyContinue
    }
}
