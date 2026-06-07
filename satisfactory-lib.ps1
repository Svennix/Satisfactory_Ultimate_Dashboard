# ============================================================
# Satisfactory Dashboard - Shared Library
# ============================================================
# Pure functions used by collect.ps1, backup.ps1 and serve.ps1.
# No side effects on dot-source beyond loading settings.
#
# Data sources (all local, no game mod required):
#   - HTTPS API  -> live server state (tick rate, tier, phase, player count)
#   - FactoryGame.log -> per-player join/leave sessions (names + Steam IDs)
#   - the process     -> CPU% and RAM
#   - netstat 8888    -> authoritative "who is connected right now"
#   - the .sav files  -> save size (a proxy for factory complexity)
# ============================================================

. (Join-Path $PSScriptRoot 'satisfactory-settings.ps1') | Out-Null

# --- Small formatters -------------------------------------------------------

function Format-SatDuration {
    param([double]$Seconds)
    if ($Seconds -lt 60)    { return ('{0}s' -f [int]$Seconds) }
    if ($Seconds -lt 3600)  { return ('{0}m' -f [int]($Seconds / 60)) }
    if ($Seconds -lt 86400) { return ('{0}h {1}m' -f [int]($Seconds / 3600), [int](($Seconds % 3600) / 60)) }
    return ('{0}d {1}h' -f [int]($Seconds / 86400), [int](($Seconds % 86400) / 3600))
}

function Format-SatBytes {
    param([long]$Bytes)
    if ($Bytes -lt 1KB) { return "$Bytes B" }
    if ($Bytes -lt 1MB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N2} GB' -f ($Bytes / 1GB))
}

# --- HTTPS API --------------------------------------------------------------

function Get-SatApiToken {
    # Logs in with the admin password and returns an Administrator bearer token.
    # Tokens are short-lived, so callers fetch one per cycle (cheap, localhost).
    if (-not (Test-Path $SatSecretFile)) { return $null }
    $pw = (Get-Content $SatSecretFile -Raw).Trim()
    try {
        $r = Invoke-RestMethod -Uri $SatApiBase -Method Post -SkipCertificateCheck `
            -ContentType 'application/json' -TimeoutSec 10 `
            -Body (@{ function = 'PasswordLogin'; data = @{ Password = $pw; MinimumPrivilegeLevel = 'Administrator' } } | ConvertTo-Json)
        return $r.data.authenticationToken
    } catch { return $null }
}

function Invoke-SatApi {
    param(
        [Parameter(Mandatory)][string]$Function,
        [hashtable]$Data,
        [string]$Token
    )
    $body = @{ function = $Function }
    if ($Data) { $body.data = $Data }
    $headers = @{}
    if ($Token) { $headers.Authorization = "Bearer $Token" }
    Invoke-RestMethod -Uri $SatApiBase -Method Post -SkipCertificateCheck `
        -ContentType 'application/json' -TimeoutSec 15 -Headers $headers `
        -Body ($body | ConvertTo-Json -Depth 6)
}

function Get-SatServerState {
    # Returns the serverGameState hashtable, or $null if the API is unreachable.
    param([string]$Token)
    if (-not $Token) { $Token = Get-SatApiToken }
    if (-not $Token) { return $null }
    try {
        $r = Invoke-SatApi -Function 'QueryServerState' -Token $Token
        $gs = $r.data.serverGameState
        # Tidy the gamePhase blob down to a readable phase number/name.
        $phaseNum = $null
        if ($gs.gamePhase -match 'Phase_(\d+)') { $phaseNum = [int]$Matches[1] }
        [PSCustomObject]@{
            SessionName  = $gs.activeSessionName
            Players      = [int]$gs.numConnectedPlayers
            PlayerLimit  = [int]$gs.playerLimit
            TechTier     = [int]$gs.techTier
            GamePhase    = $phaseNum
            IsRunning    = [bool]$gs.isGameRunning
            IsPaused     = [bool]$gs.isGamePaused
            DurationSec  = [double]$gs.totalGameDuration
            TickRate     = [math]::Round([double]$gs.averageTickRate, 1)
        }
    } catch { return $null }
}

# --- Process metrics (CPU% + RAM) -------------------------------------------

