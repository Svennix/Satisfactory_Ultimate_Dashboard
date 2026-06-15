# ============================================================
# Satisfactory Dashboard - Settings loader
# ============================================================
# Machine-specific values live in config.json (gitignored, edited
# via the Settings tab or by hand). This file holds safe DEFAULTS,
# overlays config.json on top, derives the rest, then loads secrets.
#
# Don't hand-edit the $Global:* below for per-machine values - put
# those in config.json. Secrets go in secrets.local.ps1.
# ============================================================

# --- Defaults (overridden by config.json) -----------------------------------
$SatDefaults = @{
    Root             = 'C:\satisfactoryserver'
    SaveDir          = "$env:LOCALAPPDATA\FactoryGame\Saved\SaveGames\server"
    ChildProc        = 'FactoryServer-Win64-Shipping-Cmd'
    TaskName         = 'SatisfactoryServer'
    ApiBase          = 'https://localhost:7777/api/v1'
    WebPort          = 8081
    WebBinds         = @('127.0.0.1')      # add your mgmt/VPN IP via config.json
    BackupDir        = 'C:\Satisfactory_Backups'
    BackupKeepRecent = 24
    BackupKeepDaily  = 14
    BackupKeepWeekly = 8
    BackupKeepMonthly= 12
    Watchdog         = $true
    SteamCmd         = 'C:\steamcmd\steamcmd.exe'
    SteamAppId       = '1690800'
    NickMap          = @{}
    # --- Discord command bot (polls a channel with a bot token) ---
    DiscordBotEnabled    = $false
    DiscordBotChannel    = ''         # channel ID to watch for commands
    DiscordCommandPrefix = '!'        # text-message prefix (NOT native slash commands)
    DiscordPollSeconds   = 10         # how often the listener polls Discord
    DiscordApprovedUsers = @()        # [{ Id = '<discord user id>'; Name = '<label>' }, ...]
}

# --- Overlay config.json ----------------------------------------------------
$SatConfigFile = Join-Path $PSScriptRoot 'config.json'
$cfg = @{} ; foreach ($k in $SatDefaults.Keys) { $cfg[$k] = $SatDefaults[$k] }
if (Test-Path $SatConfigFile) {
    try {
        $j = Get-Content $SatConfigFile -Raw | ConvertFrom-Json
        foreach ($k in @($SatDefaults.Keys)) { if ($null -ne $j.PSObject.Properties[$k]) { $cfg[$k] = $j.$k } }
    } catch { Write-Warning "config.json is invalid - using defaults. ($($_.Exception.Message))" }
}

# NickMap may arrive as a PSCustomObject (from JSON); normalize to a hashtable.
$nick = @{}
if ($cfg.NickMap -is [hashtable]) { $nick = $cfg.NickMap }
elseif ($cfg.NickMap) { foreach ($p in $cfg.NickMap.PSObject.Properties) { $nick[$p.Name] = "$($p.Value)" } }

# ApprovedUsers may arrive as an array of PSCustomObjects (from JSON); normalize
# to a clean array of @{ Id; Name } hashtables with string values.
$approved = @()
foreach ($u in @($cfg.DiscordApprovedUsers)) {
    if (-not $u) { continue }
    $id = "$($u.Id)".Trim(); if (-not $id) { continue }
    $nm = if ("$($u.Name)".Trim()) { "$($u.Name)".Trim() } else { $id }
    $approved += @{ Id = $id; Name = $nm }
}

# --- Assign globals (env values from config, paths derived) -----------------
$Global:SatRoot       = $cfg.Root
$Global:SatDashboard  = Join-Path $cfg.Root 'dashboard'
$Global:SatLogFile    = Join-Path $cfg.Root 'FactoryGame\Saved\Logs\FactoryGame.log'
$Global:SatWrapperLog = Join-Path $cfg.Root 'wrapper.log'
$Global:SatStopFlag   = Join-Path $cfg.Root 'stop.flag'
$Global:SatSaveDir    = $cfg.SaveDir
$Global:SatPlayerDb   = Join-Path $SatDashboard 'players.db'

