#Requires -Version 7.0
<#
.SYNOPSIS
  Install / uninstall the DSH Night-Shift Watchdog (Windows).

.DESCRIPTION
  One-time, idempotent host-level setup. It does NOT register auto-start at login.

  Install:
    1. Create $DSH_HOME/night-shift/{scripts,runs}.
    2. Copy watchdog.ps1 from this repository folder to the host scripts folder.
    3. Create or update $DSH_HOME/night-shift/config.json:
         - defaults: heartbeatSeconds=900, stallMinutes=40, staleHours=18,
           enableStallCheck=false, dshProcessName='DeepSeek Harness'
         - hostSetup.watchdog.installed = true
    4. Register scheduled task 'DSH Night Watchdog' every 10 minutes
       (runs only while you are logged on; no password stored).

  Uninstall:
    1. Remove the scheduled task.
    2. Set hostSetup.watchdog.installed = false.
    (Scripts and config stay on disk; delete manually if you want.)

.PARAMETER DshHome
  DSH home directory. Defaults to $env:DSH_HOME or ~/.dsh.

.PARAMETER DshExecutable
  Full path to the DSH executable. Optional; auto-detected from a running
  process, otherwise taken from an existing config.json.

.PARAMETER Uninstall
  Remove the scheduled task and mark the watchdog as not installed.

.PARAMETER DryRun
  Print the planned actions without changing anything.

.EXAMPLE
  pwsh -NoProfile -File setup.ps1 -DryRun
.EXAMPLE
  pwsh -NoProfile -File setup.ps1
.EXAMPLE
  pwsh -NoProfile -File setup.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$DshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }),
    [string]$DshExecutable = '',
    [switch]$Uninstall,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$taskName    = 'DSH Night Watchdog'
$root        = Join-Path $DshHome 'night-shift'
$configPath  = Join-Path $root 'config.json'
$scriptsDir  = Join-Path $root 'scripts'
$runsDir     = Join-Path $root 'runs'
$watchdogSrc = Join-Path $PSScriptRoot 'watchdog.ps1'
$watchdogDst = Join-Path $scriptsDir 'watchdog.ps1'

function Say([string]$Message) { Write-Host $Message }

function Get-DshExecutable {
    param([string]$Explicit, [string]$FromConfig)

    if ($Explicit -and (Test-Path -LiteralPath $Explicit)) { return (Resolve-Path -LiteralPath $Explicit).Path }
    if ($FromConfig -and (Test-Path -LiteralPath $FromConfig)) { return $FromConfig }

    $proc = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc -and $proc.Path -and (Test-Path -LiteralPath $proc.Path)) { return $proc.Path }

    return ''
}

