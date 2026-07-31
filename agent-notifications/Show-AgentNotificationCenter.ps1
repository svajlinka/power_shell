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
        foreach ($entry in $displayEntries) {
            $event = $entry.event
            $line = Format-AgentNotificationDisplayLine -Event $event -Number $entry.number
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
                    $succeeded = $false
                    $sessionProperty = $event.PSObject.Properties['sessionId']
                    $sessionId = if ($null -eq $sessionProperty) { '' } else { "$($sessionProperty.Value)" }
                    $source = "$($event.source)"
                    $pane = 0
                    [void][int]::TryParse("$($event.pane)", [ref]$pane)
                    $hasExactChat = -not [string]::IsNullOrWhiteSpace($sessionId) -and
                        $source -in @('Codex', 'Claude') -and $pane -ge 1 -and $pane -le 4
                    if (Test-AgentNotificationTarget -Guard $event.guard) {
                        if ($hasExactChat) {
                            Start-Process wt.exe -ArgumentList (Get-AgentPaneFocusArguments -Window $event.window -Pane $pane)
                        } else {
                            Start-Process wt.exe -ArgumentList @('-w', $event.window, 'focus-tab', '-t', '0')
                        }
                        $notice = ''
                        $succeeded = $true
                    } else {
                        try {
                            $windowGuard = 'Local\AgentNotifications.Project.' + $event.window
                            if ($hasExactChat -and (Test-AgentNotificationTarget -Guard $windowGuard)) {
                                $notice = 'The project is open, but the original chat pane is no longer available.'
                            } else {
                                $settingsFile = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
                                $settings = Get-Content -Raw -LiteralPath $settingsFile | ConvertFrom-Json
                                $profile = Find-AgentNotificationProjectProfile -Event $event -Profiles @($settings.profiles.list)
                                if ($null -eq $profile) {
                                    $notice = 'That project profile no longer exists.'
                                } elseif ($hasExactChat) {
                                    Start-ProjectWindow -ProfileName $profile.name -ProfileGuid "$($profile.guid)" `
                                        -ProfilePath $profile.startingDirectory -ResumeSource $source `
                                        -ResumePane $pane -ResumeSessionId $sessionId
                                    $notice = ''
                                    $succeeded = $true
                                } else {
                                    Start-ProjectWindow -ProfileName $profile.name -ProfileGuid "$($profile.guid)" `
                                        -ProfilePath $profile.startingDirectory
                                    $notice = ''
                                    $succeeded = $true
                                }
                            }
                        } catch {
                            $notice = "Could not open that chat: $($_.Exception.Message)"
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
