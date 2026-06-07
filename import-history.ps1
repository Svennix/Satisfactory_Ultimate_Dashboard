# ============================================================
# Satisfactory Dashboard - One-time history import
# ============================================================
# Seeds players.db from the existing rotated / Unreal "backup" logs, to recover
# playtime that happened before the persistent DB existed.
#
# This is a MANUAL, run-once migration. The collector never reads backup logs;
# it only reads the current FactoryGame.log. Re-running this is safe (sessions
# are keyed by SteamID + start time, so they can't be double-counted).
#
#   .\import-history.ps1            # import + save
#   .\import-history.ps1 -WhatIf    # show what it would add, change nothing
# ============================================================

param([switch]$WhatIf)

. (Join-Path $PSScriptRoot 'satisfactory-lib.ps1') | Out-Null

$reJoin  = 'Login request:.*?\?Name=([^?]+?) userId:.*?RepData=\[([0-9A-Fa-f]+)\]'
$reLeave = 'UNetConnection::Close:.*?RepData=\[([0-9A-Fa-f]+)\]'
$reIp    = 'RemoteAddr: \[::ffff:([0-9.]+)\]'

$db = Read-SatPlayerDb
$before = $db.Sessions.Count

$dir = Split-Path $SatLogFile -Parent
$curName = Split-Path $SatLogFile -Leaf
# every .log except the live one - these are completed (stopped) server runs
$files = Get-ChildItem $dir -Filter '*.log' | Where-Object { $_.Name -ne $curName } | Sort-Object LastWriteTime

Write-Host "Importing from $($files.Count) rotated log file(s)..." -ForegroundColor Cyan
foreach ($lf in $files) {
    $joins=@{}; $leaves=@{}; $names=@{}; $ips=@{}; $lastTs=$null
    foreach ($line in (Read-SatLogLines $lf.FullName)) {
        if ($line -notmatch '^\[') { continue }
        $t = ConvertFrom-SatLogTime $line
        if ($t) { $lastTs = $t }
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
    # pair within this (completed) run; an unmatched join ended when the run stopped
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
            $end = if ($lastTs -and $lastTs -gt $open) { $lastTs } else { $open }
            Add-SatSession $db $sid $nm $ip $open $end $false
        }
    }
}

$added = $db.Sessions.Count - $before
if ($WhatIf) {
    Write-Host "[WhatIf] Would add $added new session(s) (DB would have $($db.Sessions.Count))." -ForegroundColor Yellow
} else {
    Save-SatPlayerDb $db
    Write-Host "Imported. Added $added session(s); DB now holds $($db.Sessions.Count)." -ForegroundColor Green
}