function Read-Config {
    if (Test-Path -LiteralPath $configPath) {
        return ([System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    }
    return $null
}

function Save-Config($Config) {
    $json = $Config | ConvertTo-Json -Depth 10
    if ($DryRun) {
        Say '[dry-run] would write config.json:'
        Say $json
        return
    }
    # UTF-8 without BOM (PowerShell 5.1 reads UTF-8 correctly only when explicit)
    [System.IO.File]::WriteAllText($configPath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Runner {
    # This machine standardizes on PowerShell 7 (pwsh). Do not fall back to 5.1.
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh -and $pwsh.Source) { return $pwsh.Source }
    throw 'pwsh (PowerShell 7) not found on PATH. Install PS7 or run this setup with pwsh explicitly.'
}

# ============================ uninstall ======================================
if ($Uninstall) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        if ($DryRun) { Say "[dry-run] would unregister scheduled task '$taskName'" }
        else {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Say "scheduled task '$taskName' removed"
        }
    } else {
        Say "scheduled task '$taskName' not found (nothing to remove)"
    }

    $cfg = Read-Config
    if ($cfg) {
        if ($cfg.hostSetup -and $cfg.hostSetup.watchdog) {
            $cfg.hostSetup.watchdog | Add-Member -NotePropertyName installed -NotePropertyValue $false -Force
            $cfg.hostSetup.watchdog | Add-Member -NotePropertyName note -NotePropertyValue 'uninstalled; task removed' -Force
        }
        Save-Config $cfg
        Say 'config.json: hostSetup.watchdog.installed = false'
    }
    Say 'uninstall done (scripts/config left on disk)'
    return
}

# ============================ install ========================================
Say "DSH home: $DshHome"
foreach ($d in @($root, $scriptsDir, $runsDir)) {
    if (-not (Test-Path -LiteralPath $d)) {
        if ($DryRun) { Say "[dry-run] would create directory $d" }
        else { New-Item -ItemType Directory -Path $d -Force | Out-Null; Say "created $d" }
    }
}

# 1) copy watchdog script
if (-not (Test-Path -LiteralPath $watchdogSrc)) {
    throw "watchdog.ps1 not found next to setup.ps1: $watchdogSrc"
}
if ($DryRun) { Say "[dry-run] would copy $watchdogSrc -> $watchdogDst" }
else { Copy-Item -LiteralPath $watchdogSrc -Destination $watchdogDst -Force; Say "copied watchdog -> $watchdogDst" }

# 2) config.json
$cfg = Read-Config
$isNew = ($null -eq $cfg)
if ($isNew) {
    $cfg = [pscustomobject]@{
        version          = 1
        centralKnowledge = (Join-Path $root 'central-knowledge')
        dshExecutable    = ''
        dshProcessName   = 'DeepSeek Harness'
        heartbeatSeconds = 900
        stallMinutes     = 40
        staleHours       = 18
        enableStallCheck = $false
        hostSetup        = [pscustomobject]@{
            subagentModel = [pscustomobject]@{ configured = $false; note = 'set manually in your user preset' }
            watchdog      = [pscustomobject]@{ installed = $false }
        }
    }
    Say 'config.json not found -> creating with defaults'
} else {
    Say 'config.json found -> updating'
    if (-not $cfg.dshProcessName)   { $cfg | Add-Member -NotePropertyName dshProcessName -NotePropertyValue 'DeepSeek Harness' -Force }
    if ($null -eq $cfg.staleHours)  { $cfg | Add-Member -NotePropertyName staleHours -NotePropertyValue 18 -Force }
    if ($null -eq $cfg.stallMinutes){ $cfg | Add-Member -NotePropertyName stallMinutes -NotePropertyValue 40 -Force }
    if ($null -eq $cfg.heartbeatSeconds) { $cfg | Add-Member -NotePropertyName heartbeatSeconds -NotePropertyValue 900 -Force }
    if ($null -eq $cfg.enableStallCheck) { $cfg | Add-Member -NotePropertyName enableStallCheck -NotePropertyValue $false -Force }
    if (-not $cfg.hostSetup) { $cfg | Add-Member -NotePropertyName hostSetup -NotePropertyValue ([pscustomobject]@{}) -Force }
    if (-not $cfg.hostSetup.watchdog) { $cfg.hostSetup | Add-Member -NotePropertyName watchdog -NotePropertyValue ([pscustomobject]@{}) -Force }
}

$existingExe = if ($cfg.dshExecutable) { [string]$cfg.dshExecutable } else { '' }
$resolvedExe = Get-DshExecutable -Explicit $DshExecutable -FromConfig $existingExe
if (-not $resolvedExe) {
    Write-Warning 'DSH executable not detected. Pass -DshExecutable "<path to DeepSeek Harness.exe>" and re-run.'
} else {
    $cfg.dshExecutable = $resolvedExe
    Say "dshExecutable = $resolvedExe"
}
$cfg.hostSetup.watchdog | Add-Member -NotePropertyName installed -NotePropertyValue $true -Force
$cfg.hostSetup.watchdog | Add-Member -NotePropertyName installedAt -NotePropertyValue (Get-Date -Format 'yyyy-MM-dd') -Force
$cfg.hostSetup.watchdog | Add-Member -NotePropertyName note -NotePropertyValue 'installed; source: night-shift/scripts/windows/setup.ps1' -Force
Save-Config $cfg

# 3) scheduled task
$runner = Get-Runner
$argString = '-NoProfile -WindowStyle Hidden -File "{0}"' -f $watchdogDst

if ($DryRun) {
    Say "[dry-run] would register task '$taskName':"
    Say "  program : $runner"
    Say "  args    : $argString"
    Say '  trigger : every 10 minutes, run only while logged on'
    Say '  (no auto-start at login)'
    return
}

$action = New-ScheduledTaskAction -Execute $runner -Argument $argString
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 10)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
$settings.DisallowStartIfOnBatteries = $false

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
    -Description 'DSH night-shift crash recovery: starts DSH only when a night-shift run is registered.' -Force | Out-Null

Say "scheduled task '$taskName' registered (every 10 minutes, logged-on only)"
Say 'no auto-start at login was added (by design)'
Say ''
Say 'verify with:  Get-ScheduledTask -TaskName "DSH Night Watchdog" | Format-List'
Say 'uninstall  :  pwsh -NoProfile -File setup.ps1 -Uninstall   (needs an elevated shell)'
