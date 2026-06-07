# ============================================================
# Satisfactory Dashboard - Collector
# ============================================================
# Snapshots the server every cycle and writes the JSON the web
# page reads. Run on a short schedule (e.g. every 30-60s).
#
# Outputs (all under www\data):
#   state.json      - current snapshot + fun facts (the headline view)
#   players.json    - per-player aggregates + recent sessions
#   metrics.jsonl   - append-only timeseries (tps, cpu, ram, players)
#   savesize.jsonl  - append-only save-size samples (factory growth)
# ============================================================

. (Join-Path $PSScriptRoot 'satisfactory-lib.ps1') | Out-Null

if (-not (Test-Path $SatDataDir)) { New-Item -ItemType Directory -Path $SatDataDir -Force | Out-Null }

# Watchdog first: relaunch the server if it died unexpectedly (no stop.flag).
Invoke-SatWatchdog

$now = Get-Date

# --- Gather -----------------------------------------------------------------
$token   = Get-SatApiToken
$state   = Get-SatServerState -Token $token        # may be $null if API down
$metrics = Get-SatProcessMetrics
$pd      = Get-SatPlayerData
$online  = Get-SatOnlineConnections
$save    = Get-SatSaveInfo
$uptime  = Get-SatUptimeInfo -ReadyEvents $pd.ReadyEvents

# Online count: prefer the API, fall back to live sockets.
$playersOnline = if ($state) { $state.Players } else { @($online).Count }

# --- Fun facts (the geek candy) --------------------------------------------
$combined = ($pd.Players | Measure-Object TotalSeconds -Sum).Sum
$topPlayer = $pd.Players | Select-Object -First 1
$longestSession = $pd.Sessions | Sort-Object DurationSec -Descending | Select-Object -First 1

# busiest day of week by minutes online (sum the heat grid rows)
$dayNames = 'Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'
$dayTotals = @(for ($d=0; $d -lt 7; $d++) { ($pd.Heatmap[$d] | Measure-Object -Sum).Sum })
$busiestDayIdx = 0; for ($d=1; $d -lt 7; $d++) { if ($dayTotals[$d] -gt $dayTotals[$busiestDayIdx]) { $busiestDayIdx = $d } }
# busiest hour of day across the week
$hourTotals = @(for ($h=0; $h -lt 24; $h++) { $s=0; for($d=0;$d -lt 7;$d++){ $s += $pd.Heatmap[$d][$h] }; $s })
$busiestHour = 0; for ($h=1; $h -lt 24; $h++) { if ($hourTotals[$h] -gt $hourTotals[$busiestHour]) { $busiestHour = $h } }

$funFacts = [PSCustomObject]@{
    UniquePlayers        = @($pd.Players).Count
    CombinedPlaytimeSec  = [int]$combined
    TopPlayer            = if ($topPlayer) { $topPlayer.Name } else { $null }
    TopPlayerSec         = if ($topPlayer) { $topPlayer.TotalSeconds } else { 0 }
    LongestSessionName   = if ($longestSession) { $longestSession.Name } else { $null }
    LongestSessionSec    = if ($longestSession) { $longestSession.DurationSec } else { 0 }
    PeakConcurrent       = $pd.Peak
    PeakAt               = $pd.PeakAt
    BusiestDay           = if (($dayTotals | Measure-Object -Sum).Sum -gt 0) { $dayNames[$busiestDayIdx] } else { $null }
    BusiestHour          = if (($hourTotals | Measure-Object -Sum).Sum -gt 0) { $busiestHour } else { $null }
    TotalSessions        = @($pd.Sessions).Count
}

# --- state.json -------------------------------------------------------------
$gamePhaseNames = @{ 0='Onboarding / Phase 0'; 1='Phase 1: Distribution'; 2='Phase 2: Construction';
                     3='Phase 3: Project Assembly'; 4='Phase 4: Assembly'; 5='Phase 5: Completion' }
