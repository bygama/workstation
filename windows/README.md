# Windows

Target operating system: Windows 11 Pro. This folder owns the operating-system layer rather
than application configuration.

| File | Use |
| --- | --- |
| `usb.md` | Optional recovery-media fallback when Windows recovery cannot be used |
| `bootstrap.ps1` | PowerShell 5.1 fallback for missing winget, PowerShell 7, and Developer Mode |
| `audit.ps1` | Read-only before/after process, service, startup, AppX, and policy report |
| `install.ps1` | User UI/privacy settings, scanner exclusions, and power-plan configuration |
| `debloat.ps1` | Explicit removal of selected inbox applications |

## Reinstall from the PC

The normal path does not need a USB: Settings → System → Recovery → Reset this PC → Remove
everything → Cloud download. Do not restore manufacturer applications if Windows offers that
choice. Complete [`docs/pre-format.md`](../docs/pre-format.md) first. Use `usb.md` only when
Windows recovery fails, the machine cannot boot, or the target disk must be repartitioned
manually.

## Local account and sign-in

Prefer a local account during setup when Windows offers it. If Cloud reset requires a
Microsoft account, complete setup with it, then create a local administrator under Settings
→ Accounts → Other users → Add account → I don't have this person's sign-in information →
Add a user without a Microsoft account. Leave the password fields blank for the chosen
passwordless local profile.

Sign into the new local account, verify that it is an administrator and that its files are
correct, then remove the temporary Microsoft-linked account if it is no longer wanted. Skip
or remove Windows Hello PIN and biometric methods under Settings → Accounts → Sign-in
options. The installer disables the biometric service, but it never creates accounts,
enables automatic logon, stores credentials, or changes passwords.

If the restore already ran while signed into a Microsoft account, do not create a second
profile: Settings → Accounts → Your info → "Sign in with a local account instead" converts
the existing account in place — same SID, same `C:\Users` folder, every restored setting
kept. Leave the new password blank and remove the Windows Hello PIN afterwards. The
installer's only sign-in change is skipping the lock-screen curtain by policy, so a
passwordless profile boots straight to the desktop.

## Bootstrap

Windows 11 normally provides winget through App Installer. If `Get-Command winget` returns
nothing before the repository is cloned, update **App Installer** from Microsoft Store and
open a new terminal. If the repository was obtained as a ZIP and winget still does not
register, run this from elevated Windows PowerShell 5.1:

```powershell
powershell -ExecutionPolicy Bypass -File windows\bootstrap.ps1
```

This is the only PowerShell 5.1 script in the repo because it may run before PowerShell 7
exists. It obtains the current winget release and dependencies, installs PowerShell 7, and
enables Developer Mode unless `-SkipDevMode` is passed.

## Post-format order

1. Finish Windows Update and hardware-driver installation, including every required reboot.
2. Establish the local administrator profile and sign-in choices described above.
3. Clone this repository. Close browsers, Claude, launchers, and other applications; wait
   five to ten minutes after boot, then capture `pwsh windows\audit.ps1 -Label stock`.
4. Run the root restore with `-WhatIfOnly`, then for real. Reboot whenever it stops for a
   pending restart, and continue until all six phases complete.
5. Run the elevated `windows\install.ps1` command printed by the final phase, then reboot.
6. Review debloat with `-List` and `-WhatIfOnly`, then perform the current-user removal and
   reboot.
7. Capture `pwsh windows\audit.ps1 -Label optimized` under the same idle conditions.
8. Review startup applications manually, reboot, and take a final audit if any are changed.

Audit JSON is written to `%LOCALAPPDATA%\workstation-audits`. The command itself adds a
PowerShell and terminal process, so compare reports captured in the same way rather than
treating one process count as an absolute score. It records names and counts but omits
process and startup command lines to avoid collecting secrets.

## System configuration

```powershell
pwsh windows\install.ps1 -WhatIfOnly
Start-Process pwsh -Verb RunAs -ArgumentList '-File windows\install.ps1'
```

The script applies current-user Explorer/taskbar preferences, the classic Windows 10
right-click menu, and the day/month/year regional date format, sets Windows diagnostic
data to the minimum supported by Pro, disables the selected diagnostic services and scheduled
tasks, removes consumer surfaces, leaves Edge installed but idle, excludes the declared development
roots from Defender's real-time scanning (§ Scanner exclusions), and uses the built-in
Balanced power scheme. AC standby and hibernation remain disabled for long development,
Docker, and game sessions. Explorer restarts only after a real run.

