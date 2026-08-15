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

$script:centerWindowWidth = 0

function Write-CenterEntry {
    param(
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][int]$SelectedIndex,
        [Parameter(Mandatory = $true)][hashtable]$ChatNames,
        [switch]$NoNewline
    )

    $event = $Entry.event
    $chatName = Get-CachedAgentNotificationChatName -Event $event -Cache $ChatNames -StateRoot $StateRoot
    $line = Format-AgentNotificationDisplayLine -Event $event -Number $Entry.number -ChatName $chatName
    $color = if (Test-AgentNotificationHandled -Event $event) { 'Blue' } else { 'Yellow' }
    $line = $(if ($Index -eq $SelectedIndex) { '> ' } else { '  ' }) + $line
    $maximumLength = [Math]::Max(1, [Console]::WindowWidth - 1)
    if ($line.Length -gt $maximumLength) { $line = $line.Substring(0, $maximumLength) }
    if ($Index -eq $SelectedIndex) {
        Write-Host $line -ForegroundColor White -BackgroundColor DarkCyan -NoNewline:$NoNewline
    } else {
        Write-Host $line -ForegroundColor $color -NoNewline:$NoNewline
    }
}

function Show-Center {
    param(
        [object[]]$Events,
        [hashtable]$ChatNames,
        [string]$InputBuffer,
        [string]$Notice,
        [int]$SelectedIndex
    )

    Clear-Host
    $script:centerWindowWidth = [Console]::WindowWidth
    Write-Host '---==[ Agent Notifications ]==---' -ForegroundColor Cyan
    Write-Host 'Up/Down = select   Enter = open   number/d/d12/d12 d3/c/q + Enter = run command' -ForegroundColor DarkGray
    Write-Host ''

    $displayEntries = @(Get-AgentNotificationDisplayEntries -Events $Events)
    if ($displayEntries.Count -eq 0) {
        Write-Host '  No notifications yet.' -ForegroundColor DarkGray
    } else {
        for ($i = 0; $i -lt $displayEntries.Count; $i++) {
            $entry = $displayEntries[$i]
            Write-CenterEntry -Entry $entry -Index $i -SelectedIndex $SelectedIndex -ChatNames $ChatNames
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Notice)) {
        Write-Host "`n$Notice" -ForegroundColor Yellow
    }
    Write-Host "`nSelection: $InputBuffer" -NoNewline -ForegroundColor Green
}

function Update-CenterSelection {
    param(
        [object[]]$Events,
        [hashtable]$ChatNames,
        [int]$PreviousIndex,
        [int]$SelectedIndex
    )

    $displayEntries = @(Get-AgentNotificationDisplayEntries -Events $Events)
    if ($PreviousIndex -lt 0 -or $SelectedIndex -lt 0 -or
        $PreviousIndex -ge $displayEntries.Count -or $SelectedIndex -ge $displayEntries.Count -or
        $script:centerWindowWidth -ne [Console]::WindowWidth) {
        return $false
    }

    try {
        $escape = [char]27
        $indexes = @(@($PreviousIndex, $SelectedIndex) | Select-Object -Unique)
        foreach ($index in $indexes) {
            $rowsUp = $displayEntries.Count + 1 - $index
            Write-Host "$escape[s$escape[$($rowsUp)A`r$escape[2K" -NoNewline
            Write-CenterEntry -Entry $displayEntries[$index] -Index $index `
                -SelectedIndex $SelectedIndex -ChatNames $ChatNames -NoNewline
            Write-Host "$escape[u" -NoNewline
        }
        return $true
    } catch {
        return $false
    }
}

$events = @()
$chatNames = Read-AgentNotificationChatNameCache -StateRoot $StateRoot
$inputBuffer = ''
$notice = ''
$lastSignature = ''
$needsRender = $true
$selectedNotificationIndex = -1
$selectedChatKey = $null
$notificationSelectionPinned = $false

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
            $displayEntries = @(Get-AgentNotificationDisplayEntries -Events $events)
            if ($displayEntries.Count -eq 0) {
                $selectedNotificationIndex = -1
                $selectedChatKey = $null
                $notificationSelectionPinned = $false
            } elseif ($notificationSelectionPinned) {
                $selectedNotificationIndex = Find-AgentNotificationDisplayIndex -Events $events -ChatKey $selectedChatKey
                if ($selectedNotificationIndex -lt 0) {
                    $selectedNotificationIndex = Get-InitialListSelectionIndex -Count $displayEntries.Count -Position Last
                    $notificationSelectionPinned = $false
                }
                $selectedChatKey = Get-AgentNotificationChatKey -Event $displayEntries[$selectedNotificationIndex].event
            } else {
                $selectedNotificationIndex = Get-InitialListSelectionIndex -Count $displayEntries.Count -Position Last
                $selectedChatKey = Get-AgentNotificationChatKey -Event $displayEntries[$selectedNotificationIndex].event
            }
            $lastSignature = $signature
            $needsRender = $true
        }

        if ($needsRender) {
            Show-Center -Events $events -ChatNames $chatNames -InputBuffer $inputBuffer -Notice $notice `
                -SelectedIndex $selectedNotificationIndex
            $needsRender = $false
        }

        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::UpArrow -or $key.Key -eq [ConsoleKey]::DownArrow) {
                $displayEntries = @(Get-AgentNotificationDisplayEntries -Events $events)
                $direction = if ($key.Key -eq [ConsoleKey]::UpArrow) { -1 } else { 1 }
                $previousNotificationIndex = $selectedNotificationIndex
                $hadTransientText = (-not [string]::IsNullOrEmpty($inputBuffer) -or -not [string]::IsNullOrWhiteSpace($notice))
                $selectedNotificationIndex = Move-ListSelectionIndex -Index $selectedNotificationIndex `
                    -Count $displayEntries.Count -Direction $direction
                if ($selectedNotificationIndex -ge 0) {
                    $selectedChatKey = Get-AgentNotificationChatKey -Event $displayEntries[$selectedNotificationIndex].event
                    $notificationSelectionPinned = $true
                }
                $inputBuffer = ''
                $notice = ''
                if ($hadTransientText -or -not (Update-CenterSelection -Events $events -ChatNames $chatNames `
                    -PreviousIndex $previousNotificationIndex -SelectedIndex $selectedNotificationIndex)) {
                    $needsRender = $true
                }
                continue
            }
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
                    $selectedNotificationIndex = -1
                    $selectedChatKey = $null
                    $notificationSelectionPinned = $false
                    $inputBuffer = ''
                    $notice = ''
                    $lastSignature = ''
                    $needsRender = $true
                    continue
                }
                $selection = 0
                $event = $null
                if ([string]::IsNullOrEmpty($inputBuffer)) {
                    $displayEntries = @(Get-AgentNotificationDisplayEntries -Events $events)
                    if ($selectedNotificationIndex -ge 0 -and $selectedNotificationIndex -lt $displayEntries.Count) {
                        $event = $displayEntries[$selectedNotificationIndex].event
                    }
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
