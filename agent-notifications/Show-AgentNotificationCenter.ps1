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
    Write-Host 'Agent Notifications' -ForegroundColor Cyan
    Write-Host 'Type an event number to focus its project window.  c = clear  q = close' -ForegroundColor DarkGray
    Write-Host ''

    $displayEvents = @(Get-AgentNotificationDisplayEvents -Events $Events)
    if ($displayEvents.Count -eq 0) {
        Write-Host '  No notifications yet.' -ForegroundColor DarkGray
    } else {
        for ($i = 0; $i -lt $displayEvents.Count; $i++) {
            $event = $displayEvents[$i]
            $line = Format-AgentNotificationDisplayLine -Event $event -Number ($i + 1)
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
            if ($key.Key -eq [ConsoleKey]::Q) { break }
            if ($key.Key -eq [ConsoleKey]::C -and [string]::IsNullOrEmpty($inputBuffer)) {
                Clear-AgentNotificationEvents -StateRoot $StateRoot
                $events = @()
                $inputBuffer = ''
                $notice = 'Notification history cleared.'
                $lastSignature = ''
                $needsRender = $true
                continue
            }
            if ($key.Key -eq [ConsoleKey]::Backspace) {
                if ($inputBuffer.Length -gt 0) { $inputBuffer = $inputBuffer.Substring(0, $inputBuffer.Length - 1) }
                $needsRender = $true
                continue
            }
            if ($key.Key -eq [ConsoleKey]::Enter) {
                $selection = 0
                $displayEvents = @(Get-AgentNotificationDisplayEvents -Events $events)
                if ([int]::TryParse($inputBuffer, [ref]$selection) -and $selection -ge 1 -and $selection -le $displayEvents.Count) {
                    $event = $displayEvents[$selection - 1]
                    $succeeded = $false
                    if (Test-AgentNotificationTarget -Guard $event.guard) {
                        Start-Process wt.exe -ArgumentList @('-w', $event.window, 'focus-tab', '-t', '0')
                        $notice = "Focused $($event.project); notification came from pane $($event.pane)."
                        $succeeded = $true
                    } else {
                        try {
                            $settingsFile = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
                            $settings = Get-Content -Raw -LiteralPath $settingsFile | ConvertFrom-Json
                            $profile = Find-AgentNotificationProjectProfile -Event $event -Profiles @($settings.profiles.list)
                            if ($null -eq $profile) {
                                $notice = 'That project profile no longer exists.'
                            } else {
                                Start-ProjectWindow -ProfileName $profile.name -ProfileGuid "$($profile.guid)" `
                                    -ProfilePath $profile.startingDirectory
                                $notice = "Reopened $($profile.name)."
                                $succeeded = $true
                            }
                        } catch {
                            $notice = "Could not reopen that project: $($_.Exception.Message)"
                        }
                    }
                    if ($succeeded) {
                        [void](Set-AgentNotificationHandled -EventId $event.id -StateRoot $StateRoot)
                        $lastSignature = ''
                    }
                } else {
                    $notice = 'Enter a valid event number.'
                }
                $inputBuffer = ''
                $needsRender = $true
                continue
            }
            if ([char]::IsDigit($key.KeyChar)) {
                $inputBuffer += $key.KeyChar
                $notice = ''
                $needsRender = $true
            }
        }

        Start-Sleep -Milliseconds 150
    }
} finally {
    $centerMutex.ReleaseMutex()
    $centerMutex.Dispose()
}
