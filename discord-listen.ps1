# ============================================================
# Satisfactory Dashboard - Discord command listener
# ============================================================
# A long-running poller. It reads recent messages from the configured Discord
# channel using a BOT token and hands each one to the command dispatcher in the
# library. This is NOT native slash commands (those need a Gateway socket or a
# public interactions endpoint) - it reacts to text messages that start with the
# command prefix, which is all polling can see.
#
# Runtime model (matches the rest of the dashboard):
#   - started at boot by the "Satisfactory Dashboard Discord Bot" task
#   - settings are re-read every cycle, so toggling the bot, rotating the token,
#     changing the channel or the approved list all take effect within one poll
#   - all state (last-seen id, pending confirmations, cooldowns) is on disk, so a
#     restart never replays old commands
#
# Run it directly for testing:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File discord-listen.ps1
# ============================================================

$libPath      = Join-Path $PSScriptRoot 'satisfactory-lib.ps1'
$settingsPath = Join-Path $PSScriptRoot 'satisfactory-settings.ps1'
. $libPath | Out-Null

Write-Host "Satisfactory Discord listener started. Polling every $SatDiscordPollSeconds s." -ForegroundColor Green

while ($true) {
    # Refresh config + secrets so UI changes apply without restarting the task.
    try { . $settingsPath | Out-Null } catch {}

    $sleep = [Math]::Max(3, [int]$SatDiscordPollSeconds)
    try {
        if (-not $SatDiscordBotEnabled -or -not $SatDiscordBotToken -or -not $SatDiscordBotChannel) {
            Start-Sleep -Seconds $sleep
            continue
        }

        $state = Read-SatDiscordState

        # Learn who we are once (so we never reply to ourselves).
        if (-not $state.BotUserId) {
            try {
                $me = Invoke-SatDiscordRequest -Method GET -Path '/users/@me'
                $state.BotUserId = "$($me.id)"
                $state.BotUser   = if ($me.global_name) { "$($me.global_name)" } else { "$($me.username)" }
            } catch {
                $state.LastError = "auth/@me failed: $($_.Exception.Message)"
                Save-SatDiscordState $state
                Start-Sleep -Seconds $sleep
                continue
            }
        }

        # First run: seed the cursor at the newest message so we never replay history.
        if (-not $state.LastMessageId) {
            try {
                $seed = @(Invoke-SatDiscordRequest -Method GET -Path "/channels/$SatDiscordBotChannel/messages?limit=1")
                if ($seed.Count) { $state.LastMessageId = "$($seed[0].id)" }
            } catch {
                $state.LastError = "seed read failed: $($_.Exception.Message)"
                Save-SatDiscordState $state
                Start-Sleep -Seconds $sleep
                continue
            }
        }

        # Fetch anything newer than the cursor (oldest-first for orderly processing).
        $after = $state.LastMessageId
        $resp = Invoke-SatDiscordRequest -Method GET -Path "/channels/$SatDiscordBotChannel/messages?limit=50&after=$after"
        # Flatten (the REST helper can hand back a nested array) and keep only real
        # message objects, so member access (.id/.author) is always a scalar.
        $msgs = @(); foreach ($x in $resp) { foreach ($y in $x) { if ($null -ne $y.id) { $msgs += $y } } }
        $ordered = @($msgs | Sort-Object { try { [uint64]"$($_.id)" } catch { [uint64]0 } })

        foreach ($m in $ordered) {
            # Advance the cursor FIRST and unconditionally (parse defensively), so a
            # message that fails to parse or process can never wedge the listener on
            # the same batch forever.
            $mid = [uint64]0; try { $mid = [uint64]"$($m.id)" } catch {}
            $cur = [uint64]0; try { $cur = [uint64]"$($state.LastMessageId)" } catch {}
            if ($mid -gt $cur) { $state.LastMessageId = "$($m.id)" }
            if ($m.author.bot) { continue }
            if ("$($m.author.id)" -eq "$($state.BotUserId)") { continue }
            try { $state = Invoke-SatDiscordCommand -Msg $m -State $state }
            catch { Write-SatEvent -Category 'control' -Message "Discord: command error: $($_.Exception.Message)" -Level 'error' }
        }

        # auto-cancel any confirmation whose 60s window has elapsed (runs every
        # cycle, even with no new messages, so forgotten commands never linger)
        $state = Invoke-SatDiscordExpiry -State $state

        $state.LastPoll  = (Get-Date).ToString('o')
        $state.LastError = ''
        Save-SatDiscordState $state
    } catch {
        try {
            $state = Read-SatDiscordState
            $state.LastError = "poll failed: $($_.Exception.Message)"
            Save-SatDiscordState $state
        } catch {}
    }

    Start-Sleep -Seconds $sleep
}