function Get-SatProcessMetrics {
    # CPU% is derived from the delta of TotalProcessorTime between calls, so it
    # needs a tiny persisted sample. RAM is the live working set.
    $p = Get-Process -Name $SatChildProc -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) {
        return [PSCustomObject]@{ Running = $false; CpuPercent = 0; RamMB = 0; RamPercent = 0; UptimeSec = 0; Pid = $null }
    }

    $cores  = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    $totalRamMB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
    $now    = Get-Date
    $cpuSec = $p.TotalProcessorTime.TotalSeconds
    $sampleFile = Join-Path $SatDataDir '_cpusample.json'

    $cpuPct = 0.0
    if (Test-Path $sampleFile) {
        try {
            $prev = Get-Content $sampleFile -Raw | ConvertFrom-Json
            if ($prev.Pid -eq $p.Id) {
                $dWall = ($now - [datetime]$prev.At).TotalSeconds
                $dCpu  = $cpuSec - [double]$prev.CpuSec
                if ($dWall -gt 0) { $cpuPct = [math]::Round(($dCpu / ($dWall * $cores)) * 100, 1) }
                if ($cpuPct -lt 0) { $cpuPct = 0 }
            }
        } catch {}
    }
    @{ Pid = $p.Id; CpuSec = $cpuSec; At = $now.ToString('o') } | ConvertTo-Json | Set-Content $sampleFile -Encoding UTF8

    $ramMB = [math]::Round($p.WorkingSet64 / 1MB)
    [PSCustomObject]@{
        Running    = $true
        CpuPercent = $cpuPct
        RamMB      = $ramMB
        RamPercent = if ($totalRamMB) { [math]::Round(100 * $ramMB / $totalRamMB, 1) } else { 0 }
        UptimeSec  = [int]($now - $p.StartTime).TotalSeconds
        Pid        = $p.Id
    }
}

# --- Steam ID decode --------------------------------------------------------

function ConvertFrom-SteamRepData {
    # The log encodes the SteamID as little-endian RepData hex, e.g.
    # RepData=[69C1310201001001]. The low 4 bytes are the account ID;
    # SteamID64 = 76561197960265728 + accountID.
    param([string]$Hex)
    if (-not $Hex -or $Hex.Length -lt 8) { return $null }
    $b = $Hex.Substring(0, 8)
    # reverse the 4 bytes (little-endian -> big-endian) then parse
    $rev = $b.Substring(6,2) + $b.Substring(4,2) + $b.Substring(2,2) + $b.Substring(0,2)
    try {
        $acct = [Convert]::ToUInt32($rev, 16)
        return (76561197960265728 + [uint64]$acct).ToString()
    } catch { return $null }
}

# --- Log timestamp parsing --------------------------------------------------

function Read-SatLogLines {
    # The running server keeps FactoryGame.log open with an exclusive-ish lock,
    # so [System.IO.File]::ReadLines fails. Open with FileShare.ReadWrite and
    # stream the lines instead.
    param([string]$Path)
    $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $sr = [System.IO.StreamReader]::new($fs)
    try {
        while ($null -ne ($line = $sr.ReadLine())) { $line }
    } finally {
        $sr.Dispose(); $fs.Dispose()
    }
}

function ConvertFrom-SatLogTime {
    # Bracket timestamps in FactoryGame.log are UTC, e.g. [2026.06.07-14.40.19:325].
    # Returns a local DateTime.
    param([string]$Stamp)
    if ($Stamp -match '(\d{4})\.(\d{2})\.(\d{2})-(\d{2})\.(\d{2})\.(\d{2})') {
        $utc = [datetime]::new($Matches[1],$Matches[2],$Matches[3],$Matches[4],$Matches[5],$Matches[6],[DateTimeKind]::Utc)
        return $utc.ToLocalTime()
    }
    return $null
}

# --- The log parser: build player sessions ----------------------------------

function Read-SatPlayerDb {
    # Loads players.db (a JSON document: { Sessions: { "<sid>|<startISO>": {...} } }).
    $db = @{ Sessions = @{} }
    if (Test-Path $SatPlayerDb) {
        try {
            $loaded = Get-Content $SatPlayerDb -Raw | ConvertFrom-Json
            if ($loaded.Sessions) { foreach ($p in $loaded.Sessions.PSObject.Properties) { $db.Sessions[$p.Name] = $p.Value } }
        } catch {}
    }
    $db
}

function Save-SatPlayerDb {
    param($Db)
    try { @{ Sessions = $Db.Sessions } | ConvertTo-Json -Depth 5 | Set-Content $SatPlayerDb -Encoding UTF8 } catch {}
}

function Add-SatSession {
    # Upserts one session into the persistent DB, keyed by SteamID + start time
    # so re-parsing the same log line is idempotent (can't double-count).
    param($Db, [string]$Sid, [string]$Name, [string]$Ip, [datetime]$Start, [datetime]$End, [bool]$Open)
    if ($End -lt $Start) { $End = $Start }
    $key = '{0}|{1}' -f $Sid, $Start.ToString('o')
    $Db.Sessions[$key] = @{
        Name = $Name; SteamId = $Sid; Ip = $Ip
        Start = $Start.ToString('o'); End = $End.ToString('o')
        DurationSec = [int]($End - $Start).TotalSeconds; Open = $Open
    }
}