Delivery Optimization is set to HTTP-only mode: Windows Update and Store downloads continue,
but this PC does not exchange update payloads with peers. Recall and Click to Do where the
current build supports that policy, activity-history upload, feedback prompts, cloud search,
search highlights, and Edge diagnostic/personalization reporting are disabled. The Bing
Search package is removed separately by `debloat.ps1`. Pro still sends service data required
for security, licensing, certificates, Store, Xbox, and updates; the profile deliberately
does not block Microsoft hosts or damage those dependencies.

Power command failures are collected and produce exit code 1. The dry run performs no
registry, power, or Explorer changes.

## Scanner exclusions

Defender stays on and real-time protection stays on. What this removes is real-time scanning
of the two development roots, because a single `npm install` writes tens of thousands of
short-lived files and MsMpEng reads every one of them: on this machine it had accumulated
fourteen hours of CPU time scanning `node_modules` churn across worktrees.

| Key | Resolves to | Why |
| --- | --- | --- |
| `layout:repos` | the `repos` row of [`layout/LAYOUT.md`](../layout/LAYOUT.md) | Every clone, and every `node_modules` inside one |
| `home:orca\workspaces` | `%USERPROFILE%\orca\workspaces` | Orca worktrees — one dependency tree per worktree, all transient |

Keys rather than paths: `C:\Briar\repos` is written down once, in `layout/LAYOUT.md`, and a
second copy here is a copy that drifts. A declared path does not have to exist yet —
`orca\workspaces` appears the first time a worktree is created, and the exclusion has to be
in place before it is.

What it costs: code that lands in either root is not scanned as it is written, so a malicious
dependency is caught when it executes outside the root, not when it unpacks inside it.
Nothing else changes — cloud protection, behaviour monitoring, SmartScreen, and scheduled
scans of the rest of the disk stay exactly as they were. Process exclusions are deliberately
not part of the profile: `node.exe` is excluded nowhere, only these two trees.

Applying and reading the list both need elevation, so an unelevated run reports every row as
pending rather than guessing. Tamper Protection can also accept the call and leave the list
unchanged; the installer reads each path back and fails the row when Defender does not
report it, in which case add it by hand under Windows Security → Virus & threat protection →
Manage settings → Exclusions.

```powershell
Get-MpPreference | Select-Object -ExpandProperty ExclusionPath   # elevated
```

## Debloat

`debloat.ps1` is excluded from the root orchestrator because package removal deserves a
separate confirmation:

```powershell
pwsh windows\debloat.ps1 -List
pwsh windows\debloat.ps1 -WhatIfOnly
pwsh windows\debloat.ps1
```

The canonical post-format run affects only the current account. This is a one-user personal
workstation, so registrations for unrelated profiles and provisioned copies for hypothetical
future users are deliberately outside scope. The script also removes the Win32 packages
declared below through winget. A package that is already absent is the desired state, not
stale-manifest evidence; review `-List` when deciding whether to change the tables.

## Intended profile

This is a personal LTSC-like profile on Windows 11 Pro, not an attempt to turn Pro into the
LTSC servicing channel. It removes the consumer and cloud-facing applications that are not
used while retaining the Microsoft infrastructure required by the workstation:

- Xbox, Game Pass, Game Bar, Gaming Services, DirectX, and GameInput stay.
- Store, App Installer/winget, Terminal, WSL, Hyper-V, and Windows Security stay.
- Calculator, Notepad, Snipping Tool, Photos, and Media Player stay as small local fallbacks.
- Edge stays installed for Windows compatibility and WebView2, but background mode, startup
  boost, first-run promotion, and default-browser prompts are disabled. Chrome is selected
  manually as the default browser after the restore.
- Phone Link, Cross Device, OneDrive, Widgets, Copilot, Microsoft 365 consumer applications,
  suggestions, news, weather, and web results in Start search go away.
- Windows Update, Defender, Firewall, SmartScreen, Search, SysMain, Bluetooth, notifications,
  printing to PDF, and Store servicing are not optimization targets. Defender keeps every
  protection enabled; the declared development roots are narrowed out of real-time scanning
  by path, and nothing else about it is touched — § Scanner exclusions.

## Startup applications

