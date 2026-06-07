# ============================================================
# Satisfactory Dashboard - Scheduled / manual restart
# ============================================================
# Flow:
#   1. If players are online and a lead time is configured, run a
#      countdown (each milestone logged + Discord if configured).
#      If nobody is online, skip the wait and restart immediately.
#   2. SaveGame via API (so no progress is lost).
#   3. Stop the server.
#   4. (optional) SteamCMD app_update validate.
#   5. Start the server and wait for the API to come healthy.
# Everything is recorded in events.log.
#
#   scheduled: restart.ps1 -Auto              (reads restart-config.json)
#   manual:    restart.ps1 -Now               (immediate, short countdown)
#              restart.ps1 -Now -ForceUpdate  (immediate + update)
#              restart.ps1 -Now -NoUpdate     (immediate, skip update)
# ============================================================

param(
    [switch]$Auto,
    [switch]$Now,
    [switch]$ForceUpdate,
    [switch]$NoUpdate
)

. (Join-Path $PSScriptRoot 'satisfactory-lib.ps1') | Out-Null

$cfg = Get-SatRestartConfig
$doUpdate = if ($ForceUpdate) { $true } elseif ($NoUpdate) { $false } else { [bool]$cfg.Update }
$lead = if ($Now) { 1 } else { [int]$cfg.LeadMinutes }

Write-SatEvent -Category 'restart' -Message ("Restart requested ({0}). Update={1}, lead={2}m." -f ($(if($Auto){'scheduled'}else{'manual'})), $doUpdate, $lead)

# 1. Countdown (only meaningful while players are online) --------------------
$token = Get-SatApiToken
$state = Get-SatServerState -Token $token
$online = if ($state) { $state.Players } else { 0 }

if ($online -gt 0 -and $lead -gt 0) {
    Send-SatNotify "Server restart scheduled in $lead minute(s). $online player(s) online."
    # minute milestones down to 1, then a short second-countdown
    $marks = 60,30,15,10,5,4,3,2,1 | Where-Object { $_ -le $lead } | Sort-Object -Descending
    $remaining = $lead
    foreach ($m in $marks) {
        $sleep = ($remaining - $m) * 60
        if ($sleep -gt 0) { Start-Sleep -Seconds $sleep }
        $remaining = $m
        Send-SatNotify "Server restarting in $m minute(s)."
    }
    Start-Sleep -Seconds 30
    Send-SatNotify "Server restarting in 30 seconds - save your work!"
    Start-Sleep -Seconds 30
} elseif ($online -eq 0) {
    Write-SatEvent -Category 'restart' -Message 'No players online - restarting immediately.'
}

# 2. Save -------------------------------------------------------------------
try {
    if ($token -and $state) {
        $saveName = ($state.SessionName) -replace '[^\w\- ]','' -replace '\s+','_'
        Invoke-SatApi -Function 'SaveGame' -Data @{ SaveName = $saveName } -Token $token | Out-Null
        Write-SatEvent -Category 'restart' -Message "Saved game '$saveName' before restart."
        Start-Sleep -Seconds 2
    }
} catch { Write-SatEvent -Category 'restart' -Message "Pre-restart save failed: $($_.Exception.Message)" -Level 'warn' }

# 3. Stop -------------------------------------------------------------------
Stop-SatServer | Out-Null
Write-SatEvent -Category 'restart' -Message 'Stop requested; waiting for process to exit...'
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline -and (Get-Process -Name $SatChildProc -ErrorAction SilentlyContinue)) { Start-Sleep -Seconds 2 }

# 4. Update (optional) ------------------------------------------------------
if ($doUpdate) {
    try { Update-SatServer | Out-Null } catch { Write-SatEvent -Category 'update' -Message "Update error: $($_.Exception.Message)" -Level 'error' }
}

# 5. Start + wait for health ------------------------------------------------
Start-SatServer | Out-Null
Write-SatEvent -Category 'restart' -Message 'Start requested; waiting for API health...'
$deadline = (Get-Date).AddSeconds(180)
$healthy = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    try {
        $h = Invoke-RestMethod -Uri $SatApiBase -Method Post -SkipCertificateCheck -ContentType 'application/json' -TimeoutSec 8 `
            -Body (@{ function = 'HealthCheck'; data = @{ clientCustomData = '' } } | ConvertTo-Json)
        if ($h.data.health -eq 'healthy') { $healthy = $true; break }
    } catch {}
}
if ($healthy) {
    Write-SatEvent -Category 'restart' -Message 'Restart complete - server is healthy.'
    Send-SatNotify 'Server is back online.'
} else {
    Write-SatEvent -Category 'restart' -Message 'Server did not report healthy within 3 minutes after restart.' -Level 'error'
}
