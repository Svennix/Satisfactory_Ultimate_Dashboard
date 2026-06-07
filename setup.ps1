# ============================================================
# Satisfactory Dashboard - First-time setup
# ============================================================
# Run this once after cloning to configure secrets, verify the
# server API, register the scheduled tasks and start the web UI.
#
# Interactive (prompts for what it needs):
#   pwsh -File setup.ps1
# Non-interactive (CI / scripted):
#   pwsh -File setup.ps1 -AdminPassword '...' -DiscordWebhook '...' -NoStart
#
# Run from an ELEVATED PowerShell 7 (Administrator) so it can
# register tasks and bind the web listener.
# ============================================================
#requires -Version 7
param(
    [string]$ControlToken,          # omit to auto-generate a strong one
    [string]$DiscordWebhook,        # optional; omit to be prompted (Enter = none)
    [string]$AdminPassword,         # server admin API password (omit to be prompted)
    [switch]$NoTasks,               # skip scheduled-task registration
    [switch]$NoStart                # skip starting the web server
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
function Say($m,$c='Gray'){ Write-Host $m -ForegroundColor $c }

Say "`n=== Satisfactory Dashboard setup ===`n" 'Cyan'

# 0. Elevation check ---------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) { Say "WARNING: not elevated. Task registration and the web listener need Administrator." 'Yellow' }

# 1. config.json (machine-specific values) ----------------------------------
$cfgFile = Join-Path $here 'config.json'
if (-not (Test-Path $cfgFile)) {
    Copy-Item (Join-Path $here 'config.example.json') $cfgFile
    Say "Created config.json from the example - set your paths/binds in the Settings tab (or edit the file)." 'Green'
} else {
    Say "config.json already exists - keeping it." 'DarkGray'
}

# 2. secrets.local.ps1 -------------------------------------------------------
$secretsFile = Join-Path $here 'secrets.local.ps1'
if (Test-Path $secretsFile) {
    Say "secrets.local.ps1 already exists - keeping it." 'DarkGray'
} else {
    if (-not $ControlToken) {
        $bytes = [byte[]]::new(24)
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $ControlToken = ([Convert]::ToBase64String($bytes) -replace '[^A-Za-z0-9]','').Substring(0,32)
        Say "Generated a strong control token." 'Green'
    }
    if (-not $PSBoundParameters.ContainsKey('DiscordWebhook')) {
        $DiscordWebhook = Read-Host "Discord webhook URL (optional - press Enter to skip)"
    }
    @"
# Local secrets - gitignored, do NOT commit.
`$Global:SatControlToken   = '$ControlToken'
`$Global:SatDiscordWebhook = '$DiscordWebhook'
"@ | Set-Content $secretsFile -Encoding UTF8
    Say "Wrote secrets.local.ps1" 'Green'
}

# 2. Load settings (now incl. secrets) --------------------------------------
. (Join-Path $here 'satisfactory-settings.ps1') | Out-Null

# 3. admin.secret ------------------------------------------------------------
if (Test-Path $SatSecretFile) {
    Say "admin.secret already exists - keeping it." 'DarkGray'
} else {
    if (-not $AdminPassword) {
        $sec = Read-Host "Server admin API password" -AsSecureString
        $AdminPassword = [System.Net.NetworkCredential]::new('', $sec).Password
    }
    Set-Content -Path $SatSecretFile -Value $AdminPassword -NoNewline -Encoding UTF8
    icacls $SatSecretFile /inheritance:r /grant:r "SYSTEM:(F)" "Administrators:(F)" | Out-Null
    Say "Wrote admin.secret (ACL-locked to SYSTEM + Administrators)." 'Green'
}

# 4. data dir + API check ----------------------------------------------------
if (-not (Test-Path $SatDataDir)) { New-Item -ItemType Directory -Path $SatDataDir -Force | Out-Null }
. (Join-Path $here 'satisfactory-lib.ps1') | Out-Null
if (Get-SatApiToken) { Say "Server API login OK." 'Green' }
else { Say "Could not log in to the server API. Check admin.secret and that the server's HTTPS API is up at $SatApiBase." 'Yellow' }

# 5. Scheduled tasks ---------------------------------------------------------
if ($NoTasks) { Say "Skipping task registration (-NoTasks)." 'DarkGray' }
else { & (Join-Path $here 'install-tasks.ps1') }

# 6. Web server --------------------------------------------------------------
if ($NoStart) {
    Say "Skipping web server start (-NoStart)." 'DarkGray'
} else {
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" |
        Where-Object { $_.CommandLine -match '-File\s+\S*serve\.ps1' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    Start-Process pwsh -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $here 'serve.ps1') -WindowStyle Hidden
    Say "Web server started." 'Green'
}

# 7. Summary -----------------------------------------------------------------
Say "`n=== Setup complete ===" 'Cyan'
foreach ($b in $SatWebBinds) { Say "  Dashboard: http://${b}:$SatWebPort/" 'White' }
Say "  Control token: $SatControlToken" 'White'
Say ""
Say "Next steps:" 'DarkGray'
Say "  - Adjust paths/binds in satisfactory-settings.ps1 for your machine." 'DarkGray'
Say "  - Allow the web port through the firewall to your management network only, e.g.:" 'DarkGray'
Say "      New-NetFirewallRule -DisplayName 'Satisfactory Dashboard' -Direction Inbound -Action Allow ``" 'DarkGray'
Say "        -Protocol TCP -LocalPort $SatWebPort -RemoteAddress <your-mgmt-subnet> -Profile Private,Public" 'DarkGray'
Say "  - See HOWTO.md for the full guide." 'DarkGray'
