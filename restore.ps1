# ============================================================
# Satisfactory Dashboard - Restore a backup
# ============================================================
# Restores a .sav from C:\OneDrive\Satisfactory_Backups to the
# live server using the official UploadSaveGame API (multipart).
#
# This is intentionally a MANUAL, run-from-PowerShell tool - never
# a one-click web button - because loading a save replaces the
# current world for everyone connected.
#
# Examples:
#   .\restore.ps1 -List                       # show available backups
#   .\restore.ps1 -Name '...sav'              # upload to server (does NOT switch)
#   .\restore.ps1 -Name '...sav' -Load        # upload AND load it live (replaces world)
#   .\restore.ps1 -Index 1 -Load              # same, by list position (1 = newest)
# ============================================================

param(
    [string]$Name,
    [int]$Index,
    [switch]$List,
    [switch]$Load,
    [switch]$Force
)

. (Join-Path $PSScriptRoot 'satisfactory-lib.ps1') | Out-Null

$backups = @(Get-ChildItem $SatBackupDir -Filter '*.sav' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
if ($backups.Count -eq 0) { Write-Host "No backups found in $SatBackupDir" -ForegroundColor Yellow; return }

if ($List -or (-not $Name -and -not $Index)) {
    Write-Host "`nBackups in $SatBackupDir (newest first):`n" -ForegroundColor Cyan
    $i = 1
    foreach ($b in $backups) {
        '{0,3}. {1,-55} {2,10}  {3}' -f $i, $b.Name, (Format-SatBytes $b.Length), $b.LastWriteTime.ToString('yyyy-MM-dd HH:mm') | Write-Host
        $i++
    }
    Write-Host "`nRestore with:  .\restore.ps1 -Index <n> [-Load]" -ForegroundColor DarkGray
    return
}

# resolve the chosen backup
$target = if ($Index) { $backups[$Index - 1] } else { $backups | Where-Object Name -eq $Name | Select-Object -First 1 }
if (-not $target) { Write-Host "Backup not found." -ForegroundColor Red; return }

$saveName = [System.IO.Path]::GetFileNameWithoutExtension($target.Name)
Write-Host "`nSelected: $($target.Name)  ($(Format-SatBytes $target.Length), $($target.LastWriteTime))" -ForegroundColor White
Write-Host "Will upload as save '$saveName'." -ForegroundColor DarkGray
if ($Load) { Write-Host "-Load set: this REPLACES the live world for everyone connected." -ForegroundColor Yellow }

if (-not $Force) {
    $ok = Read-Host "Type YES to proceed"
    if ($ok -ne 'YES') { Write-Host "Cancelled." -ForegroundColor DarkGray; return }
}

$token = Get-SatApiToken
if (-not $token) { Write-Host "Could not get an API token (check admin.secret)." -ForegroundColor Red; return }

$data = @{ function = 'UploadSaveGame'; data = @{ SaveName = $saveName; LoadSaveGame = [bool]$Load; EnableAdvancedGameSettings = $false } } | ConvertTo-Json -Compress
try {
    # The API requires the 'data' part to be application/json, which Invoke-RestMethod
    # -Form can't set per-part. Build the multipart body with HttpClient instead.
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.ServerCertificateCustomValidationCallback = [System.Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator  # self-signed cert
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(120)
    $client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)

    $content = [System.Net.Http.MultipartFormDataContent]::new()
    $csPart = [System.Net.Http.StringContent]::new('utf-8'); $content.Add($csPart, '_charset_')
    $dataPart = [System.Net.Http.StringContent]::new($data, [System.Text.Encoding]::UTF8, 'application/json')
    $content.Add($dataPart, 'data')
    $fileBytes = [System.IO.File]::ReadAllBytes($target.FullName)
    $filePart = [System.Net.Http.ByteArrayContent]::new($fileBytes)
    $filePart.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
    $content.Add($filePart, 'saveGameFile', $target.Name)

    $resp = $client.PostAsync($SatApiBase, $content).Result
    $respBody = $resp.Content.ReadAsStringAsync().Result
    if (-not $resp.IsSuccessStatusCode) { throw "HTTP $([int]$resp.StatusCode): $respBody" }
    $client.Dispose()

    if ($Load) {
        Write-Host "Restored and loaded '$saveName'. The world is now live." -ForegroundColor Green
    } else {
        Write-Host "Uploaded '$saveName' to the server's save list (not loaded)." -ForegroundColor Green
        Write-Host "Load it from the in-game Server Manager, or re-run with -Load." -ForegroundColor DarkGray
    }
} catch {
    Write-Host "Restore FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails) { Write-Host $_.ErrorDetails.Message -ForegroundColor DarkRed }
}
