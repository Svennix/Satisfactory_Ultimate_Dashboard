# ============================================================
# Satisfactory Dashboard - Web Server
# ============================================================
# A dependency-free static + control server built on HttpListener.
# Serves www\ (including www\data\*.json) and a small control API.
#
# SECURITY: binds ONLY to loopback + the Netbird management IP
# (see $SatWebBinds). Never bind this to the DMZ/public NIC.
# Control actions (start/stop/backup) require the shared token.
#
# Run it (as admin, so HttpListener can bind):
#   powershell -NoProfile -ExecutionPolicy Bypass -File serve.ps1
# ============================================================

. (Join-Path $PSScriptRoot 'satisfactory-lib.ps1') | Out-Null

$mime = @{
    '.html'='text/html; charset=utf-8'; '.js'='application/javascript; charset=utf-8';
    '.css'='text/css; charset=utf-8';   '.json'='application/json; charset=utf-8';
    '.svg'='image/svg+xml'; '.ico'='image/x-icon'; '.png'='image/png'; '.map'='application/json'
}

$listener = [System.Net.HttpListener]::new()
foreach ($b in $SatWebBinds) { $listener.Prefixes.Add("http://${b}:$SatWebPort/") }
try {
    $listener.Start()
} catch {
    Write-Host "Failed to start listener: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "If this is an access error, run as Administrator or add a URL ACL:" -ForegroundColor Yellow
    Write-Host "  netsh http add urlacl url=http://100.100.171.56:$SatWebPort/ user=Administrators" -ForegroundColor Yellow
    exit 1
}
Write-Host "Satisfactory dashboard listening on:" -ForegroundColor Green
foreach ($b in $SatWebBinds) { Write-Host "  http://${b}:$SatWebPort/" -ForegroundColor Cyan }
Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray

function Send-Text {
    param($Ctx, [string]$Text, [string]$ContentType = 'application/json; charset=utf-8', [int]$Status = 200)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Ctx.Response.StatusCode = $Status
    $Ctx.Response.ContentType = $ContentType
    $Ctx.Response.ContentLength64 = $bytes.Length
    $Ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Ctx.Response.OutputStream.Close()
}

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
        $req  = $ctx.Request
        $path = [System.Uri]::UnescapeDataString($req.Url.AbsolutePath)
        if ($path -eq '/') { $path = '/index.html' }

        # --- control API --------------------------------------------------
        if ($path -eq '/api/control' -and $req.HttpMethod -eq 'POST') {
            $body = (New-Object System.IO.StreamReader($req.InputStream)).ReadToEnd()
            $cmd  = $null; try { $cmd = $body | ConvertFrom-Json } catch {}
            if (-not $cmd -or $cmd.token -ne $SatControlToken) {
                Send-Text $ctx (@{ ok=$false; error='bad token' } | ConvertTo-Json) -Status 403; continue
            }
            try {
                $pwshExe = (Get-Command pwsh).Source
                $result = switch ($cmd.action) {
                    'start'  { Start-SatServer }
                    'stop'   { Stop-SatServer }
                    'backup' { & (Join-Path $PSScriptRoot 'backup.ps1') -Auto -Trigger 'dashboard'; 'backup started' }
                    'collect'{ & (Join-Path $PSScriptRoot 'collect.ps1'); 'collected' }
                    'restart'{ Start-Process $pwshExe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'restart.ps1'),'-Now','-NoUpdate'; 'restart started (running in background)' }
                    'update' { Start-Process $pwshExe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'restart.ps1'),'-Now','-ForceUpdate'; 'update + restart started (running in background)' }
                    'set-restart' {
                        Set-SatRestartConfig -Enabled ([bool]$cmd.enabled) -Frequency "$($cmd.frequency)" -Time "$($cmd.time)" -Update ([bool]$cmd.update) -LeadMinutes ([int]$cmd.lead) | Out-Null
                        & (Join-Path $PSScriptRoot 'collect.ps1')   # refresh maintenance.json immediately
                        'schedule saved'
                    }
                    'set-config' {
                        $upd = @{}
                        if ($cmd.config) {
                            foreach ($k in $SatConfigKeys) {
                                $v = $cmd.config.$k
                                if ($null -ne $v) {
                                    if ($k -eq 'WebBinds') { $upd[$k] = @($v) }
                                    elseif ($k -eq 'NickMap') { $h = @{}; foreach ($p in $v.PSObject.Properties) { if ("$($p.Value)".Trim()) { $h[$p.Name] = "$($p.Value)" } }; $upd[$k] = $h }
                                    else { $upd[$k] = $v }
                                }
                            }
                            Set-SatConfig -Updates $upd
                        }
                        $newTok = if ($cmd.rotateToken -and "$($cmd.rotateToken)".Trim()) { "$($cmd.rotateToken)" } else { $null }
                        $newWh  = if ($null -ne $cmd.discordWebhook) { "$($cmd.discordWebhook)" } else { $null }
                        Set-SatSecrets -ControlToken $newTok -DiscordWebhook $newWh
                        & (Join-Path $PSScriptRoot 'collect.ps1')   # refresh settings.json immediately
                        'settings saved (web port/binds/token changes apply after a web-server restart)'
                    }
                    default  { throw "unknown action '$($cmd.action)'" }
                }
                Send-Text $ctx (@{ ok=$true; result="$result" } | ConvertTo-Json)
            } catch {
                Send-Text $ctx (@{ ok=$false; error=$_.Exception.Message } | ConvertTo-Json) -Status 500
            }
            continue
        }

        # --- static files (sandboxed to www) ------------------------------
        $full = Join-Path $SatWebDir ($path.TrimStart('/') -replace '/', '\')
        $resolved = [System.IO.Path]::GetFullPath($full)
        if (-not $resolved.StartsWith([System.IO.Path]::GetFullPath($SatWebDir), [System.StringComparison]::OrdinalIgnoreCase)) {
            Send-Text $ctx '{"error":"forbidden"}' -Status 403; continue
        }
        if (Test-Path $resolved -PathType Leaf) {
            $ext = [System.IO.Path]::GetExtension($resolved).ToLower()
            $ct  = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
            # data JSON should never be cached by the browser
            if ($path -like '/data/*') { $ctx.Response.Headers.Add('Cache-Control','no-store') }
            $bytes = [System.IO.File]::ReadAllBytes($resolved)
            $ctx.Response.StatusCode = 200
            $ctx.Response.ContentType = $ct
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $ctx.Response.OutputStream.Close()
        } else {
            Send-Text $ctx '{"error":"not found"}' -Status 404
        }
    } catch {
        try { Send-Text $ctx (@{ error=$_.Exception.Message } | ConvertTo-Json) -Status 500 } catch {}
    }
}