$stateOut = [PSCustomObject]@{
    UpdatedAt    = $now.ToString('o')
    ApiOnline    = [bool]$state
    Server       = [PSCustomObject]@{
        Running      = $uptime.Running
        SessionName  = if ($state) { $state.SessionName } else { $save.File }
        PlayersOnline= $playersOnline
        PlayerLimit  = if ($state) { $state.PlayerLimit } else { 4 }
        TechTier     = if ($state) { $state.TechTier } else { $null }
        GamePhase    = if ($state) { $state.GamePhase } else { $null }
        GamePhaseName= if ($state -and $gamePhaseNames.ContainsKey($state.GamePhase)) { $gamePhaseNames[$state.GamePhase] } else { $null }
        TickRate     = if ($state) { $state.TickRate } else { $null }
        IsPaused     = if ($state) { $state.IsPaused } else { $null }
        GameDuration = if ($state) { [int]$state.DurationSec } else { $null }
        UptimeSec    = $uptime.UptimeSec
        StartedAt    = $uptime.StartedAt
    }
    Metrics      = [PSCustomObject]@{
        CpuPercent = $metrics.CpuPercent
        RamMB      = $metrics.RamMB
        RamPercent = $metrics.RamPercent
    }
    Save         = $save
    OnlineNow    = $online
    FunFacts     = $funFacts
    Heatmap      = $pd.Heatmap
}
$stateOut | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $SatDataDir 'state.json') -Encoding UTF8

# --- players.json -----------------------------------------------------------
[PSCustomObject]@{
    UpdatedAt = $now.ToString('o')
    Players   = $pd.Players
    Sessions  = @($pd.Sessions | Sort-Object Start -Descending | Select-Object -First 50)
} | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $SatDataDir 'players.json') -Encoding UTF8

# --- metrics.jsonl (append + cap) ------------------------------------------
$metricsFile = Join-Path $SatDataDir 'metrics.jsonl'
$sample = [PSCustomObject]@{
    t      = $now.ToString('o')
    tps    = if ($state) { $state.TickRate } else { $null }
    cpu    = $metrics.CpuPercent
    ram    = $metrics.RamMB
    online = $playersOnline
    tier   = if ($state) { $state.TechTier } else { $null }
} | ConvertTo-Json -Compress
Add-Content -Path $metricsFile -Value $sample -Encoding UTF8
# keep the file bounded (~last 20k samples ≈ a week at 30s cadence)
$lines = @(Get-Content $metricsFile)
if ($lines.Count -gt 20000) { $lines | Select-Object -Last 20000 | Set-Content $metricsFile -Encoding UTF8 }

# --- savesize.jsonl (append only when it changes) --------------------------
if ($save) {
    $saveFile = Join-Path $SatDataDir 'savesize.jsonl'
    $lastBytes = $null
    if (Test-Path $saveFile) {
        $lastLine = Get-Content $saveFile -Tail 1 -ErrorAction SilentlyContinue
        if ($lastLine) { try { $lastBytes = ($lastLine | ConvertFrom-Json).bytes } catch {} }
    }
    if ($lastBytes -ne $save.Bytes) {
        ([PSCustomObject]@{ t = $now.ToString('o'); bytes = $save.Bytes } | ConvertTo-Json -Compress) |
            Add-Content -Path $saveFile -Encoding UTF8
    }
}

# --- settings.json (editable config for the Settings tab; token never exposed)
try {
    Get-SatSettingsView | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $SatDataDir 'settings.json') -Encoding UTF8
} catch {}

# --- backups.json (inventory + retention + run history) ---------------------
try {
    Get-SatBackupReport | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $SatDataDir 'backups.json') -Encoding UTF8
} catch {}

# --- version tracking (logs a 'version' event on any change) ----------------
$ver = $null
try { $ver = Update-SatVersionTracking } catch {}

# --- maintenance.json (watchdog + restart schedule + version + events) ------
try {
    $rcfg = Get-SatRestartConfig
    $rtask = Get-ScheduledTask -TaskName $SatRestartTask -ErrorAction SilentlyContinue
    $nextRestart = if ($rtask) { ($rtask | Get-ScheduledTaskInfo).NextRunTime } else { $null }
    [PSCustomObject]@{
        UpdatedAt      = $now.ToString('o')
        Watchdog       = [bool]$SatWatchdog
        SteamCmdReady  = (Test-Path $SatSteamCmd)
        Version        = if ($ver) { $ver.Display } else { 'unknown' }
        VersionDetail  = $ver
        VersionHistory = @(Get-SatVersionHistory -Count 20)
        Restart        = $rcfg
        NextRestart    = if ($nextRestart) { $nextRestart.ToString('o') } else { $null }
        Events         = @(Get-SatEvents -Count 40)
    } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $SatDataDir 'maintenance.json') -Encoding UTF8
} catch {}
