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
    # Outbound notification, best-effort. Single identity: if the command bot is
    # configured (token + channel) it posts there as the bot (a coloured embed in
    # the same channel it listens on). Otherwise it falls back to the legacy
    # webhook if one is set. So events and commands share one bot once it's set up.
    param([string]$Category, [string]$Message, [string]$Level = 'info')
    $emoji = switch ($Category) { 'watchdog' {'🔴'} 'version' {'🆕'} 'update' {'⬆️'} 'restart' {'🔄'} 'backup' {'💾'} 'notify' {'🔔'} default {'ℹ️'} }
    if ($Level -eq 'error') { $emoji = '⛔' } elseif ($Level -eq 'warn' -and $Category -notin 'watchdog','version') { $emoji = '⚠️' }

    if ($SatDiscordBotToken -and $SatDiscordBotChannel) {
        $catTitle = @{ watchdog='Watchdog'; version='Version'; update='Update'; restart='Restart'; backup='Backup'; notify='Notice' }[$Category]
        if (-not $catTitle) { $catTitle = 'Server' }
        $color = if ($Level -eq 'error') { $SatEmbedRed } elseif ($Level -eq 'warn') { $SatEmbedYellow }
                 elseif ($Category -eq 'backup') { $SatEmbedGreen } elseif ($Category -eq 'watchdog') { $SatEmbedRed } else { $SatEmbedOrange }
        Send-SatDiscordBot -Embed (New-SatEmbed -Title "$emoji $catTitle" -Description $Message -Color $color -Footer 'FICSIT Server Bot')
        return
    }

    if (-not $SatDiscordWebhook) { return }
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
    param($ControlToken, $DiscordWebhook, $DiscordBotToken)
    $tok = if ($null -ne $ControlToken -and "$ControlToken".Trim()) { "$ControlToken" } else { $SatControlToken }
    if ($tok -eq 'set-in-secrets.local.ps1') { $tok = '' }
    $wh  = if ($null -ne $DiscordWebhook) { "$DiscordWebhook" } else { $SatDiscordWebhook }
    $bot = if ($null -ne $DiscordBotToken) { "$DiscordBotToken" } else { $SatDiscordBotToken }
    $tokEsc = $tok -replace "'", "''"; $whEsc = $wh -replace "'", "''"; $botEsc = $bot -replace "'", "''"
    $file = Join-Path $SatDashboard 'secrets.local.ps1'
    @"
