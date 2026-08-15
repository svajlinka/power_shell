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
    param([object[]]$Events, [hashtable]$ChatNames, [string]$InputBuffer, [string]$Notice)

    Clear-Host
    Write-Host '---==[ Agent Notifications ]==---' -ForegroundColor Cyan
    Write-Host 'Enter = latest   number/d/d12/d12 d3/c/q + Enter = run command' -ForegroundColor DarkGray
    Write-Host ''

    $displayEntries = @(Get-AgentNotificationDisplayEntries -Events $Events)
    if ($displayEntries.Count -eq 0) {
        Write-Host '  No notifications yet.' -ForegroundColor DarkGray
    } else {
        foreach ($entry in $displayEntries) {
            $event = $entry.event
            $chatName = Get-CachedAgentNotificationChatName -Event $event -Cache $ChatNames -StateRoot $StateRoot
            $line = Format-AgentNotificationDisplayLine -Event $event -Number $entry.number -ChatName $chatName
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
$chatNames = Read-AgentNotificationChatNameCache -StateRoot $StateRoot
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
            Show-Center -Events $events -ChatNames $chatNames -InputBuffer $inputBuffer -Notice $notice
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
                $done = ConvertFrom-AgentNotificationDoneCommand -Command $command
                if ($null -ne $done) {
                    if ($done.all) {
                        [void](Set-AllAgentNotificationsHandled -StateRoot $StateRoot)
                        $notice = ''
                    } else {
                        $doneIds = New-Object System.Collections.Generic.List[string]
                        $unknown = New-Object System.Collections.Generic.List[int]
                        foreach ($number in @($done.numbers)) {
                            $target = Find-AgentNotificationDisplayEvent -Events $events -Number $number
                            if ($null -eq $target) { $unknown.Add($number); continue }
                            $doneIds.Add("$($target.id)")
                        }
                        if ($doneIds.Count -gt 0) {
                            [void](Set-AgentNotificationHandled -EventId $doneIds.ToArray() -StateRoot $StateRoot)
                        }
                        $notice = ''
                        if (@($done.numbers).Count -eq 0) {
                            $notice = 'Enter a valid event number.'
                        } elseif ($unknown.Count -gt 0) {
                            $notice = "No notification numbered $($unknown -join ', ')."
                        }
                    }
                    $events = @(Read-AgentNotificationEvents -StateRoot $StateRoot)
                    $inputBuffer = ''
                    $lastSignature = ''
                    $needsRender = $true
                    continue
                }
                if ($command -eq 'c') {
                    Clear-AgentNotificationEvents -StateRoot $StateRoot
                    $events = @()
                    $chatNames.Clear()
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
            if ([char]::IsDigit($key.KeyChar) -and $inputBuffer -notmatch '^[cq]$') {
                $inputBuffer += $key.KeyChar
                $notice = ''
                Write-Host $key.KeyChar -NoNewline -ForegroundColor Green
                continue
            }
            $typed = "$($key.KeyChar)".ToLowerInvariant()
            if ($typed -eq 'd' -and ($inputBuffer.Length -eq 0 -or $inputBuffer -match '^d[d\d\s]*\d\s*$')) {
                $inputBuffer += $typed
                $notice = ''
                Write-Host $typed -NoNewline -ForegroundColor Green
                continue
            }
            if ($typed -eq ' ' -and $inputBuffer -match '^d[d\d\s]*\d$') {
                $inputBuffer += $typed
                $notice = ''
                Write-Host $typed -NoNewline -ForegroundColor Green
                continue
            }
            if ([string]::IsNullOrEmpty($inputBuffer) -and $typed -match '^[cq]$') {
                $inputBuffer = $typed
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
