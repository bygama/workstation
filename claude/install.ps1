<#
.SYNOPSIS
    Applies this folder's Claude Code configuration to ~/.claude.

.DESCRIPTION
    Reconciles the Claude Code CLI prerequisite, marketplaces, plugins, CLAUDE.md, rules,
    the Agent-Engineering skill junctions, settings.json, and - only with -Secrets - the
    user-scope MCP servers declared here.

    settings.json is merged rather than copied. Repo keys win and valid unmanaged live keys
    remain. Legacy hook shapes that make Claude reject the whole file are not preserved.

    Idempotent. Exit code 0 means everything asked for is in place; 1 means it isn't, and
    the summary names what.

.PARAMETER Secrets
    Resolve mcp.template.json with secrets/.env and apply each declared server through
    `claude mcp --scope user`. Off by default: without it this script never touches a file
    that holds API keys.

.PARAMETER WhatIfOnly
    Report every action without performing any of them.

.EXAMPLE
    pwsh claude\install.ps1
    pwsh claude\install.ps1 -WhatIfOnly
    pwsh claude\install.ps1 -Secrets
#>
[CmdletBinding()]
param(
    [switch]$Secrets,
    [switch]$WhatIfOnly
)

. "$PSScriptRoot\..\_lib.ps1"
Assert-PowerShell7

$script:DryRun = [bool]$WhatIfOnly
$failed = [System.Collections.Generic.List[string]]::new()
$claudeHome = Join-Path $HOME '.claude'
$configChanged = $false
$repoSettingsPath = Join-Path $PSScriptRoot 'settings.json'
$repoSettings = Get-Content $repoSettingsPath -Raw | ConvertFrom-Json -AsHashtable

# Sort every object's keys, at every depth, so ConvertTo-Json emits the same text for the
# same content.
#
# Without this the script is not idempotent and the bug is invisible: a PowerShell hashtable
# has no defined key order, so serialising identical settings twice gives two different
# strings, the "already identical" check never matches, and every run rewrites the file and
# drops another copy into the backup folder. Arrays keep their order - that is data, not
# layout.
function ConvertTo-Sorted {
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($k in @($Value.Keys) | Sort-Object) { $out[$k] = ConvertTo-Sorted $Value[$k] }
        return $out
    }
    if ($Value -is [object[]] -or $Value -is [System.Collections.IList]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $items.Add((ConvertTo-Sorted $item)) }
        # The unary comma stops PowerShell from unrolling the array on return: without it an
        # empty array comes back as $null and a one-element array as its bare element, which
        # corrupts hook matcher lists into shapes Claude rejects.
        return , $items.ToArray()
    }
    return $Value
}

# User skills are junction links into the repos listed in $skillSources, so editing those
# repos updates the live skills with no copy step. Linking every directory under each
# source keeps this declarative: a skill added there appears on the next run.

# Claude rejects an entire user settings file when one hook has the legacy object shape.
# Preserve third-party hooks only when every event and matcher uses the current array form.
function Test-HooksShape {
    param($Hooks)
    if ($null -eq $Hooks -or $Hooks -isnot [System.Collections.IDictionary]) { return $false }
    foreach ($eventName in $Hooks.Keys) {
        $matchers = $Hooks[$eventName]
        if ($matchers -isnot [System.Collections.IList]) { return $false }
        foreach ($matcher in $matchers) {
            if ($matcher -isnot [System.Collections.IDictionary]) { return $false }
            if (-not $matcher.ContainsKey('hooks') -or $matcher.hooks -isnot [System.Collections.IList]) {
                return $false
            }
        }
    }
    return $true
}

# ---------------------------------------------------------------- CLI and plugins
Write-Step 'Claude Code CLI'
$hasClaude = Test-Cmd claude.exe
if (-not $hasClaude) {
    Write-Fail 'claude.exe is missing. Install it before running the restore:'
    Write-Host '         irm https://claude.ai/install.ps1 | iex' -ForegroundColor DarkGray
    Write-Host '         Then open a new PowerShell 7 window.' -ForegroundColor DarkGray
    $failed.Add('Claude Code CLI')
}
else {
    $claudeVersion = (& claude.exe --version 2>$null | Out-String).Trim()
    Write-Ok "Claude Code $claudeVersion"
}