function Get-SatPlayerData {
    # Persistent all-time history in players.db. Each run reads ONLY the current
    # FactoryGame.log (which holds the active server run's sessions) and upserts
    # them into the DB keyed by SteamID + start time. Totals accumulate and
    # survive log rotation / restarts WITHOUT ever scanning backup logs.
    $db = Read-SatPlayerDb

    $reJoin  = 'Login request:.*?\?Name=([^?]+?) userId:.*?RepData=\[([0-9A-Fa-f]+)\]'
    $reLeave = 'UNetConnection::Close:.*?RepData=\[([0-9A-Fa-f]+)\]'
    $reIp    = 'RemoteAddr: \[::ffff:([0-9.]+)\]'

    $onlineIps = Get-SatOnlineConnections
    $serverUp  = [bool](Get-Process -Name $SatChildProc -ErrorAction SilentlyContinue)
    $now   = Get-Date
    $ready = New-Object System.Collections.Generic.List[datetime]

    # ---- parse the CURRENT log only, upsert sessions into the DB ----
    if (Test-Path $SatLogFile) {
        $joins=@{}; $leaves=@{}; $names=@{}; $ips=@{}; $lastTs=$null
        foreach ($line in (Read-SatLogLines $SatLogFile)) {
            if ($line -notmatch '^\[') { continue }
            $t = ConvertFrom-SatLogTime $line
            if ($t) { $lastTs = $t }
            if ($line -match 'Server streaming socket bound to port 8888') { if ($t) { $ready.Add($t) }; continue }
            if ($line -match $reJoin) {
                $nm = $Matches[1].Trim(); $sid = ConvertFrom-SteamRepData $Matches[2]
                if ($sid -and $t) {
                    if (-not $joins.ContainsKey($sid)) { $joins[$sid] = New-Object System.Collections.Generic.List[datetime] }
                    $joins[$sid].Add($t); $names[$sid] = $nm
                    if ($line -match $reIp) { $ips[$sid] = $Matches[1] }
                }
                continue
            }
            if ($line -match $reLeave) {
                $sid = ConvertFrom-SteamRepData $Matches[1]
                if ($sid -and $t) {
                    if (-not $leaves.ContainsKey($sid)) { $leaves[$sid] = New-Object System.Collections.Generic.List[datetime] }
                    $leaves[$sid].Add($t)
                }
            }
        }
        foreach ($sid in @($joins.Keys + $leaves.Keys | Sort-Object -Unique)) {
            $events = New-Object System.Collections.Generic.List[object]
            if ($joins.ContainsKey($sid))  { foreach ($t in $joins[$sid])  { $events.Add([PSCustomObject]@{ T = $t; Kind = 'J' }) } }
            if ($leaves.ContainsKey($sid)) { foreach ($t in $leaves[$sid]) { $events.Add([PSCustomObject]@{ T = $t; Kind = 'L' }) } }
            $events = $events | Sort-Object T
            $nm = if ($names.ContainsKey($sid)) { $names[$sid] } else { $null }
            $ip = if ($ips.ContainsKey($sid))   { $ips[$sid] }   else { $null }
            $open = $null
            foreach ($e in $events) {
                if ($e.Kind -eq 'J') { if ($null -eq $open) { $open = $e.T } }
                elseif ($null -ne $open) { Add-SatSession $db $sid $nm $ip $open $e.T $false; $open = $null }
            }
            if ($null -ne $open) {
                if ($serverUp -and $ip -and ($onlineIps -contains $ip)) { Add-SatSession $db $sid $nm $ip $open $now $true }
                else { $end = if ($lastTs -and $lastTs -gt $open) { $lastTs } else { $open }; Add-SatSession $db $sid $nm $ip $open $end $false }
            }
        }
    }

    Save-SatPlayerDb $db

    # ---- aggregate the whole DB (all-time, including offline players) ----
    $allSessions = New-Object System.Collections.Generic.List[object]
    $byPlayer = @{}
    foreach ($k in $db.Sessions.Keys) {
        $s = $db.Sessions[$k]
        $obj = [PSCustomObject]@{ Name=$s.Name; SteamId=$s.SteamId; Ip=$s.Ip; Start=[datetime]$s.Start; End=[datetime]$s.End; Open=[bool]$s.Open; DurationSec=[int]$s.DurationSec }
        $allSessions.Add($obj)
        if (-not $byPlayer.ContainsKey($s.SteamId)) { $byPlayer[$s.SteamId] = New-Object System.Collections.Generic.List[object] }
        $byPlayer[$s.SteamId].Add($obj)
    }

    $players = New-Object System.Collections.Generic.List[object]
    $heat = New-Object 'double[,]' 7,24
    foreach ($sid in $byPlayer.Keys) {
        $sess = @($byPlayer[$sid] | Sort-Object Start)
        $total   = ($sess | Measure-Object DurationSec -Sum).Sum
        $longest = ($sess | Measure-Object DurationSec -Maximum).Maximum
        $latest  = $sess[-1]
        $online  = [bool]($sess | Where-Object { $_.Open -and ($onlineIps -contains $_.Ip) })
        $name    = if ($SatNickMap.ContainsKey($sid)) { $SatNickMap[$sid] } elseif ($latest.Name) { $latest.Name } else { "Steam $sid" }
        foreach ($s in $sess) { $cur = $s.Start; while ($cur -lt $s.End) { $heat[[int]$cur.DayOfWeek, $cur.Hour] += 1; $cur = $cur.AddMinutes(1) } }
        $players.Add([PSCustomObject]@{
            Name         = $name
            SteamId      = $sid
            Ip           = $latest.Ip
            Online       = $online
            TotalSeconds = [int]$total
            Sessions     = $sess.Count
            LongestSec   = [int]$longest
            AvgSec       = [int]($total / [Math]::Max(1, $sess.Count))
            FirstSeen    = ($sess | Sort-Object Start | Select-Object -First 1).Start.ToString('o')
            LastSeen     = if ($online) { $now.ToString('o') } else { ($sess | Sort-Object End | Select-Object -Last 1).End.ToString('o') }
            CurrentSince = if ($online) { ($sess | Where-Object Open | Sort-Object Start | Select-Object -First 1).Start.ToString('o') } else { $null }
        })
    }

    # peak concurrency over all sessions
    $points = New-Object System.Collections.Generic.List[object]
    foreach ($s in $allSessions) { $points.Add([PSCustomObject]@{ T = $s.Start; D = 1 }); $points.Add([PSCustomObject]@{ T = $s.End; D = -1 }) }
    $peak = 0; $cc = 0; $peakAt = $null
    foreach ($p in ($points | Sort-Object T)) { $cc += $p.D; if ($cc -gt $peak) { $peak = $cc; $peakAt = $p.T } }

    $heatRows = @()
    for ($d = 0; $d -lt 7; $d++) { $row = @(); for ($h = 0; $h -lt 24; $h++) { $row += [int]$heat[$d,$h] }; $heatRows += ,$row }

    [PSCustomObject]@{
        Players     = $players | Sort-Object TotalSeconds -Descending
        Sessions    = $allSessions | Sort-Object Start
        ReadyEvents = $ready
        Peak        = $peak
        PeakAt      = if ($peakAt) { $peakAt.ToString('o') } else { $null }
        Heatmap     = $heatRows
    }
}