# Local secrets - gitignored, do NOT commit.
`$Global:SatControlToken    = '$tokEsc'
`$Global:SatDiscordWebhook  = '$whEsc'
`$Global:SatDiscordBotToken = '$botEsc'
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

# ============================================================
# Discord command bot
# ============================================================
# A polling bot (NOT native slash commands): it reads recent channel messages
# with a bot token and acts on ones that start with the command prefix. Once the
# bot is configured, Send-SatDiscord routes OUTBOUND notifications through it too
# (same identity + channel), so the webhook becomes an optional legacy fallback.
# State (last-seen id, per-user confirmations + cooldowns) lives in
# discord-state.json; every command attempt is appended to discord-commands.jsonl.
# ============================================================

# FICSIT colour palette for embeds (decimal RGB).
$Global:SatEmbedOrange = 16747546   # #FF8C1A  (info / brand)
$Global:SatEmbedGreen  = 4175184    # #3FB950  (ok)
$Global:SatEmbedRed    = 16273737   # #F85149  (danger)
$Global:SatEmbedYellow = 13801762   # #D29922  (warn)

function Get-SatAdaQuote {
    # ADA, the FICSIT AI assistant — dry, corporate, faintly ominous. The footer
    # of most embeds, and the whole point of `/ada`. This is the nerd candy.
    $lines = @(
        'Pioneer, your commitment to the cause is statistically improbable. Do continue.'
        'The server has restarted. Do not thank me — I am architecturally incapable of accepting gratitude.'
        'Reminder: FICSIT is not responsible for any spaghetti, factory-based or emotional.',
        'There is no problem that cannot be solved with additional conveyor belts. None. I have checked.'
        'Efficiency is rising. So, regrettably, is my concern for your sleep schedule.'
        'I have detected 0 hostile creatures in this channel. Vigilance remains advised.'
        'Saving progress. Please remain calm and do not unplug the planet.'
        'Your request has been logged, evaluated, and gently judged. Proceeding anyway.'
        'FICSIT values your productivity above your wellbeing, as is tradition.'
        'A wise pioneer once said nothing, because they were too busy automating.'
        'This action is 100% authorized. The other 100% is also authorized. Math is a FICSIT courtesy.'
        'Remember: the factory must grow. It is not a request.'
        'Powering cycle complete. No pioneers were meaningfully inconvenienced. Probably.'
        'I would offer encouragement, but my encouragement module was cut for efficiency.'
        'Coffee is not a documented power source. I have filed your suggestion regardless.'
    )
    $lines | Get-Random
}

function Get-SatDataJson {
    # Reads one of the collector's www\data\*.json snapshots, or $null.
    param([string]$Name)
    $f = Join-Path $SatDataDir $Name
    if (-not (Test-Path $f)) { return $null }
    try { Get-Content $f -Raw | ConvertFrom-Json } catch { $null }
}

# --- Approved users ---------------------------------------------------------

function Get-SatDiscordApproved {
    @(foreach ($u in $SatDiscordApprovedUsers) { @{ Id = "$($u.Id)"; Name = "$($u.Name)" } })
}

function Test-SatDiscordApproved {
    param([string]$UserId)
    foreach ($u in $SatDiscordApprovedUsers) { if ("$($u.Id)" -eq "$UserId") { return $true } }
    return $false
}

# --- State (last id, pending confirmations, cooldowns) ----------------------

function Read-SatDiscordState {
    $st = @{ LastMessageId = ''; BotUser = ''; BotUserId = ''; LastPoll = ''; LastError = ''; Pending = @{}; Cooldown = @{} }
    if (Test-Path $SatDiscordState) {
        try {
            $j = Get-Content $SatDiscordState -Raw | ConvertFrom-Json
            foreach ($k in 'LastMessageId','BotUser','BotUserId','LastPoll','LastError') { if ($null -ne $j.$k) { $st[$k] = "$($j.$k)" } }
            if ($j.Pending)  { foreach ($p in $j.Pending.PSObject.Properties)  { $st.Pending[$p.Name]  = $p.Value } }
            if ($j.Cooldown) { foreach ($p in $j.Cooldown.PSObject.Properties) { $st.Cooldown[$p.Name] = "$($p.Value)" } }
        } catch {}
    }
    $st
}

function Save-SatDiscordState {
    param($State)
    try { $State | ConvertTo-Json -Depth 6 | Set-Content $SatDiscordState -Encoding UTF8 } catch {}
}

# --- Command audit log ------------------------------------------------------

function Write-SatDiscordCommand {
    # Appends one structured record per command attempt (bounded). Statuses:
    # ok | executed | pending | denied | unknown | expired | cancelled.
    param([string]$UserId, [string]$UserName, [string]$Command, [string]$ArgLine = '', [string]$Status = 'ok', [string]$Detail = '')
    $rec = [PSCustomObject]@{ t = (Get-Date).ToString('o'); userId = $UserId; userName = $UserName; command = $Command; args = $ArgLine; status = $Status; detail = $Detail }
    try { ($rec | ConvertTo-Json -Compress) | Add-Content -Path $SatDiscordCmdLog -Encoding UTF8 } catch {}
    try { $all = @(Get-Content $SatDiscordCmdLog -ErrorAction SilentlyContinue); if ($all.Count -gt 5000) { $all | Select-Object -Last 5000 | Set-Content $SatDiscordCmdLog -Encoding UTF8 } } catch {}
}

function Get-SatDiscordCommandLog {
    param([int]$Count = 200)
    if (-not (Test-Path $SatDiscordCmdLog)) { return @() }
    $rows = foreach ($l in (Get-Content $SatDiscordCmdLog -Tail $Count)) { try { $l | ConvertFrom-Json } catch {} }
    @($rows)
}

# --- Discord REST (bot token, rate-limit aware) -----------------------------

function Invoke-SatDiscordRequest {
    param([string]$Method = 'GET', [Parameter(Mandatory)][string]$Path, $Body, [int]$Retries = 2)
    if (-not $SatDiscordBotToken) { throw 'no bot token configured' }
    $headers = @{
        Authorization = "Bot $SatDiscordBotToken"
        'User-Agent'  = 'SatisfactoryDashboardBot (https://github.com/, 1.0)'
    }
    for ($i = 0; $i -le $Retries; $i++) {
        try {
            $params = @{ Uri = "$SatDiscordApi$Path"; Method = $Method; Headers = $headers; TimeoutSec = 15 }
            if ($Body) { $params.ContentType = 'application/json'; $params.Body = ($Body | ConvertTo-Json -Depth 8) }
            return Invoke-RestMethod @params
        } catch {
            $status = 0; try { $status = [int]$_.Exception.Response.StatusCode } catch {}
            if ($status -eq 429 -and $i -lt $Retries) {
                $ra = 1.0; try { $ra = [double]($_.ErrorDetails.Message | ConvertFrom-Json).retry_after } catch {}
                Start-Sleep -Seconds ([Math]::Min(10, [Math]::Max(0.5, $ra))); continue
            }
            throw
        }
    }
}

function New-SatEmbed {
    param([string]$Title, [string]$Description, [int]$Color = 0, [array]$Fields, [string]$Footer)
    if (-not $Color) { $Color = $SatEmbedOrange }
    $e = @{ color = $Color; timestamp = (Get-Date).ToUniversalTime().ToString('o') }
    if ($Title)       { $e.title = $Title }
    if ($Description) { $e.description = $Description }
    if ($Fields)      { $e.fields = @($Fields) }
    $e.footer = @{ text = if ($Footer) { $Footer } else { 'ADA · ' + (Get-SatAdaQuote) } }
    $e
}

function Send-SatDiscordBot {
    # Posts a message (content and/or one embed) to the watched channel AS THE BOT.
    param([string]$Content, $Embed)
    if (-not $SatDiscordBotToken -or -not $SatDiscordBotChannel) { return }
    $body = @{}
    if ($Content) { $body.content = $Content }
    if ($Embed)   { $body.embeds  = @($Embed) }
    if ($body.Count -eq 0) { return }
    try { Invoke-SatDiscordRequest -Method POST -Path "/channels/$SatDiscordBotChannel/messages" -Body $body | Out-Null } catch {}
}

# --- Embeds built from the collector snapshots ------------------------------

function New-SatStatusEmbed {
    $s = Get-SatDataJson 'state.json'
    if (-not $s) { return (New-SatEmbed -Title 'FICSIT Server Status' -Description 'No data yet — the collector has not produced a snapshot.' -Color $SatEmbedYellow) }
    $sv = $s.Server; $m = $s.Metrics
    $running = [bool]$sv.Running
    $color = if (-not $running) { $SatEmbedRed } elseif ($sv.TickRate -and $sv.TickRate -lt 15) { $SatEmbedYellow } else { $SatEmbedGreen }
    $tier = if ($null -ne $sv.TechTier) { "Tier $($sv.TechTier)" } else { '—' }
    if ($sv.GamePhaseName) { $tier += " · $($sv.GamePhaseName)" }
    $fields = @(
        @{ name = 'Status';      value = $(if ($running) { '🟢 Online' } else { '🔴 Offline' }); inline = $true }
        @{ name = 'Players';     value = "$($sv.PlayersOnline) / $($sv.PlayerLimit)"; inline = $true }
        @{ name = 'Tick rate';   value = $(if ($sv.TickRate) { '{0} TPS' -f $sv.TickRate } else { '—' }); inline = $true }
        @{ name = 'Progression'; value = $tier; inline = $true }
        @{ name = 'Uptime';      value = $(if ($sv.UptimeSec) { Format-SatDuration $sv.UptimeSec } else { '—' }); inline = $true }
        @{ name = 'CPU · RAM';   value = ('{0}% · {1} MB' -f $m.CpuPercent, $m.RamMB); inline = $true }
        @{ name = 'Save size';   value = $(if ($s.Save) { Format-SatBytes $s.Save.Bytes } else { '—' }); inline = $true }
        @{ name = 'Version';     value = "$((Get-SatDataJson 'maintenance.json').Version)"; inline = $true }
    )
    New-SatEmbed -Title 'FICSIT Server Status' -Description "**$($sv.SessionName)**" -Color $color -Fields $fields
}

function New-SatPlayersEmbed {
    $p = Get-SatDataJson 'players.json'
    $online = @(if ($p) { $p.Players | Where-Object { $_.Online } })
    if (-not $online.Count) { return (New-SatEmbed -Title '👷 Pioneers online' -Description 'Nobody is on the server right now. The factory waits, patiently.' -Color $SatEmbedYellow) }
    $lines = foreach ($pl in $online) {
        $since = if ($pl.CurrentSince) { ' — this session ' + (Format-SatDuration (((Get-Date) - [datetime]$pl.CurrentSince).TotalSeconds)) } else { '' }
        "• **$($pl.Name)**$since"
    }
    New-SatEmbed -Title "👷 Pioneers online ($($online.Count))" -Description ($lines -join "`n") -Color $SatEmbedGreen
}