Write-Step 'Plugin marketplaces and plugins'
if (-not $hasClaude) {
    Write-Warn2 'plugin sync skipped - Claude Code CLI is missing'
}
else {
    $marketplaceManifest = Get-Content (Join-Path $PSScriptRoot 'marketplaces.json') -Raw |
        ConvertFrom-Json -AsHashtable
    $marketplaces = @()
    try {
        $marketplaces = @((& claude.exe plugin marketplace list --json 2>$null | Out-String) |
                ConvertFrom-Json)
    }
    catch {
        Write-Fail "could not inspect Claude plugin marketplaces: $($_.Exception.Message)"
        $failed.Add('plugin marketplace inspection')
    }

    foreach ($name in $marketplaceManifest.marketplaces.Keys) {
        if ($marketplaces.name -contains $name) {
            Write-Skip "$name marketplace already registered"
            continue
        }

        $source = $marketplaceManifest.marketplaces[$name]
        if ($script:DryRun) {
            Write-Would "register $name marketplace from $source"
            continue
        }

        & claude.exe plugin marketplace add --scope user $source 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "$name marketplace registered"
            $configChanged = $true
        }
        else {
            Write-Fail "$name marketplace could not be registered from $source"
            $failed.Add("plugin marketplace: $name")
        }
    }

    $installedPlugins = @()
    try {
        $installedPlugins = @((& claude.exe plugin list --json 2>$null | Out-String) |
                ConvertFrom-Json)
    }
    catch {
        Write-Fail "could not inspect installed Claude plugins: $($_.Exception.Message)"
        $failed.Add('plugin inspection')
    }

    $wantedPlugins = @($repoSettings.enabledPlugins.Keys | Where-Object {
            $repoSettings.enabledPlugins[$_]
        })
    foreach ($id in $wantedPlugins) {
        $installed = $installedPlugins | Where-Object id -eq $id | Select-Object -First 1
        if ($installed -and $installed.enabled) {
            Write-Skip "$id already installed and enabled"
            continue
        }

        $action = if ($installed) { 'enable' } else { 'install' }
        if ($script:DryRun) {
            Write-Would "$action user plugin $id"
            continue
        }

        if ($installed) { & claude.exe plugin enable $id --scope user 2>&1 | Out-Null }
        else { & claude.exe plugin install $id --scope user 2>&1 | Out-Null }
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "$id $(if ($installed) { 'enabled' } else { 'installed' })"
            $configChanged = $true
        }
        else {
            Write-Fail "$id could not be $(if ($action -eq 'enable') { 'enabled' } else { 'installed' })"
            $failed.Add("plugin: $id")
        }
    }
}

# ---------------------------------------------------------------- CLAUDE.md
Write-Step 'CLAUDE.md'
$claudeMdPath = Join-Path $claudeHome 'CLAUDE.md'
$ownedText = (Get-Content (Join-Path $PSScriptRoot 'CLAUDE.md') -Raw).TrimEnd()
$claudeText = $ownedText + "`n"
$claudeNeedsWrite = -not (Test-Path $claudeMdPath -PathType Leaf) -or
    ((Get-Content $claudeMdPath -Raw) -cne $claudeText)
if (-not (Install-ConfigText -Destination $claudeMdPath -Text $claudeText -Label 'CLAUDE.md')) {
    $failed.Add('CLAUDE.md')
}
elseif ($claudeNeedsWrite -and -not $script:DryRun) { $configChanged = $true }

