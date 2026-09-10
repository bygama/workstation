<#
.SYNOPSIS
    Phase 6. LTSC-like Windows 11 Pro profile: shell, privacy, Edge, services, and power.

.DESCRIPTION
    Runs LAST, because it restarts Explorer.

    Split by privilege on purpose. Everything under HKCU is per-user and needs no
    elevation; the machine-wide settings under HKLM do. Without admin the script applies
    the HKCU half, reports the unapplied settings, and exits 1 so an incomplete restore
    cannot look successful.

    Reports every change as old -> new so you can put anything back by hand.

.PARAMETER SkipExplorerRestart
    Apply the settings but don't restart Explorer. They take effect at next sign-in.

.PARAMETER WhatIfOnly
    Print what would change and exit.

.EXAMPLE
    pwsh windows\install.ps1              # HKCU only if not elevated
    # elevated, for the full set:
    Start-Process pwsh -Verb RunAs -ArgumentList '-File windows\install.ps1'
#>
[CmdletBinding()]
param(
    [switch]$SkipExplorerRestart,
    [switch]$WhatIfOnly
)

. "$PSScriptRoot\..\_lib.ps1"
Assert-PowerShell7

$admin = Test-Admin
$edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
$build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild

Write-Step "Phase 6 - Windows"
Write-Host "  edition $edition  ·  build $build  ·  $(if ($admin) { 'elevated' } else { 'NOT elevated' })"
if ($edition -like '*Eval*') {
    Write-Warn2 "This is an Evaluation SKU - 90 days, then hourly reboots. See usb.md."
}

$changed = 0
$skipped = 0
$already = 0
$planned = 0
$failed = [System.Collections.Generic.List[string]]::new()
$needsElevation = [System.Collections.Generic.List[string]]::new()

# Set a registry value, reporting old -> new. Idempotent.
function Set-Reg {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        # AllowEmptyString: a REG_SZ whose desired data is '' is a real setting (the classic
        # context menu key), and Mandatory alone rejects it at binding time.
        [Parameter(Mandatory)][AllowEmptyString()]$Value,
        [string]$Type = 'DWord',
        [string]$What
    )
    $pathExists = Test-Path $Path
    $old = if ($pathExists) {
        (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    }
    else { $null }
    if ($old -eq $Value) { Write-Skip "$What (already $Value)"; $script:already++; return }

    # HKLM is machine state. HKCU\Software\Policies is the per-user POLICY hive, and Windows
    # ACLs it to SYSTEM/Administrators precisely so an unelevated user cannot set policies on
    # themselves - so both belong to the elevated pass.
    $requiresAdmin = -not $admin -and
        ($Path -like 'HKLM:*' -or $Path -like 'HKCU:\SOFTWARE\Policies\*')
    if ($WhatIfOnly) {
        if (-not $pathExists) { Write-Host "  would create $Path" -ForegroundColor DarkGray }
        $adminNote = if ($requiresAdmin) { ' [requires elevation]' } else { '' }
        Write-Host "  would set $What : $(if ($null -eq $old) { '(unset)' } else { $old }) -> $Value$adminNote" -ForegroundColor DarkGray
        $script:planned++
        return
    }
    if ($requiresAdmin) {
        Write-Skip "$What - needs admin"
        $script:skipped++
        $script:needsElevation.Add($What)
        return
    }
    # A denied write must degrade to one named failure, not a terminating error that costs
    # every setting after it - the same collect-and-continue contract the folders follow.
    try {
        if (-not $pathExists) { New-Item -Path $Path -Force | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type
    }
    catch {
        Write-Warn2 "$What - $($_.Exception.Message)"
        $script:failed.Add($What)
        return
    }
    Write-Ok "$What : $(if ($null -eq $old) { '(unset)' } else { $old }) -> $Value"
    $script:changed++
}

# Disable only a short, explicitly chosen service set. Missing services are skipped rather
# than created: service names change between Windows builds, and a fake registry-only service
# entry is worse than leaving a new build at its default.
function Disable-ServiceIfPresent {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$What
    )
    $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path $path)) { Write-Skip "$What - service not present"; $script:already++; return }
    Set-Reg $path 'Start' 4 -What "$What service disabled"
}