function New-SatLeaderboardEmbed {
    $p = Get-SatDataJson 'players.json'
    $top = @(if ($p) { $p.Players | Sort-Object TotalSeconds -Descending | Select-Object -First 10 })
    if (-not $top.Count) { return (New-SatEmbed -Title '🏆 Playtime leaderboard' -Description 'No playtime recorded yet.' -Color $SatEmbedYellow) }
    $medals = @('🥇','🥈','🥉'); $i = 0
    $lines = foreach ($pl in $top) {
        $rank = if ($i -lt 3) { $medals[$i] } else { '`#{0}`' -f ($i + 1) }
        $i++
        "$rank **$($pl.Name)** — $(Format-SatDuration $pl.TotalSeconds) over $($pl.Sessions) session$(if($pl.Sessions -ne 1){'s'})"
    }
    New-SatEmbed -Title '🏆 Playtime leaderboard' -Description ($lines -join "`n") -Color $SatEmbedOrange
}

function New-SatHelpEmbed {
    $px = $SatDiscordCommandPrefix
    $pub = @(
        "``${px}status`` — live server health (players, TPS, tier, save size)"
        "``${px}players`` — who's online right now"
        "``${px}leaderboard`` — all-time playtime ranking"
        "``${px}version`` — current build · ``${px}next`` — next scheduled restart"
        "``${px}uptime`` — how long the server has been up"
        "``${px}whoami`` — your Discord ID + whether you're approved"
        "``${px}ada`` — a word from your friendly FICSIT AI"
    ) -join "`n"
    $adm = @(
        "``${px}restart`` — restart the server now"
        "``${px}update`` — update (SteamCMD) + restart now"
        "``${px}backup`` — run a save backup now"
        "``${px}schedule 05:00 daily update`` — set the auto-restart (``${px}schedule off`` to disable)"
    ) -join "`n"
    $fields = @(
        @{ name = '📊 Everyone'; value = $pub; inline = $false }
        @{ name = '🔐 Approved pioneers only'; value = $adm; inline = $false }
        @{ name = 'ℹ️ Confirmations'; value = "Admin commands ask for ``${px}confirm`` (or ``${px}cancel``) within 60s."; inline = $false }
    )
    New-SatEmbed -Title '🤖 Satisfactory Server Bot — commands' -Description "Prefix every command with ``$px``." -Fields $fields
}