# ---------------------------------------------------------------- rules
Write-Step 'Rules'
$rulesSrc = Join-Path $PSScriptRoot 'rules\common'
$rulesDst = Join-Path $claudeHome 'rules\common'
$repoRules = @(Get-ChildItem $rulesSrc -Filter *.md -ErrorAction SilentlyContinue | Sort-Object Name)
foreach ($f in $repoRules) {
    if (-not (Install-ConfigFile $f.FullName (Join-Path $rulesDst $f.Name))) {
        $failed.Add("rule: $($f.Name)")
    }
}
# This directory is declarative: a removed repo rule must stop loading globally. Backups
# make the first cleanup recoverable, and unrelated rule directories are untouched.
$wantedRuleNames = @($repoRules.Name)
foreach ($liveRule in @(Get-ChildItem $rulesDst -Filter *.md -ErrorAction SilentlyContinue)) {
    if ($liveRule.Name -in $wantedRuleNames) { continue }
    if ($script:DryRun) { Write-Would "remove undeclared global rule $($liveRule.FullName)"; continue }
    try {
        Backup-ExistingFile $liveRule.FullName | Out-Null
        Remove-Item -LiteralPath $liveRule.FullName -Force
        $configChanged = $true
        Write-Ok "removed undeclared global rule $($liveRule.Name)"
    }
    catch {
        Write-Fail "could not remove global rule $($liveRule.Name): $($_.Exception.Message)"
        $failed.Add("rule cleanup: $($liveRule.Name)")
    }
}

# ---------------------------------------------------------------- hooks
Write-Step 'Hooks'
$hooksSrc = Join-Path $PSScriptRoot 'hooks'
$hooksDst = Join-Path $claudeHome 'hooks'
foreach ($f in @(Get-ChildItem $hooksSrc -Filter *.ps1 -ErrorAction SilentlyContinue | Sort-Object Name)) {
    if (-not (Install-ConfigFile $f.FullName (Join-Path $hooksDst $f.Name))) {
        $failed.Add("hook: $($f.Name)")
    }
}