# --- Who is connected right now (authoritative, from sockets) ---------------

function Get-SatOnlineConnections {
    # Each connected player holds an ESTABLISHED TCP 8888 socket. Returns the
    # list of remote IPs currently connected.
    $lines = netstat -ano | Select-String -Pattern ':8888\s' | Select-String -Pattern 'ESTABLISHED'
    $ips = @()
    foreach ($l in $lines) {
        if ($l -match '\s(\d+\.\d+\.\d+\.\d+):\d+\s+ESTABLISHED') { $ips += $Matches[1] }
    }
    return @($ips | Where-Object { $_ -ne '0.0.0.0' } | Sort-Object -Unique)
}

# --- Save info --------------------------------------------------------------

function Get-SatSaveInfo {
    $sav = Get-ChildItem $SatSaveDir -Filter '*.sav' -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $sav) { return $null }
    [PSCustomObject]@{
        File     = $sav.Name
        Bytes    = $sav.Length
        Modified = $sav.LastWriteTime.ToString('o')
    }
}

# --- Server uptime / restart history ----------------------------------------

function Start-SatServer {
    # Clears the stop flag and kicks the run-server.ps1 scheduled task. The
    # wrapper refuses to double-start, so this is safe if already running.
    if (Test-Path $SatStopFlag) { Remove-Item $SatStopFlag -Force -ErrorAction SilentlyContinue }
    Start-ScheduledTask -TaskName $SatTaskName -ErrorAction Stop
    return 'start requested'
}

function Stop-SatServer {
    # Drops the stop.flag the wrapper watches, then stops the processes so the
    # wrapper sees the flag on its next loop and exits cleanly (no auto-restart).
    Set-Content -Path $SatStopFlag -Value "stopped via dashboard $(Get-Date -Format o)" -Encoding UTF8
    Get-Process 'FactoryServer','FactoryServer-Win64-Shipping-Cmd' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    return 'stop requested'
}

function Get-SatUptimeInfo {
    param($ReadyEvents)
    $proc = Get-Process -Name $SatChildProc -ErrorAction SilentlyContinue | Select-Object -First 1
    $restarts = if ($ReadyEvents) { @($ReadyEvents).Count } else { 0 }
    [PSCustomObject]@{
        Running     = [bool]$proc
        StartedAt   = if ($proc) { $proc.StartTime.ToString('o') } else { $null }
        UptimeSec   = if ($proc) { [int]((Get-Date) - $proc.StartTime).TotalSeconds } else { 0 }
        RestartsLogged = $restarts
    }
}

# --- Backup retention + reporting -------------------------------------------

