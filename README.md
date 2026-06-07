# Satisfactory Server Dashboard

A self-hosted dashboard for the Satisfactory dedicated server: live stats,
per-player playtime, server health, OneDrive backups, and start/stop control.
No game mod required, no third-party cloud. Pure PowerShell + vanilla JS.

## Quick start
New here? Read **[HOWTO.md](HOWTO.md)**, then run **`setup.ps1`** from an elevated
PowerShell 7. It creates your secrets, stores the admin password, registers the
scheduled tasks and starts the web server.

## Open it
`http://<your-mgmt-ip>:8081/` — the listen IPs are set in `$SatWebBinds`. Keep it to
loopback + your management/VPN network only; **never** the public/DMZ NIC, and firewall
the port to that subnet.

## Pieces
| File | Role |
|------|------|
| `setup.ps1` | First-time setup: config, secrets, admin password, tasks, start. Run once. |
| `config.json` | **Machine-specific config** (paths, binds, retention…). **Gitignored** — edit via the **Settings tab** or copy from `config.example.json`. |
| `satisfactory-settings.ps1` | Loader: ships defaults, overlays `config.json`, derives paths, loads secrets. |
| `secrets.local.ps1` | Control token + Discord webhook. **Gitignored** — copy from `secrets.local.example.ps1`. |
| `satisfactory-lib.ps1` | Shared functions (log parser, API, metrics, backup, control). |
| `collect.ps1` | Snapshots state into `www/data/*.json`. Runs every minute. |
| `backup.ps1` | Save → OneDrive with GFS retention. Daily 04:00. `-Auto` for scheduled. |
| `restore.ps1` | Restore a backup to the server via the upload API. Manual, run from PowerShell. |
| `restart.ps1` | Scheduled/manual restart: countdown → save → optional update → restart. `-Now` / `-ForceUpdate`. |
| `import-history.ps1` | One-time: seed `players.db` from old rotated logs. `-WhatIf` to preview. Collector never reads backups. |

## Player history (`players.db`)
All-time per-player stats (total / average / longest playtime, sessions, last seen)
persist in `players.db`. Each collector run reads **only** the live `FactoryGame.log`
and upserts into the DB — it never scans Unreal's rotated `backup` logs. This is why
stats survive the log rotation that happens on every server restart. To recover history
that predates the DB, run `import-history.ps1` once.
| `serve.ps1` | The web server. Starts at boot. |
| `install-tasks.ps1` | (Re)registers the three scheduled tasks. |
| `admin.secret` | Server admin password (ACL-locked). Used to mint API tokens. |

## Scheduled tasks
- **Satisfactory Dashboard Collector** — every 1 min (also runs the watchdog)
- **Satisfactory Dashboard Backup** — daily 04:00 (`install-tasks.ps1 -BackupAt 'HH:mm'` to change)
- **Satisfactory Dashboard Web** — at boot
- **Satisfactory Dashboard Restart** — per the Maintenance tab (default daily 05:00 + update)

## Maintenance (watchdog, restart, update)
- **Watchdog**: the collector relaunches the server if its process is gone and no
  `stop.flag` is set (i.e. it crashed, wasn't stopped on purpose). Logged to `events.log`.
- **Scheduled restart**: configure from the **Maintenance** tab — every day / 2 days /
  3 days / weekly, at a chosen time, with an optional SteamCMD `app_update` each restart.
  When players are online it waits out the warn-lead (saving first); empty → restarts now.
- **No in-game messages**: a vanilla server cannot push chat/notifications to players
  (confirmed — the API has no such function and `Say` is a no-op headless). Instead,
  notifications go to a **Discord webhook** (`$SatDiscordWebhook` in settings). What posts:
  restart countdown 🔔, watchdog relaunch 🔴, version change 🆕, backup result 💾.
  Add `-Discord` to any `Write-SatEvent` call to route more. The webhook URL is a secret
  (anyone with it can post to the channel) — keep it in settings only.
- Manual **Restart now** / **Update + restart now** buttons on the Maintenance tab.

## Operating
- **Change the control token** in `satisfactory-settings.ps1` (`$SatControlToken`,
  default `ficsit-please`). The web Start/Stop/Backup buttons require it.
- Backups land in `C:\OneDrive\Satisfactory_Backups`. Retention is grandfather-
  father-son (recent hours, then daily/weekly/monthly), tunable in settings.
- Friendly player names: the log already provides them; override via `$SatNickMap`
  (keyed by SteamID64) if you want real names instead of gamertags.

## Manual commands
```powershell
& .\collect.ps1                 # refresh data now
& .\backup.ps1                  # one-off backup
& .\serve.ps1                   # run the web server in the foreground
& .\install-tasks.ps1           # re-register scheduled tasks
```

## Restoring a backup
Run from PowerShell on the server (never a web button — loading a save replaces
the world for everyone connected):
```powershell
.\restore.ps1 -List             # list backups, newest first
.\restore.ps1 -Index 1          # upload newest to the server (does NOT switch)
.\restore.ps1 -Index 1 -Load    # upload AND load it live (replaces the world)
```
After an upload you can also load it from the in-game **Server Manager → Manage Saves**.