# ---------------------------------------------------------------- skills
Write-Step 'Skills (repo junctions)'
$skillSources = @(
    (Join-Path (Get-LayoutPath 'repos') 'pegasuz\agent-engineering\skills'),
    (Join-Path (Get-LayoutPath 'repos') 'mine\skills\skills')
)
$skillsDst = Join-Path $claudeHome 'skills'
if (-not (Test-Path $skillsDst) -and -not $script:DryRun) {
    New-Item -ItemType Directory $skillsDst -Force | Out-Null
}
# One junction per skill NAME. When two sources ship the same name, the later
# source in $skillSources wins, so a skill migrating between repos never
# flip-flops its junction within one run.
$skillDirs = [ordered]@{}
$sourcesComplete = $true
foreach ($skillsSrc in $skillSources) {
    if (-not (Test-Path $skillsSrc)) {
        Write-Warn2 "skills source not found at $skillsSrc; clone it (dev/repos), then re-run"
        $failed.Add("skills: source missing: $skillsSrc")
        $sourcesComplete = $false
        continue
    }
    foreach ($src in Get-ChildItem $skillsSrc -Directory) { $skillDirs[$src.Name] = $src }
}
foreach ($name in @($skillDirs.Keys) | Sort-Object) {
    $src = $skillDirs[$name]
    $link = Join-Path $skillsDst $name
    $existing = Get-Item $link -ErrorAction SilentlyContinue
    if ($existing -and $existing.LinkType -eq 'Junction' -and $existing.LinkTarget -eq $src.FullName) {
        Write-Ok "$name junction already in place"
        continue
    }
    if ($script:DryRun) { Write-Would "link skill $name -> $($src.FullName)"; continue }
    if ($existing) {
        Backup-ExistingFile $link | Out-Null
        Remove-Item -LiteralPath $link -Recurse -Force
    }
    New-Item -ItemType Junction -Path $link -Target $src.FullName | Out-Null
    Write-Ok "$name junction created"
    $configChanged = $true
}
# A skill renamed or absorbed upstream leaves its junction behind, pointing at a path
# that no longer exists. Removing one takes BOTH conditions: the target is gone AND the
# target sits under a declared $skillSources root. The root half is a PREFIX test on the
# target path, never a name lookup in $skillDirs - a renamed skill still points at
# <source>\<oldname>, so it is still swept, while junctions this script does not own stay
# safe even when they dangle: claude-dual-account-setup (owned by accounts\install.ps1)
# and the Orca-managed ~\.agents\skills links point outside every declared root, and
# their owners recreate them where this script never would. Anything that is not a
# junction - a real directory, a plugin's own folder - is left alone for the same reason.
#
# Accepted cost of the prefix test: rename a source REPO and its junctions stop being
# swept, their dead targets no longer sitting under any declared root. That is the case
# where a mass removal would be least welcome anyway.
#
# Caveat the prefix test does not cover: Test-Path answers $false, not an error, for a
# disconnected mapped drive or a parent that lost traverse permission, so a merely
# unreachable target reads as gone. The missing-source skip below is what keeps that from
# becoming a mass deletion - if a whole source is unavailable, no junction is swept.
#
# No backup: a junction stores a path, not content, and a dangling one's target is
# already gone, so there is nothing to copy - Backup-ExistingFile is leaf-gated and
# returns $null for any junction anyway.
if (-not $sourcesComplete) {
    Write-Warn2 'dangling junction sweep skipped - a declared skills source is missing, so every junction into it would read as dangling'
}
else {
    $sourceRoots = @($skillSources | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') + '\' })
    foreach ($live in @(Get-ChildItem $skillsDst -Force -ErrorAction SilentlyContinue)) {
        if ($live.LinkType -ne 'Junction') { continue }
        $target = $live.LinkTarget
        if (-not $target -or (Test-Path -LiteralPath $target)) { continue }
        # The trailing separator on each root is what stops a sibling like
        # ...\skills-other from counting as being under ...\skills.
        $full = [IO.Path]::GetFullPath($target)
        $underSource = @($sourceRoots |
            Where-Object { $full.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if (-not $underSource) { continue }
        if ($script:DryRun) { Write-Would "remove dangling skill junction $($live.Name) -> $target"; continue }
        try {
            Remove-Item -LiteralPath $live.FullName -Recurse -Force
            $configChanged = $true
            Write-Ok "removed dangling skill junction $($live.Name)"
        }
        catch {
            Write-Fail "could not remove dangling skill junction $($live.Name): $($_.Exception.Message)"
            $failed.Add("skill junction cleanup: $($live.Name)")
        }
    }
}

# ---------------------------------------------------------------- settings.json
Write-Step 'settings.json'
$settingsPath = Join-Path $claudeHome 'settings.json'

# _notes documents the repo's copy for a human reading it. It is not configuration and does
# not belong in the live file.
$repoSettings.Remove('_notes')

$liveSettings = @{}
if (Test-Path $settingsPath) {
    try { $liveSettings = Get-Content $settingsPath -Raw | ConvertFrom-Json -AsHashtable }
    catch {
        Write-Warn2 "live settings.json is invalid JSON and will not be merged: $($_.Exception.Message)"
    }
}

$merged = @{}
$discarded = [System.Collections.Generic.List[string]]::new()
foreach ($k in $liveSettings.Keys) {
    if ($k -eq 'hooks' -and -not (Test-HooksShape $liveSettings[$k])) {
        $discarded.Add('hooks (legacy/invalid shape)')
        continue
    }
    $merged[$k] = $liveSettings[$k]
}
foreach ($k in $repoSettings.Keys) { $merged[$k] = $repoSettings[$k] }

# Repo-managed hooks MERGE into the live hooks key instead of replacing it:
# Orca injects its own hook entries into the live file at runtime and they
# must survive every install. `${CLAUDE_HOME}` in hook commands resolves to
# the absolute ~/.claude path HERE — the hook runner's shell is not cmd and
# expands no %VARS%, so the stored command must need no expansion at all
# (learned from the 2026-08-18 session-start failure). Repo-owned entries
# are recognized by the .ps1 script file they call and REPLACED in place,
# so a command or timeout edit propagates and stale variants never
# accumulate; Orca-injected hooks reference no repo script and are never
# touched.
$repoHooksPath = Join-Path $PSScriptRoot 'hooks.json'
if (Test-Path $repoHooksPath) {
    $repoHooksRaw = (Get-Content $repoHooksPath -Raw).Replace('${CLAUDE_HOME}', ($claudeHome -replace '\\', '/'))
    $repoHooks = $repoHooksRaw | ConvertFrom-Json -AsHashtable
    $mergedHooks = if ($merged.ContainsKey('hooks') -and (Test-HooksShape $merged['hooks'])) { $merged['hooks'] } else { @{} }
    foreach ($eventName in $repoHooks.Keys) {
        $entries = [System.Collections.Generic.List[object]]::new()
        if ($mergedHooks.ContainsKey($eventName)) {
            foreach ($e in $mergedHooks[$eventName]) { $entries.Add($e) }
        }
        foreach ($wanted in $repoHooks[$eventName]) {
            $wantedScripts = @($wanted.hooks | ForEach-Object {
                    if ($_.command -match '([\w.-]+\.ps1)') { $Matches[1] }
                } | Where-Object { $_ })
            $kept = [System.Collections.Generic.List[object]]::new()
            foreach ($e in $entries) {
                $ownedByRepo = $false
                foreach ($h in $e.hooks) {
                    foreach ($s in $wantedScripts) {
                        if ($h.command -like "*$s*") { $ownedByRepo = $true }
                    }
                }
                if (-not $ownedByRepo) { $kept.Add($e) }
            }
            $kept.Add($wanted)
            $entries = $kept
        }
        $mergedHooks[$eventName] = $entries.ToArray()
    }
    $merged['hooks'] = $mergedHooks
}

# User-directory skills load normally: the standard's skills (Agent-Engineering repo) are
# designed for automatic triggering, so no skillOverrides are generated anymore.
$merged.Remove('skillOverrides')

$kept = @($liveSettings.Keys | Where-Object {
        -not $repoSettings.ContainsKey($_) -and $_ -notin @('hooks', 'skillOverrides')
    })
if ($kept.Count) { Write-Host "  keeping $($kept.Count) key(s) this repo doesn't manage: $($kept -join ', ')" -ForegroundColor DarkGray }
if ($discarded.Count) {
    Write-Warn2 "not preserving invalid live setting(s): $($discarded -join ', ')"
    Write-Host '         The complete old file is backed up before the repaired one is written.' -ForegroundColor DarkGray
}

$json = ((ConvertTo-Sorted $merged) | ConvertTo-Json -Depth 100) + "`n"
$settingsNeedsWrite = -not (Test-Path $settingsPath -PathType Leaf) -or
    ((Get-Content $settingsPath -Raw) -cne $json)
$settingsInstalled = Install-ConfigText -Destination $settingsPath -Text $json -Label 'settings.json'
if (-not $settingsInstalled) {
    $failed.Add('settings.json')
}
else {
    if ($settingsNeedsWrite -and -not $script:DryRun) { $configChanged = $true }
}
if ($settingsInstalled -and -not $script:DryRun -and $hasClaude) {
    $doctor = & claude.exe doctor 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $doctor -match '(?m)^Invalid settings') {
        Write-Fail 'Claude rejected the resulting settings.json; run: claude doctor'
        $failed.Add('settings.json validation')
    }
    else { Write-Ok 'claude doctor accepted settings.json' }
}

# ---------------------------------------------------------------- MCP
Write-Step 'MCP servers'
if (-not $Secrets) {
    Write-Skip 'user-scope MCP sync skipped - pass -Secrets to apply it'
    Write-Host '         It contains API keys, so it is never changed by accident.' -ForegroundColor DarkGray
}
else {
    $envFile = Join-Path $PSScriptRoot '..\secrets\.env'
    if (-not (Test-Path $envFile)) {
        Write-Warn2 'secrets\.env is missing. Copy secrets\.env.example and fill it in.'
        $failed.Add('secrets\.env')
    }
    else {
        $vars = @{}
        foreach ($line in Get-Content $envFile) {
            if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
            $i = $line.IndexOf('=')
            $vars[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim().Trim('"')
        }

        # Installer-derived paths are machine state, not secrets. Keep Memory's graph out
        # of npx's package/cache directory so an npm cache cleanup or package update cannot
        # silently erase it.
        $vars['LAYOUT_REPOS'] = Get-LayoutPath 'repos'
        $vars['CLAUDE_MEMORY_FILE'] = Join-Path $claudeHome 'mcp-memory.jsonl'

        $templateText = Get-Content (Join-Path $PSScriptRoot 'mcp.template.json') -Raw
        $required = @([regex]::Matches($templateText, '\$\{([A-Za-z_][A-Za-z0-9_]*)\}') |
                ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $missing = @($required | Where-Object {
                -not $vars.ContainsKey($_) -or [string]::IsNullOrWhiteSpace([string]$vars[$_])
            })
        if ($missing) {
            Write-Warn2 "$($missing.Count) placeholder(s) with no value in secrets\.env: $($missing -join ', ')"
            Write-Host '         No MCP configuration was changed.' -ForegroundColor DarkGray
            $failed.Add('MCP placeholders')
        }
        elseif (-not $hasClaude) {
            Write-Warn2 'claude.exe is missing - cannot apply user-scope MCP servers'
            $failed.Add('claude.exe')
        }
        else {
            # Resolve placeholders as values inside the parsed object, then serialize. This
            # correctly escapes quotes and backslashes inside credentials and paths.
            function Resolve-TemplateValue {
                param($Value)
                if ($Value -is [System.Collections.IDictionary]) {
                    $out = [ordered]@{}
                    foreach ($k in $Value.Keys) { $out[$k] = Resolve-TemplateValue $Value[$k] }
                    return $out
                }
                if ($Value -is [object[]] -or $Value -is [System.Collections.IList]) {
                    return @($Value | ForEach-Object { Resolve-TemplateValue $_ })
                }
                if ($Value -is [string]) {
                    if ($Value -match '^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$') { return [string]$vars[$Matches[1]] }
                    $text = $Value
                    foreach ($k in $vars.Keys) { $text = $text.Replace('${' + $k + '}', [string]$vars[$k]) }
                    return $text
                }
                return $Value
            }

            $template = $templateText | ConvertFrom-Json -AsHashtable
            $desiredServers = (Resolve-TemplateValue $template).mcpServers
            $userJsonPath = Join-Path $HOME '.claude.json'
            $userState = @{}
            if (Test-Path $userJsonPath) {
                try { $userState = Get-Content $userJsonPath -Raw | ConvertFrom-Json -AsHashtable }
                catch {
                    Write-Fail "~/.claude.json is invalid JSON; no MCP server was changed"
                    $failed.Add('~/.claude.json')
                }
            }
            $currentServers = if ($userState.mcpServers) { $userState.mcpServers } else { @{} }

            # Claude normalizes stdio entries by adding type=stdio and sometimes env={}. Do
            # not remove/re-add a server on every run solely because of those CLI defaults.
            function Get-ComparableMcpJson {
                param($Server)
                $copy = @{}
                foreach ($key in $Server.Keys) { $copy[$key] = $Server[$key] }
                if ($copy.type -eq 'stdio') { $copy.Remove('type') }
                if ($copy.env -is [System.Collections.IDictionary] -and $copy.env.Count -eq 0) {
                    $copy.Remove('env')
                }
                return (ConvertTo-Sorted $copy) | ConvertTo-Json -Depth 100 -Compress
            }

            $userJsonExisted = Test-Path $userJsonPath
            $userJsonBackup = $null
            $mcpMigrationComplete = -not ($failed -contains '~/.claude.json')
            foreach ($name in @($desiredServers.Keys)) {
                if ($failed -contains '~/.claude.json') { break }
                $wantJson = (ConvertTo-Sorted $desiredServers[$name]) | ConvertTo-Json -Depth 100 -Compress
                $haveJson = if ($currentServers.ContainsKey($name)) {
                    Get-ComparableMcpJson $currentServers[$name]
                }
                else { $null }

                $wantComparable = Get-ComparableMcpJson $desiredServers[$name]
                if ($haveJson -ceq $wantComparable) { Write-Skip "$name already configured at user scope"; continue }
                if ($script:DryRun) {
                    Write-Would "$(if ($haveJson) { 'update' } else { 'add' }) user-scope MCP server $name"
                    continue
                }

                if (-not $userJsonBackup -and (Test-Path $userJsonPath)) {
                    $userJsonBackup = Backup-ExistingFile $userJsonPath
                }
                if ($haveJson) {
                    & claude.exe mcp remove --scope user $name 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        Write-Fail "$name could not be removed before update"
                        $failed.Add("MCP: $name")
                        if ($userJsonBackup) {
                            Copy-Item -LiteralPath $userJsonBackup -Destination $userJsonPath -Force
                            Write-Warn2 'restored the pre-run ~/.claude.json after the MCP failure'
                        }
                        $mcpMigrationComplete = $false
                        break
                    }
                }

                & claude.exe mcp add-json --scope user $name $wantJson 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Ok "$name configured at user scope"
                    $configChanged = $true
                }
                else {
                    Write-Fail "$name could not be configured"
                    $failed.Add("MCP: $name")
                    if ($userJsonBackup) {
                        Copy-Item -LiteralPath $userJsonBackup -Destination $userJsonPath -Force
                        Write-Warn2 'restored the pre-run ~/.claude.json after the MCP failure'
                    }
                    elseif (-not $userJsonExisted -and (Test-Path $userJsonPath)) {
                        Remove-Item -LiteralPath $userJsonPath -Force
                        Write-Warn2 'removed the partial ~/.claude.json created by this run'
                    }
                    $mcpMigrationComplete = $false
                    break
                }
            }

            # Older Claude versions and OMC used this path. Current Claude Code ignores it;
            # once the user-scope migration succeeds, remove the plaintext duplicate.
            $legacyMcpPath = Join-Path $claudeHome 'mcp-configs\mcp-servers.json'
            if ($mcpMigrationComplete -and (Test-Path $legacyMcpPath)) {
                if ($script:DryRun) { Write-Would "archive and remove obsolete $legacyMcpPath" }
                else {
                    Backup-ExistingFile $legacyMcpPath | Out-Null
                    Remove-Item -LiteralPath $legacyMcpPath -Force
                    $configChanged = $true
                    Write-Ok 'obsolete mcp-configs/mcp-servers.json removed after migration'
                }
            }
        }
    }
}

# ---------------------------------------------------------------- manual
Write-Step 'Left to do by hand'
foreach ($row in Get-RowsFromReadme (Join-Path $PSScriptRoot 'README.md') @('What stays manual')) {
    Write-Host "         $row" -ForegroundColor DarkGray
}
# Claude Code stores user-scope MCP servers in ~/.claude.json. The CLI owns writes to that
# file; this report only calls out entries not declared by the template.
$userJson = Join-Path $HOME '.claude.json'
if (Test-Path $userJson) {
    try {
        $u = Get-Content $userJson -Raw | ConvertFrom-Json -AsHashtable
        $manifest = Get-Content (Join-Path $PSScriptRoot 'mcp.template.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $declared = @($manifest.mcpServers.Keys) + @($manifest.externalServers)
        $unexpected = @($u.mcpServers.Keys | Where-Object { $_ -and $_ -notin $declared })
        if ($unexpected.Count) {
            Write-Host ''
            Write-Warn2 "$($unexpected.Count) undeclared user-scope MCP server(s), preserved but not managed here:"
            Write-Host "         $($unexpected -join ', ')" -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Warn2 "could not inspect ~/.claude.json: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------- summary
Write-Step 'Summary'
if ($failed.Count) {
    Write-Host ''
    Write-Fail "$($failed.Count) didn't complete:"
    foreach ($f in $failed) { Write-Host "         $f" -ForegroundColor Red }
    Write-Host ''
    Write-Host '  Re-running is safe and skips everything that already worked.' -ForegroundColor DarkGray
    Write-Host ''
    exit 1
}

Write-Ok 'nothing failed'
Write-Host ''
if ($script:DryRun) { Write-Host '  Dry run complete; no Claude files changed.' -ForegroundColor DarkGray }
elseif ($configChanged) { Write-Host '  Restart Claude Code for the changes to take effect.' -ForegroundColor DarkGray }
else { Write-Host '  Claude configuration was already current.' -ForegroundColor DarkGray }
Write-Host ''
exit 0