Startup is intentionally a review step rather than a hard-coded registry purge: package
updates rename startup entries, and disabling the wrong entry can silently break a driver or
VPN. In Task Manager → Startup apps, normally keep Windows Security notifications, Realtek,
Tailscale, and Logitech G Hub when its device profiles are needed. Vanguard remains when a
game requires it.

Chrome/Edge auto-launch, Discord, Steam, Riot Client, EA, Docker Desktop, Ollama, Spotify,
Claude, Porofessor, and similar launchers are better started on demand. This changes idle
process count far more than forcing unrelated Windows services off. Re-run `audit.ps1` after
making the final choices.

## Inbox apps

| Package | Application |
| --- | --- |
| `Microsoft.BingNews` | News |
| `Microsoft.BingWeather` | Weather |
| `Microsoft.BingSearch` | Web results in Start search |
| `Microsoft.GetHelp` | Get Help |
| `Microsoft.Getstarted` | Tips |
| `Microsoft.MicrosoftOfficeHub` | Office promotion hub |
| `Microsoft.MicrosoftSolitaireCollection` | Solitaire |
| `Microsoft.People` | People |
| `Microsoft.WindowsFeedbackHub` | Feedback Hub |
| `Microsoft.WindowsMaps` | Maps |
| `Microsoft.ZuneVideo` | Movies & TV |
| `Microsoft.Todos` | Microsoft To Do |
| `Microsoft.PowerAutomateDesktop` | Power Automate |
| `Microsoft.OutlookForWindows` | New Outlook |
| `Microsoft.OneDriveSync` | OneDrive Store-packaged sync client |
| `Microsoft.WindowsSoundRecorder` | Sound Recorder |
| `MicrosoftCorporationII.QuickAssist` | Quick Assist |
| `Clipchamp.Clipchamp` | Clipchamp |
| `MSTeams` | Consumer Teams |
| `Microsoft.549981C3F5F10` | Cortana package, when present |
| `Microsoft.Copilot` | Copilot application, when present |
| `Microsoft.Windows.DevHome` | Dev Home |
| `Microsoft.MicrosoftStickyNotes` | Sticky Notes |
| `Microsoft.WindowsAlarms` | Clock |
| `Microsoft.WindowsCamera` | Camera |
| `Microsoft.Paint` | Paint |
| `Microsoft.YourPhone` | Phone Link |
| `MicrosoftWindows.CrossDevice` | Cross-device integration |
| `MicrosoftCorporationII.MicrosoftFamily` | Microsoft Family, when present |
| `Microsoft.StartExperiencesApp` | Widgets feed experience |
| `Microsoft.WidgetsPlatformRuntime` | Widgets runtime |
| `MicrosoftWindows.Client.WebExperience` | Windows Web Experience Pack |

## Win32 apps

| winget ID | Application |
| --- | --- |
| `Microsoft.OneDrive` | OneDrive sync client |

## Deliberately kept

| Package | Reason |
| --- | --- |
| `Microsoft.DesktopAppInstaller` | App Installer and winget |
| `Microsoft.StorePurchaseApp` | Store licensing and purchases |
| `Microsoft.WindowsTerminal` | Terminal used by PowerShell, WSL, and the restore |
| `Microsoft.WindowsCalculator` | Small local calculator |
| `Microsoft.WindowsNotepad` | Small local text editor |
| `Microsoft.ScreenSketch` | Snipping Tool |
| `Microsoft.Windows.Photos` | Default local image handler |
| `Microsoft.ZuneMusic` | Current Media Player and default audio handler |
| `Microsoft.GamingApp` | Xbox and Game Pass |
| `Microsoft.GamingServices` | Microsoft Store and Game Pass game runtime |
| `Microsoft.XboxGamingOverlay` | Xbox Game Bar |
| `Microsoft.XboxIdentityProvider` | Xbox authentication |
| `Microsoft.Xbox.TCUI` | Xbox sign-in interface |
| `Microsoft.XboxSpeechToTextOverlay` | Xbox accessibility integration |
| `Microsoft.WindowsStore` | Store and Store-only package source |

Framework packages, WebView2, Windows Security, the shell, codecs, and driver control panels
are also protected by `debloat.ps1`; they are infrastructure rather than user-facing bloat.

Keep these tables under their own headings: the parser treats every backticked first cell
under `## Inbox apps` as an AppX removal target, every one under `## Win32 apps` as a winget
uninstall target, and every one under `## Scanner exclusions` as a path to exclude from
Defender.