# Scheduled-task names move between Windows builds. Disable only known diagnostic tasks and
# treat an absent task as an already-satisfied end state.
function Disable-ScheduledTaskIfPresent {
    param(
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$What
    )
    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { Write-Skip "$What - task not present"; $script:already++; return }
    if ($task.State -eq 'Disabled') { Write-Skip "$What - already disabled"; $script:already++; return }

    if ($WhatIfOnly) {
        $adminNote = if (-not $admin) { ' [requires elevation]' } else { '' }
        Write-Host "  would disable $What$adminNote" -ForegroundColor DarkGray
        $script:planned++
        return
    }
    if (-not $admin) {
        Write-Skip "$What - needs admin"
        $script:skipped++
        $script:needsElevation.Add($What)
        return
    }

    try {
        Disable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
        Write-Ok "$What disabled"
        $script:changed++
    }
    catch {
        Write-Warn2 "$What - $($_.Exception.Message)"
        $script:failed.Add($What)
    }
}

# Turn a declared exclusion key into a real path. Keys, not literals: `C:\Briar\repos` is
# written down once, in layout\LAYOUT.md, and a second copy inside a README is a copy that
# drifts the day a folder moves. `home:` covers the paths a vendor owns under the profile,
# which LAYOUT.md deliberately does not describe.
function Resolve-ExclusionPath {
    param([Parameter(Mandatory)][string]$Key)
    if ($Key -match '^layout:(.+)$') { return Get-LayoutPath $Matches[1] }
    if ($Key -match '^home:(.+)$') { return Join-Path $HOME $Matches[1] }
    throw "unknown exclusion key prefix: $Key"
}

# ================================================================ Explorer (per-user)
Write-Step 'Explorer'
$adv = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

Set-Reg $adv 'HideFileExt'          0 -What 'show file extensions'
Set-Reg $adv 'Hidden'               1 -What 'show hidden files'
Set-Reg $adv 'LaunchTo'             1 -What 'open to This PC'
Set-Reg $adv 'ShowTaskViewButton'   0 -What 'hide Task View button'
Set-Reg $adv 'TaskbarDa'            0 -What 'hide Widgets'
Set-Reg $adv 'TaskbarMn'            0 -What 'hide Chat'
Set-Reg $adv 'TaskbarAl'            0 -What 'taskbar aligned left'
Set-Reg $adv 'ShowSyncProviderNotifications' 0 -What 'hide Explorer sync-provider promotions'
Set-Reg $adv 'Start_IrisRecommendations' 0 -What 'hide Start recommendations'

Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 0 `
    -What 'hide taskbar search box'

# The Windows 10 full context menu. An empty per-user InprocServer32 under this CLSID makes
# the Windows 11 condensed-menu handler fail to load, so Explorer falls back to the classic
# menu after its next restart. Delete the key to return to the Windows 11 default.
Set-Reg 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' `
    '(Default)' '' -Type String -What 'classic Windows 10 context menu'

# ================================================================ Regional format (per-user)
Write-Step 'Regional format'
# Dates render day/month/year regardless of the display language's default. iDate is the
# legacy order flag some Win32 apps still read; Windows keeps it in step with sShortDate.
$intl = 'HKCU:\Control Panel\International'
Set-Reg $intl 'sShortDate' 'dd/MM/yyyy' -Type String -What 'short date as day/month/year'
Set-Reg $intl 'sLongDate' 'dddd, d MMMM yyyy' -Type String -What 'long date as day month year'
Set-Reg $intl 'iDate' '1' -Type String -What 'legacy date order day-first'

# ================================================================ Consumer surfaces
Write-Step 'Consumer surfaces'
$content = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
Set-Reg $content 'ContentDeliveryAllowed'          0 -What 'consumer content disabled'
Set-Reg $content 'OemPreInstalledAppsEnabled'      0 -What 'OEM suggested apps disabled'
Set-Reg $content 'PreInstalledAppsEnabled'         0 -What 'suggested preinstalled apps disabled'
Set-Reg $content 'PreInstalledAppsEverEnabled'     0 -What 'suggested app history disabled'
Set-Reg $content 'SilentInstalledAppsEnabled'      0 -What 'silent suggested-app installs disabled'
Set-Reg $content 'SoftLandingEnabled'              0 -What 'Windows tips and soft landing disabled'
Set-Reg $content 'SystemPaneSuggestionsEnabled'    0 -What 'Settings suggestions disabled'
Set-Reg $content 'RotatingLockScreenEnabled'       0 -What 'Windows Spotlight lock screen disabled'
Set-Reg $content 'RotatingLockScreenOverlayEnabled' 0 -What 'lock-screen promotions disabled'

Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0 `
    -What 'advertising ID disabled'
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy' `
    'TailoredExperiencesWithDiagnosticDataEnabled' 0 -What 'tailored experiences disabled'