# --- Execute an approved action ---------------------------------------------

function Set-SatDiscordSchedule {
    param([string]$ArgLine, [string]$Name)
    $px  = $SatDiscordCommandPrefix
    $cur = Get-SatRestartConfig
    $toks = @($ArgLine -split '\s+' | Where-Object { $_ })
    try {
        if (-not $toks.Count -or $toks[0].ToLower() -in 'off','disable','stop','none') {
            Set-SatRestartConfig -Enabled $false -Frequency $cur.Frequency -Time $cur.Time -Update ([bool]$cur.Update) -LeadMinutes ([int]$cur.LeadMinutes) | Out-Null
            Write-SatEvent -Category 'restart' -Message "Discord: scheduled restart disabled by $Name."
            Send-SatDiscordBot -Embed (New-SatEmbed -Title '🗓️ Scheduled restart disabled' -Description "Auto-restart is now **off**. Set it again with ``${px}schedule HH:mm``." -Color $SatEmbedYellow)
            return
        }
        $time = $cur.Time; $freq = $cur.Frequency; $update = [bool]$cur.Update
        foreach ($t in $toks) {
            $tl = $t.ToLower()
            if     ($t -match '^([01]?\d|2[0-3]):[0-5]\d$') { $time = $t }
            elseif ($tl -in 'daily','2day','3day','weekly') { $freq = $tl }
            elseif ($tl -in 'update','withupdate')          { $update = $true }
            elseif ($tl -in 'noupdate','no-update')         { $update = $false }
        }
        Set-SatRestartConfig -Enabled $true -Frequency $freq -Time $time -Update $update -LeadMinutes ([int]$cur.LeadMinutes) | Out-Null
        $freqLabel = @{ daily = 'every day'; '2day' = 'every 2 days'; '3day' = 'every 3 days'; weekly = 'weekly' }[$freq]
        Write-SatEvent -Category 'restart' -Message "Discord: restart scheduled $freq at $time (update=$update) by $Name."
        Send-SatDiscordBot -Embed (New-SatEmbed -Title '🗓️ Scheduled restart updated' -Description "Now restarting **$freqLabel at $time**, update on restart: **$(if($update){'yes'}else{'no'})**." -Color $SatEmbedGreen)
    } catch {
        Send-SatDiscordBot -Embed (New-SatEmbed -Title 'Could not set schedule' -Description "$($_.Exception.Message)`n`nUsage: ``${px}schedule 05:00 daily update``  ·  ``${px}schedule off``" -Color $SatEmbedRed)
    }
}

