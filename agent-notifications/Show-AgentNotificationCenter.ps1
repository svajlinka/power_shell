param([string]$StateRoot)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentNotifications.psm1') -Force -DisableNameChecking
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'powershell-profile.ps1')

$created = $false
$centerMutex = New-Object System.Threading.Mutex($true, 'Local\AgentNotifications.ControlCenter.Notifications', [ref]$created)
if (-not $created) {
    $centerMutex.Dispose()
    return
}

function Show-Center {
    param([object[]]$Events, [string]$InputBuffer, [string]$Notice)

    Clear-Host
    Write-Host '---==[ Agent Notifications ]==---' -ForegroundColor Cyan
    Write-Host 'Enter = latest   number/d/c/q + Enter = run command' -ForegroundColor DarkGray
    Write-Host ''

    $displayEntries = @(Get-AgentNotificationDisplayEntries -Events $Events)
    if ($displayEntries.Count -eq 0) {
        Write-Host '  No notifications yet.' -ForegroundColor DarkGray
    } else {
        $chatNames = @{}
        foreach ($entry in $displayEntries) {
            $event = $entry.event
            $source = "$($event.source)"
            $sessionId = "$($event.sessionId)"
            $chatKey = "$source`0$sessionId"
            if (-not $chatNames.ContainsKey($chatKey)) {
                $chatNames[$chatKey] = Get-AgentNotificationChatName -Event $event
            }
            $line = Format-AgentNotificationDisplayLine -Event $event -Number $entry.number `
                -ChatName $chatNames[$chatKey]
            $color = if (Test-AgentNotificationHandled -Event $event) { 'Blue' } else { 'Yellow' }
            Write-Host $line -ForegroundColor $color
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Notice)) {
        Write-Host "`n$Notice" -ForegroundColor Yellow
    }
    Write-Host "`nSelection: $InputBuffer" -NoNewline -ForegroundColor Green
}

$events = @()
$inputBuffer = ''
$notice = ''
$lastSignature = ''
$needsRender = $true

try {
    while ($true) {
        $eventFile = Join-Path (Get-AgentNotificationStateRoot -StateRoot $StateRoot) 'events.jsonl'
        $trackedFiles = @(
            $eventFile,
            (Join-Path $env:USERPROFILE '.codex\session_index.jsonl'),
            (Join-Path $env:USERPROFILE '.codex\history.jsonl'),
            (Join-Path $env:USERPROFILE '.claude\history.jsonl')
        )
        $signature = (($trackedFiles | ForEach-Object {
            if (Test-Path -LiteralPath $_) {
                $item = Get-Item -LiteralPath $_
                "$($item.Length):$($item.LastWriteTimeUtc.Ticks)"
            } else { 'missing' }
        }) -join '|')

        if ($signature -ne $lastSignature) {
            $events = @(Read-AgentNotificationEvents -StateRoot $StateRoot)
            $lastSignature = $signature
            $needsRender = $true
        }

        if ($needsRender) {
            Show-Center -Events $events -InputBuffer $inputBuffer -Notice $notice
            $needsRender = $false
        }

        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Backspace) {
                if ($inputBuffer.Length -gt 0) {
                    $inputBuffer = $inputBuffer.Substring(0, $inputBuffer.Length - 1)
                    Write-Host "`b `b" -NoNewline
                }
                continue
            }
            if ($key.Key -eq [ConsoleKey]::Enter) {
                $command = $inputBuffer.ToLowerInvariant()
                if ($command -eq 'q') { break }
                if ($command -eq 'd') {
                    [void](Set-AllAgentNotificationsHandled -StateRoot $StateRoot)
                    $events = @(Read-AgentNotificationEvents -StateRoot $StateRoot)
                    $inputBuffer = ''
                    $notice = ''
                    $lastSignature = ''
                    $needsRender = $true
                    continue
                }
                if ($command -eq 'c') {
                    Clear-AgentNotificationEvents -StateRoot $StateRoot
                    $events = @()
                    $inputBuffer = ''
                    $notice = ''
                    $lastSignature = ''
                    $needsRender = $true
                    continue
                }
                $selection = 0
                $event = $null
                if ([string]::IsNullOrEmpty($inputBuffer)) {
                    $selection = 1
                    $event = Find-AgentNotificationDisplayEvent -Events $events -Number $selection
                } elseif ([int]::TryParse($inputBuffer, [ref]$selection)) {
                    $event = Find-AgentNotificationDisplayEvent -Events $events -Number $selection
                }
                if ($null -ne $event) {
                    $result = Open-AgentNotificationChat -Event $event -StateRoot $StateRoot
                    $notice = $result.Error
                    if ($result.Succeeded) {
                        $lastSignature = ''
                    }
                } else {
                    $notice = 'Enter a valid event number.'
                }
                $inputBuffer = ''
                $needsRender = $true
                continue
            }
            if ([char]::IsDigit($key.KeyChar) -and $inputBuffer -notmatch '^[dcq]$') {
                $inputBuffer += $key.KeyChar
                $notice = ''
                Write-Host $key.KeyChar -NoNewline -ForegroundColor Green
                continue
            }
            if ([string]::IsNullOrEmpty($inputBuffer) -and "$($key.KeyChar)" -match '^[dDcCqQ]$') {
                $inputBuffer = "$($key.KeyChar)".ToLowerInvariant()
                $notice = ''
                Write-Host $inputBuffer -NoNewline -ForegroundColor Green
            }
        }

        Start-Sleep -Milliseconds 150
    }
} finally {
    $centerMutex.ReleaseMutex()
    $centerMutex.Dispose()
}
