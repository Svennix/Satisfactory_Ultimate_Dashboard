# ============================================================
# Satisfactory Dashboard - Backup + Retention
# ============================================================
# Copies the live save to OneDrive with a self-describing name,
# then prunes old backups with grandfather-father-son retention.
#
# Unlike the Windrose backup, this does NOT stop the server: the
# dedicated server autosaves on its own, and we trigger a fresh
# API save first, so a hot-copy of the newest .sav is consistent.
#
#   manual:    powershell -File backup.ps1
#   scheduled: powershell -File backup.ps1 -Auto
# ============================================================

param(
    [switch]$Auto,
    [string]$Trigger = 'manual'
)

. (Join-Path $PSScriptRoot 'satisfactory-lib.ps1') | Out-Null

$start = Get-Date
$log = [System.Collections.Generic.List[string]]::new()
function _log($m){ $log.Add("$(Get-Date -Format 'HH:mm:ss')  $m"); if (-not $Auto) { Write-Host $m } }

$result = @{ Success = $false; Path = ''; Bytes = 0; Pruned = 0; Error = '' }

try {
    if (-not (Test-Path $SatBackupDir)) { New-Item -ItemType Directory -Path $SatBackupDir -Force | Out-Null }

    # 1. Ask the server to flush a fresh save (best effort; autosave is fine too)
    $token = Get-SatApiToken
    $state = if ($token) { Get-SatServerState -Token $token } else { $null }
    if ($token) {
        try {
            $saveName = ($state.SessionName) -replace '[^\w\- ]', '' -replace '\s+', '_'
            if (-not $saveName) { $saveName = 'dashboard_backup' }
            Invoke-SatApi -Function 'SaveGame' -Data @{ SaveName = $saveName } -Token $token | Out-Null
            _log "Triggered API SaveGame '$saveName'"
            Start-Sleep -Seconds 2   # let the file land
        } catch { _log "API SaveGame skipped: $($_.Exception.Message)" }
    } else {
        _log "No API token; backing up newest autosave instead."
    }

    # 2. Pick the newest .sav on disk
    $sav = Get-ChildItem $SatSaveDir -Filter '*.sav' -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $sav) { throw "No .sav files found in $SatSaveDir" }

    # 3. Build a self-describing name: <session>_<stamp>_T<tier>_<gametime>.sav
    $session = if ($state) { ($state.SessionName -replace '[^\w\- ]','' -replace '\s+','-') } else { 'save' }
    $stamp   = $start.ToString('yyyy-MM-dd_HHmmss')
    $tierTag = if ($state) { "T$($state.TechTier)" } else { 'T?' }
    $durTag  = if ($state) { (Format-SatDuration $state.DurationSec) -replace '\s','' } else { '' }
    $name    = ("{0}_{1}_{2}_{3}.sav" -f $session, $stamp, $tierTag, $durTag) -replace '_+\.sav$', '.sav'
    $dest    = Join-Path $SatBackupDir $name

    Copy-Item -Path $sav.FullName -Destination $dest -Force
    $result.Path = $dest
    $result.Bytes = (Get-Item $dest).Length
    _log "Backed up $($sav.Name) -> $name ($(Format-SatBytes $result.Bytes))"

    # 4. Grandfather-father-son retention prune (shared classifier in the lib)
    $all  = Get-ChildItem $SatBackupDir -Filter '*.sav' -ErrorAction SilentlyContinue
    $plan = Get-SatRetentionPlan -Files @($all)
    $kept = 0
    foreach ($item in $plan) {
        if ($item.Keep) { $kept++; continue }
        Remove-Item $item.FullName -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $item.FullName)) { $result.Pruned++ }
    }
    _log "Retention: kept $kept, pruned $($result.Pruned)."

    $result.Success = $true
    _log "Backup OK."
} catch {
    $result.Error = $_.Exception.Message
    _log "Backup FAILED: $($result.Error)"
}

# --- append a compact history entry -----------------------------------------
$verdict = if ($result.Success) { 'SUCCESS' } else { 'FAILED' }
$dur = '{0:N1}s' -f ((Get-Date) - $start).TotalSeconds
$entry = @(
    '=' * 70
    " $($start.ToString('yyyy-MM-dd HH:mm:ss')) - $verdict ($dur)  [trigger: $Trigger]"
    '=' * 70
) + $log
if ($result.Success) { $entry += "Backup: $($result.Path) ($(Format-SatBytes $result.Bytes))" }
$entry += ''
Add-Content -Path $SatBackupHistoryLog -Value ($entry -join "`r`n") -Encoding UTF8

# Surface the outcome on the dashboard event log + Discord
if ($result.Success) {
    $sizeStr = Format-SatBytes $result.Bytes
    $last24  = @(Get-ChildItem $SatBackupDir -Filter '*.sav' -ErrorAction SilentlyContinue |
                 Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-1) }).Count
    # Local event log keeps the detail (filename + prune count) for the dashboard...
    Write-SatEvent -Category 'backup' -Message "Backup OK: $(Split-Path $result.Path -Leaf) ($sizeStr); pruned $($result.Pruned)."
    # ...Discord gets a concise, filename-free summary.
    Send-SatDiscord -Category 'backup' -Message ('Backup done in {0} · {1} · {2} backup{3} in the last 24h.' -f $dur, $sizeStr, $last24, $(if ($last24 -eq 1) { '' } else { 's' }))
} else {
    Write-SatEvent -Category 'backup' -Message "Backup FAILED: $($result.Error)" -Level 'error' -Discord
}

if (-not $result.Success -and $Auto) { exit 1 }
$result.Success