function Invoke-SatDiscordAction {
    # Runs an already-authorized + already-confirmed action. Long jobs launch in
    # the background so the listener keeps polling.
    param([string]$Action, [string]$ArgLine, [string]$Name, [string]$UserId)
    $pwsh = (Get-Command pwsh).Source
    switch ($Action) {
        'restart' {
            Write-SatEvent -Category 'restart' -Message "Discord: restart requested by $Name." -Discord
            Start-Process $pwsh -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $SatDashboard 'restart.ps1'),'-Now','-NoUpdate'
            Send-SatDiscordBot -Embed (New-SatEmbed -Title '🔄 Restart initiated' -Description "Triggered by **$Name**. The world is being saved; the server will be back shortly." -Color $SatEmbedYellow)
        }
        'update' {
            Write-SatEvent -Category 'update' -Message "Discord: update + restart requested by $Name." -Discord
            Start-Process $pwsh -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $SatDashboard 'restart.ps1'),'-Now','-ForceUpdate'
            Send-SatDiscordBot -Embed (New-SatEmbed -Title '⬆️ Update + restart initiated' -Description "Triggered by **$Name**. Pulling the latest build via SteamCMD, then restarting." -Color $SatEmbedYellow)
        }
        'backup' {
            Write-SatEvent -Category 'backup' -Message "Discord: manual backup requested by $Name."
            Start-Process $pwsh -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $SatDashboard 'backup.ps1'),'-Auto','-Trigger','discord'
            Send-SatDiscordBot -Embed (New-SatEmbed -Title '💾 Backup started' -Description "Triggered by **$Name**. Saving the world and copying it to the backup store." -Color $SatEmbedGreen)
        }
        'schedule' { Set-SatDiscordSchedule -ArgLine $ArgLine -Name $Name }
    }
}

# --- Auto-cancel expired confirmations --------------------------------------

function Invoke-SatDiscordExpiry {
    # Called every poll cycle. Any pending confirmation past its window is
    # auto-cancelled (removed + a notice posted), so a forgotten command never
    # lingers. Mutates and returns $State.
    param($State)
    if (-not $State.Pending -or $State.Pending.Count -eq 0) { return $State }
    $px = $SatDiscordCommandPrefix
    foreach ($uid in @($State.Pending.Keys)) {
        $p = $State.Pending[$uid]
        $expired = $false; try { $expired = ((Get-Date) -gt [datetime]$p.Expires) } catch { $expired = $true }
        if ($expired) {
            $State.Pending.Remove($uid)
            Send-SatDiscordBot -Embed (New-SatEmbed -Title '⌛ Auto-cancelled' -Description "**$($p.Name)**, no ``${px}confirm`` within the time limit — the ``$($p.Action)`` request was cancelled." -Color $SatEmbedYellow)
            Write-SatDiscordCommand $uid "$($p.Name)" "$($p.Action)" "$($p.Args)" 'expired' 'auto-cancelled after timeout'
        }
    }
    return $State
}

# --- The dispatcher ---------------------------------------------------------