$Global:SatChildProc  = $cfg.ChildProc
$Global:SatTaskName   = $cfg.TaskName

$Global:SatApiBase    = $cfg.ApiBase
$Global:SatSecretFile = Join-Path $SatDashboard 'admin.secret'

$Global:SatWebPort    = [int]$cfg.WebPort
$Global:SatWebBinds   = @($cfg.WebBinds)
$Global:SatWebDir     = Join-Path $SatDashboard 'www'
$Global:SatDataDir    = Join-Path $SatDashboard 'www\data'
$Global:SatControlToken = 'set-in-secrets.local.ps1'   # real value from secrets.local.ps1

$Global:SatBackupDir         = $cfg.BackupDir
$Global:SatBackupHistoryLog  = Join-Path $SatDashboard 'backup-history.log'
$Global:SatBackupKeepRecent  = [int]$cfg.BackupKeepRecent
$Global:SatBackupKeepDaily   = [int]$cfg.BackupKeepDaily
$Global:SatBackupKeepWeekly  = [int]$cfg.BackupKeepWeekly
$Global:SatBackupKeepMonthly = [int]$cfg.BackupKeepMonthly

$Global:SatWatchdog       = [bool]$cfg.Watchdog
$Global:SatEventLog       = Join-Path $SatDashboard 'events.log'
$Global:SatRestartConfig  = Join-Path $SatDashboard 'restart-config.json'
$Global:SatSteamCmd       = $cfg.SteamCmd
$Global:SatSteamAppId     = "$($cfg.SteamAppId)"
$Global:SatRestartTask    = 'Satisfactory Dashboard Restart'
$Global:SatDiscordWebhook = ''   # real value from secrets.local.ps1

$Global:SatNickMap = $nick

# --- Discord command bot ----------------------------------------------------
$Global:SatDiscordApi          = 'https://discord.com/api/v10'
$Global:SatDiscordBotEnabled   = [bool]$cfg.DiscordBotEnabled
$Global:SatDiscordBotChannel   = "$($cfg.DiscordBotChannel)".Trim()
$Global:SatDiscordCommandPrefix= if ("$($cfg.DiscordCommandPrefix)".Trim()) { "$($cfg.DiscordCommandPrefix)".Trim() } else { '!' }
$Global:SatDiscordPollSeconds  = [int]$cfg.DiscordPollSeconds; if ($SatDiscordPollSeconds -lt 3) { $Global:SatDiscordPollSeconds = 10 }
$Global:SatDiscordApprovedUsers= @($approved)
$Global:SatDiscordBotToken     = ''   # real value from secrets.local.ps1
$Global:SatDiscordState        = Join-Path $SatDashboard 'discord-state.json'
$Global:SatDiscordCmdLog       = Join-Path $SatDashboard 'discord-commands.jsonl'

# Keys that the Settings/Discord tabs are allowed to write back to config.json.
$Global:SatConfigKeys = @('Root','SaveDir','ChildProc','TaskName','ApiBase','WebPort','WebBinds',
    'BackupDir','BackupKeepRecent','BackupKeepDaily','BackupKeepWeekly','BackupKeepMonthly',
    'Watchdog','SteamCmd','SteamAppId','NickMap',
    'DiscordBotEnabled','DiscordBotChannel','DiscordCommandPrefix','DiscordPollSeconds','DiscordApprovedUsers')

# --- Local secrets (gitignored) ---------------------------------------------
# Real control token + Discord webhook live in secrets.local.ps1, which is NOT
# committed. Copy secrets.local.example.ps1 -> secrets.local.ps1 and fill it in.
$__satSecrets = Join-Path $SatDashboard 'secrets.local.ps1'
if (Test-Path $__satSecrets) { . $__satSecrets }
