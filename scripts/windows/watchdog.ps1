#Requires -Version 7.0
<#
.SYNOPSIS
  DSH Night-Shift Watchdog (Windows).

.DESCRIPTION
  Runs on a schedule (every 10 minutes). It does NOT auto-start DSH at login.

  Behavior:
    1. Exit immediately if the host config is missing (skill not installed).
    2. Take a single-instance lock (no overlapping runs).
    3. Read $DSH_HOME/night-shift/config.json.
    4. Scan $DSH_HOME/night-shift/runs/*.json and prune stale entries
       (startedAt older than config.staleHours, default 18h).
    5. If no active night-shift run exists -> exit. Never touch DSH.
    6. If an active run exists and the DSH process is NOT running -> start it.
    7. Optional stall check (config.enableStallCheck = true): if no session log
       was written for config.stallMinutes, force-restart DSH.

  Design rules (see references/host-level.md):
    - Liveness signal must come from the engine (session log mtime), never from
      model-written files or task duration.
    - Only acts while a night-shift run is registered.
    - Logs only state changes.

.PARAMETER DshHome
  DSH home directory. Defaults to $env:DSH_HOME or ~/.dsh.

.PARAMETER DryRun
  Print what would happen without starting/killing anything.

.EXAMPLE
  pwsh -NoProfile -File watchdog.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$DshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$root       = Join-Path $DshHome 'night-shift'
$configPath = Join-Path $root 'config.json'
$runsDir    = Join-Path $root 'runs'
$logPath    = Join-Path $root 'watchdog.log'
$lockPath   = Join-Path $root 'watchdog.lock'
$taskName   = 'DSH Night Watchdog'

function Write-WdLog([string]$Message) {
    $line = ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 } catch { }
}

# --- not installed: do nothing -------------------------------------------------
if (-not (Test-Path -LiteralPath $configPath)) { return }

# --- single-instance lock ------------------------------------------------------
$lockStream = $null
try {
    if (Test-Path -LiteralPath $lockPath) {
        $age = (Get-Date) - (Get-Item -LiteralPath $lockPath).LastWriteTime
        if ($age.TotalMinutes -gt 15) {
            Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
            Write-WdLog 'stale watchdog.lock removed'
        }
    }
    $lockStream = [System.IO.File]::Open(
        $lockPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None)
} catch {
    return   # another instance is running
}

try {
    $cfg = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json

    $staleHours  = if ($null -ne $cfg.staleHours)  { [double]$cfg.staleHours }  else { 18 }
    $stallMins   = if ($null -ne $cfg.stallMinutes) { [double]$cfg.stallMinutes } else { 40 }
    $procName    = if ($cfg.dshProcessName) { [string]$cfg.dshProcessName } else { 'DeepSeek Harness' }
    $exe         = if ($cfg.dshExecutable)  { [string]$cfg.dshExecutable }  else { '' }
    $stallCheck  = ($cfg.enableStallCheck -eq $true)

    # --- prune stale / invalid run entries ------------------------------------
    $activeRuns = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $runsDir) {
        foreach ($f in Get-ChildItem -LiteralPath $runsDir -Filter '*.json' -File) {
            try {
                $run = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                $started = [datetimeoffset]::Parse([string]$run.startedAt)
                $ageHours = ((Get-Date) - $started.LocalDateTime).TotalHours
                if ($ageHours -gt $staleHours) {
                    Remove-Item -LiteralPath $f.FullName -Force
                    Write-WdLog ("stale run pruned: {0} (started {1})" -f $f.Name, $run.startedAt)
                } else {
                    [void]$activeRuns.Add($run)
                }
            } catch {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                Write-WdLog ("invalid run file removed: {0}" -f $f.Name)
            }
        }
    }

    if ($activeRuns.Count -eq 0) { return }   # no night shift -> never touch DSH

    # --- is DSH running? ------------------------------------------------------
    $proc = Get-Process -Name $procName -ErrorAction SilentlyContinue

    if (-not $proc) {
        if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
            Write-WdLog ("DSH not running, but dshExecutable is missing/invalid: '{0}'" -f $exe)
            exit 1
        }
        Write-WdLog ("DSH not running ({0} active run(s)) -> starting {1}" -f $activeRuns.Count, $exe)
        if (-not $DryRun) { Start-Process -FilePath $exe | Out-Null }
        return
    }

    # --- optional stall check (engine-written signal only) --------------------
    if ($stallCheck) {
        $sessionsDir = Join-Path $DshHome 'sessions'
        if (Test-Path -LiteralPath $sessionsDir) {
            $latest = Get-ChildItem -LiteralPath $sessionsDir -Recurse -Filter 'session.jsonl.zstd' -File -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTime -Descending |
                      Select-Object -First 1
            if ($latest) {
                $idleMinutes = ((Get-Date) - $latest.LastWriteTime).TotalMinutes
                if ($idleMinutes -gt $stallMins) {
                    Write-WdLog ("stalled: no session write for {0:N0} min (limit {1:N0}) -> restarting DSH" -f $idleMinutes, $stallMins)
                    if (-not $DryRun) {
                        $proc | Stop-Process -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 3
                        if ($exe -and (Test-Path -LiteralPath $exe)) { Start-Process -FilePath $exe | Out-Null }
                    }
                }
            }
        }
    }
}
finally {
    if ($lockStream) { $lockStream.Dispose() }
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}