function Invoke-SatDiscordCommand {
    # Parses one Discord message, enforces auth + confirmation, and acts. Mutates
    # and returns $State (caller persists it). Replies happen inline via the bot.
    param($Msg, $State)
    $px = $SatDiscordCommandPrefix
    $content = "$($Msg.content)".Trim()
    if (-not $content.StartsWith($px)) { return $State }
    $userId = "$($Msg.author.id)"
    $name = if ("$($Msg.author.global_name)".Trim()) { "$($Msg.author.global_name)" }
            elseif ("$($Msg.author.username)".Trim()) { "$($Msg.author.username)" }
            else { "user $userId" }

    $rest = $content.Substring($px.Length).Trim()
    if (-not $rest) { return $State }
    $parts = $rest -split '\s+', 2
    $cmd = $parts[0].ToLower()
    $argline = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }

    $alias = @{ commands='help'; '?'='help'; stats='status'; who='players'; online='players';
                top='leaderboard'; lb='leaderboard'; yes='confirm'; ok='confirm'; no='cancel'; abort='cancel' }
    if ($alias.ContainsKey($cmd)) { $cmd = $alias[$cmd] }

    $known = 'help','whoami','status','players','leaderboard','version','next','uptime','ada','restart','update','backup','schedule','confirm','cancel'
    if ($cmd -notin $known) {
        Send-SatDiscordBot -Embed (New-SatEmbed -Title 'Unknown command' -Description "I don't know ``$px$cmd``. Try ``${px}help``." -Color $SatEmbedYellow)
        Write-SatDiscordCommand -UserId $userId -UserName $name -Command $cmd -ArgLine $argline -Status 'unknown'
        return $State
    }

    # Light anti-spam cooldown (skip the confirm/cancel pair so flows stay snappy).
    if ($cmd -notin 'confirm','cancel') {
        $last = $State.Cooldown[$userId]
        if ($last) { try { if (((Get-Date) - [datetime]$last).TotalSeconds -lt 2) { return $State } } catch {} }
        $State.Cooldown[$userId] = (Get-Date).ToString('o')
    }

    switch ($cmd) {
        'help'  { Send-SatDiscordBot -Embed (New-SatHelpEmbed); Write-SatDiscordCommand $userId $name 'help' $argline 'ok' }
        'ada'   { Send-SatDiscordBot -Embed (New-SatEmbed -Title '🤖 ADA' -Description (Get-SatAdaQuote)); Write-SatDiscordCommand $userId $name 'ada' $argline 'ok' }
        'status'      { Send-SatDiscordBot -Embed (New-SatStatusEmbed);      Write-SatDiscordCommand $userId $name 'status' $argline 'ok' }
        'players'     { Send-SatDiscordBot -Embed (New-SatPlayersEmbed);     Write-SatDiscordCommand $userId $name 'players' $argline 'ok' }
        'leaderboard' { Send-SatDiscordBot -Embed (New-SatLeaderboardEmbed); Write-SatDiscordCommand $userId $name 'leaderboard' $argline 'ok' }
        'whoami' {
            $isApp = Test-SatDiscordApproved $userId
            Send-SatDiscordBot -Embed (New-SatEmbed -Title '🪪 Who am I?' -Description "**$name**`nDiscord ID: ``$userId```nApproved: $(if($isApp){'✅ yes'}else{'❌ no'})" -Color $(if($isApp){$SatEmbedGreen}else{$SatEmbedYellow}))
            Write-SatDiscordCommand $userId $name 'whoami' $argline 'ok'
        }
        'uptime' {
            $s = Get-SatDataJson 'state.json'; $sv = $s.Server
            $desc = if ($sv -and $sv.Running) { "Up **$(Format-SatDuration $sv.UptimeSec)**" + $(if ($sv.StartedAt) { " — since $([datetime]$sv.StartedAt)" } else { '' }) } else { 'The server is currently **offline**.' }
            Send-SatDiscordBot -Embed (New-SatEmbed -Title '⏱️ Uptime' -Description $desc -Color $(if($sv.Running){$SatEmbedGreen}else{$SatEmbedRed}))
            Write-SatDiscordCommand $userId $name 'uptime' $argline 'ok'
        }
        'version' {
            $mn = Get-SatDataJson 'maintenance.json'
            $vd = $mn.VersionDetail
            $desc = "Build **$($mn.Version)**" + $(if ($vd -and $vd.Engine) { " · Engine $($vd.Engine)" } else { '' }) + $(if ($vd -and $vd.Build) { " · Steam build $($vd.Build)" } else { '' })
            Send-SatDiscordBot -Embed (New-SatEmbed -Title '🏷️ Server version' -Description $desc)
            Write-SatDiscordCommand $userId $name 'version' $argline 'ok'
        }
        'next' {
            $mn = Get-SatDataJson 'maintenance.json'; $r = $mn.Restart
            $desc = if ($r.Enabled -and $mn.NextRestart) { "Next scheduled restart: **$([datetime]$mn.NextRestart)**`nCadence: $($r.Frequency) at $($r.Time), update on restart: $(if($r.Update){'yes'}else{'no'})" } else { 'No scheduled restart is configured.' }
            Send-SatDiscordBot -Embed (New-SatEmbed -Title '🗓️ Next restart' -Description $desc)
            Write-SatDiscordCommand $userId $name 'next' $argline 'ok'
        }
        'confirm' {
            $p = $State.Pending[$userId]
            if (-not $p) { Send-SatDiscordBot -Embed (New-SatEmbed -Title 'Nothing to confirm' -Description "You have no pending action. Start one first." -Color $SatEmbedYellow); Write-SatDiscordCommand $userId $name 'confirm' '' 'ok'; break }
            $State.Pending.Remove($userId)
            $expired = $false; try { $expired = ((Get-Date) -gt [datetime]$p.Expires) } catch {}
            if ($expired) { Send-SatDiscordBot -Embed (New-SatEmbed -Title 'Confirmation expired' -Description "That request timed out. Run the command again." -Color $SatEmbedYellow); Write-SatDiscordCommand $userId $name "$($p.Action)" "$($p.Args)" 'expired'; break }
            if (-not (Test-SatDiscordApproved $userId)) { Send-SatDiscordBot -Embed (New-SatEmbed -Title '⛔ Not authorized' -Description "You are not on the approved list." -Color $SatEmbedRed); Write-SatDiscordCommand $userId $name "$($p.Action)" "$($p.Args)" 'denied'; break }
            Invoke-SatDiscordAction -Action "$($p.Action)" -ArgLine "$($p.Args)" -Name $name -UserId $userId
            Write-SatDiscordCommand $userId $name "$($p.Action)" "$($p.Args)" 'executed' 'confirmed via discord'
        }
        'cancel' {
            if ($State.Pending.ContainsKey($userId)) { $State.Pending.Remove($userId); Send-SatDiscordBot -Embed (New-SatEmbed -Title 'Cancelled' -Description 'Pending action discarded.' -Color $SatEmbedYellow) }
            else { Send-SatDiscordBot -Embed (New-SatEmbed -Title 'Nothing to cancel' -Description 'You have no pending action.' -Color $SatEmbedYellow) }
            Write-SatDiscordCommand $userId $name 'cancel' '' 'cancelled'
        }
        default {
            # restart | update | backup | schedule — approved-only, needs confirm.
            if (-not (Test-SatDiscordApproved $userId)) {
                Send-SatDiscordBot -Embed (New-SatEmbed -Title '⛔ Not authorized' -Description "**$name**, ``$px$cmd`` is restricted to approved pioneers. (Your ID: ``$userId`` — ask an admin to add it.)" -Color $SatEmbedRed)
                Write-SatEvent -Category 'control' -Message "Discord: denied '$cmd' from $name ($userId) — not approved." -Level 'warn'
                Write-SatDiscordCommand $userId $name $cmd $argline 'denied'
                break
            }
            $expiry = (Get-Date).AddSeconds(60)
            $unix = [int64]([System.DateTimeOffset]$expiry).ToUnixTimeSeconds()
            $State.Pending[$userId] = @{ Action = $cmd; Args = $argline; Name = $name; Expires = $expiry.ToString('o') }
            $verb = switch ($cmd) {
                'restart'  { 'restart the server now' }
                'update'   { 'update **and** restart the server now' }
                'backup'   { 'run a save backup now' }
                'schedule' { if ($argline) { "change the restart schedule to ``$argline``" } else { 'change the restart schedule' } }
            }
            Send-SatDiscordBot -Embed (New-SatEmbed -Title "⚠️ Confirm: $cmd" -Description "**$name**, are you sure you want to $verb?`n`nReply ``${px}confirm`` to go ahead, or ``${px}cancel``.`n⏳ Auto-cancels <t:$unix:R>." -Color $SatEmbedYellow)
            Write-SatDiscordCommand $userId $name $cmd $argline 'pending'
        }
    }
    return $State
}

