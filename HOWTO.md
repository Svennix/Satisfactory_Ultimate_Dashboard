# Satisfactory Server Dashboard — Quick How-To

A self-hosted web dashboard for a **Satisfactory dedicated server**: live player
stats, server health, OneDrive backups, scheduled restarts/updates, a crash
watchdog, and Discord notifications. Pure PowerShell + vanilla JS — no game mod,
no third-party cloud.

---

## 1. Requirements
- Windows + **PowerShell 7** (`pwsh`)
- A running **Satisfactory Dedicated Server** with the HTTPS API on `:7777`
- The server's **admin API password** (claim the server in-game → set an admin password)
- *(optional)* **SteamCMD** at `C:\steamcmd\steamcmd.exe` for the update feature
- *(optional)* a **Discord webhook URL** for notifications

## 2. Install (≈2 minutes)
```powershell
# from an ELEVATED PowerShell 7:
git clone https://github.com/Svennix/Satisfactory_Ultimate_Dashboard.git dashboard
cd dashboard
.\setup.ps1
```
`setup.ps1` will:
1. create `secrets.local.ps1` (auto-generates a strong control token; asks for an optional Discord webhook),
2. ask for your server admin password and store it ACL-locked in `admin.secret`,
3. verify it can log in to the server API,
4. register the scheduled tasks (collector, backup, web, restart),
5. start the web server.

Then open the URL it prints (e.g. `http://127.0.0.1:8081/`).

> Prefer non-interactive? `\.setup.ps1 -AdminPassword '…' -DiscordWebhook '…'`

## 3. Point it at your server
All machine-specific config lives in **`config.json`** (gitignored). The easiest way
to edit it is the **Settings tab** in the dashboard — install root, save/backup dirs,
web port + bind IPs, backup retention, watchdog, SteamCMD, nicknames, and the Discord
webhook. Or edit `config.json` directly (copy `config.example.json` to start).

> Keep bind IPs to loopback + your **management network** (a VPN/Netbird IP) — never a
> public/DMZ NIC. Web port / bind / token changes apply after the web server restarts;
> everything else applies on the next collector cycle.

Secrets (`$SatControlToken`, `$SatDiscordWebhook`) live in **`secrets.local.ps1`**
(gitignored); the admin password lives in **`admin.secret`** (gitignored). `satisfactory-settings.ps1`
just ships defaults and overlays `config.json` + secrets — you shouldn't need to edit it.

## 4. Open the firewall (management network only)
The web server binds only to the IPs in `$SatWebBinds`, but Windows Firewall must
still allow the port. Scope it to your management subnet — **do not expose it to the
internet**:
```powershell
New-NetFirewallRule -DisplayName 'Satisfactory Dashboard' -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort 8081 -RemoteAddress <your-mgmt-subnet> -Profile Private,Public
```

## 5. Using the dashboard
- **Dashboard tab** — players online, per-player playtime, CPU/RAM, tick rate,
  tech tier, save-size growth, activity heatmap, fun stats.
- **Backups tab** — inventory, retention breakdown, run history, "Backup now".
- **Maintenance tab** — server version, scheduled restart (every 1/2/3 days or
  weekly + time, optional update each restart), watchdog status, event log,
  "Restart now" / "Update + restart now".
- **Control actions** (Start/Stop/Backup/Restart/Update/Save schedule) require the
  **control token**. Viewing stats does not.

## 6. Backups & restore
- Backups copy the newest save to `$SatBackupDir` with a self-describing name and
  prune via grandfather-father-son retention (recent → daily → weekly → monthly).
- Restore is deliberately a manual PowerShell step (loading a save replaces the
  world for everyone):
  ```powershell
  .\restore.ps1 -List              # list backups
  .\restore.ps1 -Index 1           # upload to server (does NOT switch)
  .\restore.ps1 -Index 1 -Load     # upload AND load it live
  ```

## 7. Notifications
In-game messaging isn't possible on a vanilla server, so notifications go to a
**Discord webhook**. Set `$SatDiscordWebhook` in `secrets.local.ps1`. What posts:
restart countdown, watchdog relaunch, version change, backup success/failure.

## 8. Player history
All-time per-player stats live in **`players.db`**. The collector reads only the
live `FactoryGame.log` each minute and upserts into the DB, so stats survive the
log rotation that happens on every restart. To import history that predates the DB:
```powershell
.\import-history.ps1            # one-time; -WhatIf to preview
```

## 9. Troubleshooting
- **Dashboard loads but data is empty** → check the *Collector* scheduled task is
  running and `admin.secret` is correct (`Get-SatApiToken` should return a token).
- **Control buttons say "bad token"** → the token field must match `$SatControlToken`.
- **Web server won't start / "access denied"** → run it elevated, or add a URL ACL:
  `netsh http add urlacl url=http://<ip>:8081/ user=Administrators`
- **Times look 12-hour** → hard-refresh the page (Ctrl+F5).

See **README.md** for the full file-by-file reference.