Set-Reg 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' `
    'DisableTailoredExperiencesWithDiagnosticData' 1 -What 'tailored-experience policy disabled'

Set-Reg 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1 `
    -What 'File Explorer search-history suggestions disabled'

$searchPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'
Set-Reg $searchPolicy 'AllowCloudSearch'         0 -What 'cloud search disabled'
Set-Reg $searchPolicy 'EnableDynamicContentInWSB' 0 -What 'search highlights disabled'

Set-Reg $adv 'Start_TrackProgs' 0 -What 'app-launch tracking disabled'

$activityPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
Set-Reg $activityPolicy 'PublishUserActivities' 0 -What 'activity-history publishing disabled'
Set-Reg $activityPolicy 'UploadUserActivities'  0 -What 'activity-history upload disabled'

$aiPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'
Set-Reg $aiPolicy 'DisableAIDataAnalysis' 1 -What 'Recall snapshots disabled'
Set-Reg $aiPolicy 'DisableClickToDo'      1 -What 'Click to Do disabled where supported'

# No Widgets policy row on purpose. Current builds ACL HKLM\...\Policies\Microsoft\Dsh to
# SYSTEM only, so even an elevated run cannot write AllowNewsAndInterests - an unenforceable
# row only guarantees a permanent failure. The Widgets outcome is owned by debloat.ps1
# (StartExperiencesApp, WidgetsPlatformRuntime, WebExperience Pack) plus TaskbarDa above.
Set-Reg 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 `
    -What 'Windows Copilot disabled'

# ================================================================ Edge
Write-Step 'Edge compatibility shell'
Write-Host '  Edge stays installed for Windows/WebView2 compatibility, but does not preload.' -ForegroundColor DarkGray
$edgePolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
Set-Reg $edgePolicy 'BackgroundModeEnabled'         0 -What 'Edge background mode disabled'
Set-Reg $edgePolicy 'StartupBoostEnabled'           0 -What 'Edge startup boost disabled'
Set-Reg $edgePolicy 'HideFirstRunExperience'         1 -What 'Edge first-run promotion hidden'
Set-Reg $edgePolicy 'DefaultBrowserSettingEnabled'   0 -What 'Edge default-browser prompt disabled'
Set-Reg $edgePolicy 'DiagnosticData'                  0 -What 'Edge diagnostic data disabled'
Set-Reg $edgePolicy 'UrlDiagnosticDataEnabled'        0 -What 'Edge URL diagnostic data disabled'
Set-Reg $edgePolicy 'PersonalizationReportingEnabled' 0 -What 'Edge personalization reporting disabled'

# ================================================================ Fast Startup
Write-Step 'Fast Startup'
Write-Host "  Hibernated shutdowns leave NTFS locked, stop driver and BIOS updates from" -ForegroundColor DarkGray
Write-Host "  applying on 'shut down', and confuse WSL2 and Docker. Off on a dev machine." -ForegroundColor DarkGray

Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0 `
    -What 'Fast Startup disabled'

# ================================================================ Sign-in
Write-Step 'Sign-in'
Write-Host '  Passwordless is the account model, chosen by hand - README § Local account and' -ForegroundColor DarkGray
Write-Host '  sign-in. Nothing here touches accounts, credentials, or autologon; this only' -ForegroundColor DarkGray
Write-Host '  skips the lock-screen curtain so a passwordless profile lands on the desktop.' -ForegroundColor DarkGray
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' 'NoLockScreen' 1 `
    -What 'lock-screen curtain skipped'

# ================================================================ Telemetry
Write-Step 'Telemetry'
$telemetryLevel = if ($edition -match 'Enterprise|Education|Server|IoT') { 0 } else { 1 }
$telemetryLabel = if ($telemetryLevel -eq 0) { 'diagnostic data off' } else { 'diagnostic data at Required (minimum supported by Pro)' }
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' $telemetryLevel `
    -What $telemetryLabel
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'LimitDiagnosticLogCollection' 1 `
    -What 'optional diagnostic log collection limited'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'LimitDumpCollection' 1 `
    -What 'optional diagnostic dump collection limited'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1 `
    -What 'diagnostic feedback prompts disabled'

# Keep Windows Update and Store transport intact, but never upload update payloads to peers.
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0 `
    -What 'Delivery Optimization set to HTTP only (peer-to-peer disabled)'