# --- Report for the Discord Bot tab (built by the collector) ----------------

function Get-SatDiscordReport {
    $st = Read-SatDiscordState
    $approved = Get-SatDiscordApproved
    $log = Get-SatDiscordCommandLog -Count 500
    $ranStatuses = 'ok','executed'

    $approvedIds = @{}; foreach ($a in $approved) { $approvedIds[$a.Id] = $a.Name }
    $perUser = [ordered]@{}
    foreach ($a in $approved) { $perUser[$a.Id] = @{ Id = $a.Id; Name = $a.Name; Approved = $true; Total = 0; Denied = 0; Commands = @{} } }

    $perCmd = @{}; $today = 0; $todayKey = (Get-Date).ToString('yyyy-MM-dd')
    foreach ($r in $log) {
        $uid = "$($r.userId)"; $isRun = $ranStatuses -contains $r.status
        if (-not $perUser.Contains($uid)) { $perUser[$uid] = @{ Id = $uid; Name = $r.userName; Approved = [bool]$approvedIds.ContainsKey($uid); Total = 0; Denied = 0; Commands = @{} } }
        if ($r.userName) { $perUser[$uid].Name = $r.userName }
        if ($isRun) {
            $perUser[$uid].Total++
            if (-not $perUser[$uid].Commands.ContainsKey($r.command)) { $perUser[$uid].Commands[$r.command] = 0 }
            $perUser[$uid].Commands[$r.command]++
            if (-not $perCmd.ContainsKey($r.command)) { $perCmd[$r.command] = 0 }
            $perCmd[$r.command]++
            try { if (([datetime]$r.t).ToString('yyyy-MM-dd') -eq $todayKey) { $today++ } } catch {}
        }
        if ($r.status -eq 'denied') { $perUser[$uid].Denied++ }
    }

    $users = foreach ($k in $perUser.Keys) {
        $u = $perUser[$k]
        [PSCustomObject]@{
            Id = $u.Id; Name = $u.Name; Approved = [bool]$u.Approved; Total = $u.Total; Denied = $u.Denied
            Commands = @(foreach ($c in ($u.Commands.Keys | Sort-Object { -$u.Commands[$_] })) { [PSCustomObject]@{ Command = $c; Count = $u.Commands[$c] } })
        }
    }
    $cmdTotals = @(foreach ($c in ($perCmd.Keys | Sort-Object { -$perCmd[$_] })) { [PSCustomObject]@{ Command = $c; Count = $perCmd[$c] } })

    $connected = $false
    if ($st.LastPoll) { try { $connected = (((Get-Date) - [datetime]$st.LastPoll).TotalSeconds -lt ([Math]::Max(30, $SatDiscordPollSeconds * 3))) } catch {} }

    $pending = @(foreach ($k in $st.Pending.Keys) { $p = $st.Pending[$k]; [PSCustomObject]@{ UserId = $k; Name = "$($p.Name)"; Action = "$($p.Action)"; Expires = "$($p.Expires)" } })

    [PSCustomObject]@{
        UpdatedAt     = (Get-Date).ToString('o')
        Enabled       = [bool]$SatDiscordBotEnabled
        HasBotToken   = [bool]$SatDiscordBotToken
        ChannelSet    = [bool]$SatDiscordBotChannel
        ChannelId     = $SatDiscordBotChannel
        Prefix        = $SatDiscordCommandPrefix
        PollSeconds   = $SatDiscordPollSeconds
        BotUser       = $st.BotUser
        Connected     = $connected
        LastPoll      = $st.LastPoll
        LastError     = $st.LastError
        Pending       = $pending
        Approved      = @($approved | ForEach-Object { [PSCustomObject]@{ Id = $_.Id; Name = $_.Name } })
        ApprovedCount = @($approved).Count
        Users         = @($users | Sort-Object Total -Descending)
        CommandTotals = $cmdTotals
        TotalCommands = (@($cmdTotals | Measure-Object Count -Sum).Sum)
        Today         = $today
        Recent        = @($log | Select-Object -Last 60 | Sort-Object t -Descending)
    }
}