function Get-SatRetentionPlan {
    # Classifies each backup file under the grandfather-father-son policy and
    # returns, per file, whether it is kept and which bucket keeps it. Shared by
    # backup.ps1 (to prune) and the dashboard report (to explain), so they agree.
    param($Files)
    $files = @($Files)
    $now = Get-Date
    $cal = [System.Globalization.CultureInfo]::InvariantCulture.Calendar
    $keepRecent = @{}; $keepDaily = @{}; $keepWeekly = @{}; $keepMonthly = @{}

    foreach ($f in $files) {
        if (($now - $f.LastWriteTime).TotalHours -le $SatBackupKeepRecent) { $keepRecent[$f.FullName] = $true }
    }
    foreach ($g in ($files | Group-Object { $_.LastWriteTime.ToString('yyyy-MM-dd') } | Sort-Object Name -Descending | Select-Object -First $SatBackupKeepDaily)) {
        $keepDaily[($g.Group | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName] = $true
    }
    foreach ($g in ($files | Group-Object { '{0}-{1:00}' -f $_.LastWriteTime.Year, $cal.GetWeekOfYear($_.LastWriteTime,'FirstFourDayWeek','Monday') } | Sort-Object Name -Descending | Select-Object -First $SatBackupKeepWeekly)) {
        $keepWeekly[($g.Group | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName] = $true
    }
    foreach ($g in ($files | Group-Object { $_.LastWriteTime.ToString('yyyy-MM') } | Sort-Object Name -Descending | Select-Object -First $SatBackupKeepMonthly)) {
        $keepMonthly[($g.Group | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName] = $true
    }

    $plan = foreach ($f in ($files | Sort-Object LastWriteTime -Descending)) {
        $reason = if ($keepRecent[$f.FullName])  { 'recent'  }
                  elseif ($keepDaily[$f.FullName])   { 'daily'   }
                  elseif ($keepWeekly[$f.FullName])  { 'weekly'  }
                  elseif ($keepMonthly[$f.FullName]) { 'monthly' }
                  else { '' }
        [PSCustomObject]@{
            FullName = $f.FullName; Name = $f.Name; Bytes = $f.Length
            Modified = $f.LastWriteTime.ToString('o'); Keep = [bool]$reason; Reason = $reason
        }
    }
    ,@($plan)
}

# --- Event log --------------------------------------------------------------

function Write-SatEvent {
    # Appends a structured event and keeps the file bounded. Categories:
    # watchdog | restart | update | notify | version | backup | control.
    # Pass -Discord to also push it to the Discord webhook (if configured).
    param([string]$Category, [string]$Message, [ValidateSet('info','warn','error')][string]$Level = 'info', [switch]$Discord)
    $line = '{0} [{1}] [{2}] {3}' -f (Get-Date -Format 'o'), $Level.ToUpper(), $Category, $Message
    try { Add-Content -Path $SatEventLog -Value $line -Encoding UTF8 -ErrorAction Stop } catch {}
    # bound the file
    try {
        $all = @(Get-Content $SatEventLog -ErrorAction SilentlyContinue)
        if ($all.Count -gt 5000) { $all | Select-Object -Last 5000 | Set-Content $SatEventLog -Encoding UTF8 }
    } catch {}
    if ($Discord) { Send-SatDiscord -Category $Category -Message $Message -Level $Level }
}

function Send-SatDiscord {
    # Posts a formatted message to the Discord webhook. One-way, best-effort.
    param([string]$Category, [string]$Message, [string]$Level = 'info')
    if (-not $SatDiscordWebhook) { return }
    $emoji = switch ($Category) { 'watchdog' {'🔴'} 'version' {'🆕'} 'update' {'⬆️'} 'restart' {'🔄'} 'backup' {'💾'} 'notify' {'🔔'} default {'ℹ️'} }
    if ($Level -eq 'error') { $emoji = '⛔' } elseif ($Level -eq 'warn' -and $Category -notin 'watchdog','version') { $emoji = '⚠️' }
    try {
        Invoke-RestMethod -Uri $SatDiscordWebhook -Method Post -ContentType 'application/json' -TimeoutSec 10 `
            -Body (@{ content = "$emoji $Message"; username = 'Satisfactory Server Bot' } | ConvertTo-Json) | Out-Null
    } catch {}
}

function Get-SatEvents {
    param([int]$Count = 40)
    if (-not (Test-Path $SatEventLog)) { return @() }
    $rows = foreach ($l in (Get-Content $SatEventLog -Tail $Count)) {
        if ($l -match '^(\S+) \[(\w+)\] \[(\w+)\] (.*)$') {
            [PSCustomObject]@{ When = $Matches[1]; Level = $Matches[2]; Category = $Matches[3]; Message = $Matches[4] }
        }
    }
    @($rows) | Sort-Object When -Descending
}

function Send-SatNotify {
    # Logs the message and, if a Discord webhook is configured, posts it there.
    # (Vanilla servers can't message players in-game, so this is the only reach.)
    param([string]$Message)
    Write-SatEvent -Category 'notify' -Message $Message -Discord
}

# --- Watchdog ---------------------------------------------------------------

function Invoke-SatWatchdog {
    # Called by the collector each cycle. Relaunches the server if its process
    # is gone AND there is no stop.flag (i.e. it died, wasn't stopped on purpose).
    if (-not $SatWatchdog) { return }
    if (Test-Path $SatStopFlag) { return }   # intentional stop; leave it down
    $proc = Get-Process -Name $SatChildProc -ErrorAction SilentlyContinue
    if ($proc) { return }                    # healthy
    try {
        Start-SatServer | Out-Null
        Write-SatEvent -Category 'watchdog' -Message 'Server process was not running and no stop.flag was set - relaunched via scheduled task.' -Level 'warn' -Discord
    } catch {
        Write-SatEvent -Category 'watchdog' -Message "Relaunch attempt failed: $($_.Exception.Message)" -Level 'error'
    }
}

# --- Restart schedule config ------------------------------------------------

function Get-SatRestartConfig {
    $default = [PSCustomObject]@{ Enabled = $false; Frequency = 'daily'; Time = '05:00'; Update = $true; LeadMinutes = 30 }
    if (Test-Path $SatRestartConfig) {
        try {
            $c = Get-Content $SatRestartConfig -Raw | ConvertFrom-Json
            foreach ($p in 'Enabled','Frequency','Time','Update','LeadMinutes') {
                if ($null -ne $c.$p) { $default.$p = $c.$p }
            }
        } catch {}
    }
    $default
}

function Set-SatRestartConfig {
    param([bool]$Enabled, [string]$Frequency, [string]$Time, [bool]$Update, [int]$LeadMinutes)
    if ($Frequency -notin 'daily','2day','3day','weekly') { throw "Frequency must be daily|2day|3day|weekly" }
    if ($Time -notmatch '^([01]?\d|2[0-3]):[0-5]\d$')     { throw "Time must be HH:mm (24h)" }
    if ($LeadMinutes -lt 0 -or $LeadMinutes -gt 240)      { throw "LeadMinutes must be 0-240" }
    $cfg = [PSCustomObject]@{ Enabled = $Enabled; Frequency = $Frequency; Time = $Time; Update = $Update; LeadMinutes = $LeadMinutes }
    $cfg | ConvertTo-Json | Set-Content $SatRestartConfig -Encoding UTF8
    Register-SatRestartTask -Config $cfg
    $cfg
}

function Register-SatRestartTask {
    # (Re)registers the restart scheduled task from config, or removes it if disabled.
    param($Config)
    if (-not $Config) { $Config = Get-SatRestartConfig }
    Unregister-ScheduledTask -TaskName $SatRestartTask -Confirm:$false -ErrorAction SilentlyContinue
    if (-not $Config.Enabled) { return }
    $interval = switch ($Config.Frequency) { 'daily' {1} '2day' {2} '3day' {3} 'weekly' {7} default {1} }
    $pwsh = (Get-Command pwsh).Source
    $action = New-ScheduledTaskAction -Execute $pwsh `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $SatDashboard 'restart.ps1')`" -Auto"
    $trigger = New-ScheduledTaskTrigger -Daily -DaysInterval $interval -At $Config.Time
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $SatRestartTask -Description 'Scheduled Satisfactory server restart (+ optional update).' `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
}

# --- Dashboard config (Settings tab) ----------------------------------------

function Get-SatSettingsView {
    # The current editable config for the UI. NEVER includes the control token
    # (only whether one is set); the Discord webhook IS included so it can be
    # edited (the whole UI is management-network only).
    [ordered]@{
        Root             = $SatRoot
        SaveDir          = $SatSaveDir
        ChildProc        = $SatChildProc
        TaskName         = $SatTaskName
        ApiBase          = $SatApiBase
        WebPort          = $SatWebPort
        WebBinds         = @($SatWebBinds)
        BackupDir        = $SatBackupDir
        BackupKeepRecent = $SatBackupKeepRecent
        BackupKeepDaily  = $SatBackupKeepDaily
        BackupKeepWeekly = $SatBackupKeepWeekly
        BackupKeepMonthly= $SatBackupKeepMonthly
        Watchdog         = [bool]$SatWatchdog
        SteamCmd         = $SatSteamCmd
        SteamAppId       = $SatSteamAppId
        NickMap          = $SatNickMap
        DiscordWebhook   = $SatDiscordWebhook
        HasToken         = ($SatControlToken -ne 'set-in-secrets.local.ps1' -and $SatControlToken.Length -gt 0)
        ConfigFile       = $SatConfigFile
    }
}

function Set-SatConfig {
    # Merges allowed keys into config.json (validated). Unknown keys are ignored.
    param([hashtable]$Updates)
    $cur = @{}
    if (Test-Path $SatConfigFile) {
        try { $j = Get-Content $SatConfigFile -Raw | ConvertFrom-Json; foreach ($p in $j.PSObject.Properties) { $cur[$p.Name] = $p.Value } } catch {}
    }
    foreach ($k in @($Updates.Keys)) { if ($SatConfigKeys -contains $k) { $cur[$k] = $Updates[$k] } }

    if ($null -ne $cur.WebPort) { $p = [int]$cur.WebPort; if ($p -lt 1 -or $p -gt 65535) { throw 'WebPort must be 1-65535' }; $cur.WebPort = $p }
    foreach ($rk in 'BackupKeepRecent','BackupKeepDaily','BackupKeepWeekly','BackupKeepMonthly') {
        if ($null -ne $cur.$rk) { $cur.$rk = [int]$cur.$rk; if ($cur.$rk -lt 0) { throw "$rk must be >= 0" } }
    }
    if ($null -ne $cur.Watchdog) { $cur.Watchdog = [bool]$cur.Watchdog }
    if ($cur.WebBinds) { $cur.WebBinds = @($cur.WebBinds | Where-Object { "$_".Trim() }) }
    if (-not $cur.Root)    { throw 'Root path cannot be empty' }
    if (-not $cur.ApiBase) { throw 'ApiBase cannot be empty' }

    $cur | ConvertTo-Json -Depth 6 | Set-Content $SatConfigFile -Encoding UTF8
}

function Set-SatSecrets {
    # Rewrites secrets.local.ps1. $null leaves a value unchanged; '' clears it.
    param($ControlToken, $DiscordWebhook)
    $tok = if ($null -ne $ControlToken -and "$ControlToken".Trim()) { "$ControlToken" } else { $SatControlToken }
    if ($tok -eq 'set-in-secrets.local.ps1') { $tok = '' }
    $wh  = if ($null -ne $DiscordWebhook) { "$DiscordWebhook" } else { $SatDiscordWebhook }
    $tokEsc = $tok -replace "'", "''"; $whEsc = $wh -replace "'", "''"
    $file = Join-Path $SatDashboard 'secrets.local.ps1'
    @"
# Local secrets - gitignored, do NOT commit.
`$Global:SatControlToken   = '$tokEsc'
`$Global:SatDiscordWebhook = '$whEsc'
"@ | Set-Content $file -Encoding UTF8
}

# --- Server version tracking ------------------------------------------------

function Get-SatServerVersion {
    # Human version + changelist from the log's startup banner, plus the Steam
    # build id from the app manifest. Both change when the server updates.
    $ver = $null; $cl = $null; $engine = $null
    $logs = @()
    if (Test-Path "$SatLogFile.old") { $logs += "$SatLogFile.old" }
    if (Test-Path $SatLogFile)       { $logs += $SatLogFile }
    foreach ($lf in $logs) {
        foreach ($line in (Read-SatLogLines $lf)) {
            if ($line -match 'Build:\s*\+\+FactoryGame\+rel-main-([0-9.]+)-CL-(\d+)') { $ver = $Matches[1]; $cl = $Matches[2] }
            elseif ($line -match 'Engine Version:\s*([0-9.]+)') { $engine = $Matches[1] }
        }
    }
    $build = $null
    $acf = Join-Path $SatRoot "steamapps\appmanifest_$SatSteamAppId.acf"
    if (Test-Path $acf) { if ((Get-Content $acf -Raw) -match '"buildid"\s*"(\d+)"') { $build = $Matches[1] } }
    [PSCustomObject]@{
        Version = $ver
        CL      = $cl
        Engine  = $engine
        Build   = $build
        Display = if ($ver) { "$ver" + $(if ($cl) { " (CL $cl)" } else { '' }) } elseif ($build) { "build $build" } else { 'unknown' }
    }
}

function Update-SatVersionTracking {
    # Compares the running version to the last recorded one; on a change (or the
    # first sighting) it writes a 'version' event and appends to version-history.
    $v = Get-SatServerVersion
    if (-not $v.CL -and -not $v.Build) { return $v }
    $key = '{0}|{1}|{2}' -f $v.Version, $v.CL, $v.Build
    $stateFile = Join-Path $SatDataDir '_version.json'
    $histFile  = Join-Path $SatDataDir 'version-history.jsonl'
    $prev = $null
    if (Test-Path $stateFile) { try { $prev = Get-Content $stateFile -Raw | ConvertFrom-Json } catch {} }

    $changed = $false; $kind = ''
    if (-not $prev) { $changed = $true; $kind = 'initial' }
    elseif (('{0}|{1}|{2}' -f $prev.Version, $prev.CL, $prev.Build) -ne $key) { $changed = $true; $kind = 'change' }

    if ($changed) {
        if ($kind -eq 'initial') {
            Write-SatEvent -Category 'version' -Message "Now tracking server version $($v.Display) [Steam build $($v.Build)]."
        } else {
            $oldDisp = if ($prev.Version) { "$($prev.Version)" + $(if ($prev.CL) { " (CL $($prev.CL))" } else { '' }) } else { "build $($prev.Build)" }
            Write-SatEvent -Category 'version' -Message "Server updated: $oldDisp -> $($v.Display) [Steam build $($prev.Build) -> $($v.Build)]." -Level 'warn' -Discord
        }
        ([PSCustomObject]@{ t = (Get-Date).ToString('o'); version = $v.Version; cl = $v.CL; build = $v.Build; engine = $v.Engine; kind = $kind } |
            ConvertTo-Json -Compress) | Add-Content -Path $histFile -Encoding UTF8
        $v | ConvertTo-Json | Set-Content $stateFile -Encoding UTF8
    }
    $v
}

function Get-SatVersionHistory {
    param([int]$Count = 20)
    $histFile = Join-Path $SatDataDir 'version-history.jsonl'
    if (-not (Test-Path $histFile)) { return @() }
    $rows = foreach ($l in (Get-Content $histFile -Tail $Count)) { try { $l | ConvertFrom-Json } catch {} }
    @($rows) | Sort-Object t -Descending
}

# --- SteamCMD update --------------------------------------------------------

function Update-SatServer {
    # Runs a SteamCMD app_update validate. The caller is responsible for having
    # stopped the server first. Returns $true on success.
    if (-not (Test-Path $SatSteamCmd)) { Write-SatEvent -Category 'update' -Message "SteamCMD not found at $SatSteamCmd" -Level 'error'; return $false }
    Write-SatEvent -Category 'update' -Message "Starting SteamCMD app_update $SatSteamAppId validate..."
    $args = @('+force_install_dir', $SatRoot, '+login', 'anonymous', '+app_update', $SatSteamAppId, 'validate', '+quit')
    $out = & $SatSteamCmd @args 2>&1
    $successLine = $out | Where-Object { $_ -match 'fully installed|already up to date' } | Select-Object -Last 1
    if ($successLine) {
        Write-SatEvent -Category 'update' -Message "Update complete. $($successLine.ToString().Trim())"
        return $true
    }
    $tail = ($out | Where-Object { $_ -and "$_".Trim() } | Select-Object -Last 1)
    Write-SatEvent -Category 'update' -Message "Update finished but success not confirmed. Last line: $tail" -Level 'warn'
    return $true
}

function Get-SatBackupReport {
    # Everything the Backups tab needs: inventory + retention plan + run history.
    $files = @(Get-ChildItem $SatBackupDir -Filter '*.sav' -ErrorAction SilentlyContinue)
    $plan  = if ($files.Count) { Get-SatRetentionPlan -Files $files } else { @() }
    $total = ($files | Measure-Object Length -Sum).Sum
    $newest = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $oldest = $files | Sort-Object LastWriteTime | Select-Object -First 1

    # parse the structured history log written by backup.ps1
    $history = New-Object System.Collections.Generic.List[object]
    if (Test-Path $SatBackupHistoryLog) {
        $raw = Get-Content $SatBackupHistoryLog -Raw -ErrorAction SilentlyContinue
        foreach ($m in [regex]::Matches($raw, '(?m)^\s*(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) - (SUCCESS|FAILED) \(([^)]+)\)\s*\[trigger: ([^\]]+)\]')) {
            $history.Add([PSCustomObject]@{ When = $m.Groups[1].Value; Verdict = $m.Groups[2].Value; Duration = $m.Groups[3].Value.Trim(); Trigger = $m.Groups[4].Value })
        }
    }
    $ok = @($history | Where-Object Verdict -eq 'SUCCESS').Count

    $task = Get-ScheduledTask -TaskName 'Satisfactory Dashboard Backup' -ErrorAction SilentlyContinue
    $next = if ($task) { ($task | Get-ScheduledTaskInfo).NextRunTime } else { $null }

    [PSCustomObject]@{
        Dir        = $SatBackupDir
        Count      = $files.Count
        TotalBytes = [long]$total
        Newest     = if ($newest) { $newest.LastWriteTime.ToString('o') } else { $null }
        NewestName = if ($newest) { $newest.Name } else { $null }
        Oldest     = if ($oldest) { $oldest.LastWriteTime.ToString('o') } else { $null }
        NextRun    = if ($next) { $next.ToString('o') } else { $null }
        Policy     = [PSCustomObject]@{ RecentHours = $SatBackupKeepRecent; Daily = $SatBackupKeepDaily; Weekly = $SatBackupKeepWeekly; Monthly = $SatBackupKeepMonthly }
        Files      = @($plan | Select-Object Name, Bytes, Modified, Keep, Reason)
        History    = @($history | Sort-Object When -Descending | Select-Object -First 15)
        Runs       = $history.Count
        Successes  = $ok
        WouldPrune = @($plan | Where-Object { -not $_.Keep }).Count
    }
}