# ================================================================ Unused integrations
Write-Step 'Unused integrations'
Write-Host '  Xbox, notifications, Bluetooth, Search, SysMain, printing, Defender, and Update stay.' -ForegroundColor DarkGray
Disable-ServiceIfPresent 'WbioSrvc'  'Windows biometrics'
Disable-ServiceIfPresent 'lfsvc'     'geolocation'
Disable-ServiceIfPresent 'MapsBroker' 'downloaded maps'
Disable-ServiceIfPresent 'PhoneSvc'  'phone integration'
Disable-ServiceIfPresent 'CDPUserSvc' 'cross-device platform'
Disable-ServiceIfPresent 'DiagTrack' 'connected diagnostics and telemetry'
Disable-ServiceIfPresent 'dmwappushservice' 'diagnostic WAP push messaging'

Write-Step 'Diagnostic scheduled tasks'
Disable-ScheduledTaskIfPresent '\Microsoft\Windows\Application Experience\' `
    'Microsoft Compatibility Appraiser' 'compatibility telemetry appraiser'
Disable-ScheduledTaskIfPresent '\Microsoft\Windows\Application Experience\' `
    'Microsoft Compatibility Appraiser Exp' 'experimental compatibility telemetry appraiser'
Disable-ScheduledTaskIfPresent '\Microsoft\Windows\Application Experience\' `
    'ProgramDataUpdater' 'program compatibility inventory'
Disable-ScheduledTaskIfPresent '\Microsoft\Windows\Application Experience\' `
    'StartupAppTask' 'startup compatibility inventory'
Disable-ScheduledTaskIfPresent '\Microsoft\Windows\Customer Experience Improvement Program\' `
    'Consolidator' 'customer-experience telemetry consolidator'
Disable-ScheduledTaskIfPresent '\Microsoft\Windows\Customer Experience Improvement Program\' `
    'UsbCeip' 'USB customer-experience telemetry'
Disable-ScheduledTaskIfPresent '\Microsoft\Windows\DiskDiagnostic\' `
    'Microsoft-Windows-DiskDiagnosticDataCollector' 'disk diagnostic data collector'
Disable-ScheduledTaskIfPresent '\Microsoft\Windows\Autochk\' `
    'Proxy' 'disk auto-check telemetry proxy'

# ================================================================ Scanner exclusions
Write-Step 'Scanner exclusions'
Write-Host '  Defender stays on, real-time protection included. What goes is real-time' -ForegroundColor DarkGray
Write-Host '  scanning of the development roots: an npm install writes tens of thousands of' -ForegroundColor DarkGray
Write-Host '  short-lived files and MsMpEng reads every one. README has the list and its cost.' -ForegroundColor DarkGray

