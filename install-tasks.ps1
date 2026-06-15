# ============================================================
# Satisfactory Dashboard - Scheduled Task Installer
# ============================================================
# Registers three tasks (run as SYSTEM, highest privileges):
#   1. Collector  - every 1 minute, refreshes the dashboard JSON
#   2. Backup     - daily at 04:00, save -> OneDrive + GFS prune
#   3. Web server - starts serve.ps1 at boot
#
# Re-run any time to recreate them. Use -BackupAt 'HH:mm' to
# change the backup time.
# ============================================================

param([string]$BackupAt = '04:00')

. (Join-Path $PSScriptRoot 'satisfactory-lib.ps1') | Out-Null

$pwsh = (Get-Command pwsh).Source
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount

function Register-DashTask {
    param([string]$Name, [string]$Script, $Trigger, [string]$Args = '', [string]$Desc)
    $action = New-ScheduledTaskAction -Execute $pwsh `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $SatDashboard $Script)`" $Args"
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
    Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $Name -Description $Desc -Action $action -Trigger $Trigger `
        -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
    Write-Host "  registered: $Name" -ForegroundColor Green
}

# 1. Collector - repeat every minute, ~indefinitely (Task Scheduler rejects
#    TimeSpan.MaxValue, so use a 10-year window).
$collectTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
Register-DashTask -Name 'Satisfactory Dashboard Collector' -Script 'collect.ps1' `
    -Trigger $collectTrigger -Desc 'Snapshots Satisfactory server state into the dashboard JSON every minute.'

# 2. Backup - daily
if ($BackupAt -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') { throw "Invalid -BackupAt '$BackupAt' (use HH:mm)" }
$backupTrigger = New-ScheduledTaskTrigger -Daily -At $BackupAt
Register-DashTask -Name 'Satisfactory Dashboard Backup' -Script 'backup.ps1' -Args '-Auto -Trigger scheduled' `
    -Trigger $backupTrigger -Desc "Daily Satisfactory save backup to OneDrive ($BackupAt) with GFS retention."

# 3. Web server - at boot
$bootTrigger = New-ScheduledTaskTrigger -AtStartup
Register-DashTask -Name 'Satisfactory Dashboard Web' -Script 'serve.ps1' `
    -Trigger $bootTrigger -Desc 'Serves the Satisfactory dashboard on the management network.'

# 3b. Discord command listener - at boot, long-running (no execution time limit),
#     restarts itself if it ever falls over.
$discordAction = New-ScheduledTaskAction -Execute $pwsh `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $SatDashboard 'discord-listen.ps1')`""
$discordSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
Unregister-ScheduledTask -TaskName 'Satisfactory Dashboard Discord Bot' -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName 'Satisfactory Dashboard Discord Bot' `
    -Description 'Polls Discord for /commands from approved users (restart, update, backup, stats).' `
    -Action $discordAction -Trigger (New-ScheduledTaskTrigger -AtStartup) `
    -Principal $principal -Settings $discordSettings -ErrorAction Stop | Out-Null
Write-Host "  registered: Satisfactory Dashboard Discord Bot" -ForegroundColor Green

# 4. Restart task - from restart-config.json (managed via the Maintenance tab)
Register-SatRestartTask
$rc = Get-SatRestartConfig
Write-Host ("  restart task: {0} ({1} at {2}, update={3})" -f ($(if($rc.Enabled){'enabled'}else{'disabled'})), $rc.Frequency, $rc.Time, $rc.Update) -ForegroundColor Green

Write-Host "`nDone. Starting collector + Discord listener now..." -ForegroundColor Cyan
Start-ScheduledTask -TaskName 'Satisfactory Dashboard Collector'
Start-ScheduledTask -TaskName 'Satisfactory Dashboard Discord Bot'
Write-Host "Backup scheduled daily at $BackupAt. Web server + Discord bot start at boot (started now too)." -ForegroundColor DarkGray
Write-Host "Configure the Discord bot (token, channel, approved users) on the Discord Bot tab." -ForegroundColor DarkGray