if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) {
    Write-Skip 'Microsoft Defender cmdlets are not present - nothing to exclude'
    $already++
}
else {
    # Reading the current list needs admin as much as writing it, so an unelevated run
    # cannot tell "already excluded" from "not excluded yet". It reports the whole declared
    # set as pending, which is the honest answer rather than a guess.
    $excluded = if ($admin) { @((Get-MpPreference).ExclusionPath) } else { @() }
    foreach ($key in Get-IdsFromReadme "$PSScriptRoot\README.md" @('Scanner exclusions')) {
        $path = Resolve-ExclusionPath $key
        $what = "scanner exclusion $path"

        # A path that does not exist yet is still declared: orca\workspaces appears the
        # first time a worktree is created, and the exclusion has to be there before it is.
        if ($admin -and @($excluded | Where-Object { $_.TrimEnd('\') -eq $path.TrimEnd('\') })) {
            Write-Skip "$what (already excluded)"
            $already++
            continue
        }
        if ($WhatIfOnly) {
            Write-Host "  would add $what$(if (-not $admin) { ' [requires elevation]' })" -ForegroundColor DarkGray
            $planned++
            continue
        }
        if (-not $admin) {
            Write-Skip "$what - needs admin"
            $skipped++
            $needsElevation.Add($what)
            continue
        }
        try {
            Add-MpPreference -ExclusionPath $path -ErrorAction Stop
            # Tamper Protection can accept the call and leave the list untouched, so the
            # exclusion counts as applied only once Defender reads it back.
            $confirmed = @((Get-MpPreference).ExclusionPath) |
                Where-Object { $_.TrimEnd('\') -eq $path.TrimEnd('\') }
            if (-not $confirmed) {
                throw 'Defender did not report the path afterwards - add it by hand in Windows Security'
            }
            Write-Ok "$what added"
            $changed++
        }
        catch {
            Write-Warn2 "$what - $($_.Exception.Message)"
            $failed.Add($what)
        }
    }
}

# ================================================================ Power
Write-Step 'Power'
$BALANCED = '381b4222-f694-41f0-9685-ff5bb260df2e'
if ($WhatIfOnly) {
    Write-Host '  would set the Balanced power scheme' -ForegroundColor DarkGray
    Write-Host '  would disable sleep and hibernation on AC power' -ForegroundColor DarkGray
    $planned += 3
}
else {
    $active = (powercfg /getactivescheme) -replace '.*GUID: ([a-f0-9-]+).*', '$1'
    if ($active -eq $BALANCED) { Write-Skip 'already on Balanced'; $already++ }
    else {
        powercfg /setactive $BALANCED 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'power scheme -> Balanced'; $changed++ }
        else {
            Write-Warn2 'could not switch to the built-in Balanced scheme'
            $failed.Add('Balanced power scheme')
        }
    }
    # A desktop should never sleep the disks out from under Docker.
    powercfg /change standby-timeout-ac 0 2>&1 | Out-Null
    $standbyCode = $LASTEXITCODE
    powercfg /change hibernate-timeout-ac 0 2>&1 | Out-Null
    $hibernateCode = $LASTEXITCODE
    if ($standbyCode -eq 0 -and $hibernateCode -eq 0) {
        Write-Ok 'sleep and hibernate disabled on AC'
    }
    else {
        Write-Warn2 "could not disable AC sleep/hibernate (standby=$standbyCode, hibernate=$hibernateCode)"
        $failed.Add('AC sleep/hibernate')
    }
}

# ================================================================ Media Feature Pack
Write-Step 'Media Feature Pack'
if ($edition -notmatch 'N$|NEval$') {
    Write-Skip "not an N edition - nothing to add"
    $already++
}
elseif ($WhatIfOnly) {
    Write-Host "  would add Media.MediaFeaturePack$(if (-not $admin) { ' [requires elevation]' })" -ForegroundColor DarkGray
    $planned++
}
elseif (-not $admin) {
    Write-Skip 'N edition detected but needs admin'
    $skipped++
    $needsElevation.Add('Media Feature Pack')
}
else {
    Write-Warn2 "N edition - no Media Foundation. Video/audio playback, screen sharing in"
    Write-Warn2 "Teams/Zoom/Discord, Electron apps and WSLg all break without this."
    $cap = Get-WindowsCapability -Online -Name 'Media.MediaFeaturePack*' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($cap -and $cap.State -eq 'Installed') { Write-Skip 'already installed' }
    elseif ($cap) {
        Add-WindowsCapability -Online -Name $cap.Name
        Write-Ok $cap.Name
        $changed++
    }
    else { Write-Warn2 'capability not offered - needs Windows Update reachable, or the FoD ISO' }
}

# ================================================================ wrap up
Write-Step 'Done'
if ($WhatIfOnly) {
    Write-Host "  $planned planned · $already already satisfied"
}
else {
    Write-Host "  $changed changed · $already already satisfied · $skipped need elevation"
}

if ($skipped -gt 0 -and -not $admin) {
    Write-Host ''
    Write-Warn2 "$skipped machine-wide setting(s) skipped. For those, re-run elevated:"
    Write-Host "    Start-Process pwsh -Verb RunAs -ArgumentList '-File $PSCommandPath'" -ForegroundColor White
}

if ($WhatIfOnly) { exit 0 }

if ($SkipExplorerRestart) {
    Write-Warn2 'Explorer not restarted - changes apply at next sign-in'
}
elseif ($changed -gt 0) {
    Write-Host ''
    Write-Host '  restarting Explorer...' -ForegroundColor DarkYellow
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer }
    Write-Ok 'Explorer restarted'
}

Write-Host ''
Write-Warn2 'Fast Startup, privacy policies, disabled services, and tasks need a reboot to fully take effect.'
Write-Host ''

if ($failed.Count) {
    Write-Fail "$($failed.Count) Windows step(s) failed: $($failed -join ', ')"
    exit 1
}
if ($needsElevation.Count) {
    Write-Fail "$($needsElevation.Count) machine-wide setting(s) remain unapplied; re-run elevated"
    exit 1
}
exit 0
