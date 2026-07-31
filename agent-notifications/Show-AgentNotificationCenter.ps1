param([string]$StateRoot)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentNotifications.psm1') -Force -DisableNameChecking

$created = $false
$centerMutex = New-Object System.Threading.Mutex($true, 'Local\AgentNotifications.Center', [ref]$created)
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

    if ($Events.Count -eq 0) {
        Write-Host '  No notifications yet.' -ForegroundColor DarkGray
    } else {
        $first = [Math]::Max(0, $Events.Count - 30)
        for ($i = $first; $i -lt $Events.Count; $i++) {
            $event = $Events[$i]
            $time = ([DateTimeOffset]::Parse($event.timestamp)).ToLocalTime().ToString('HH:mm:ss')
            $source = ("$($event.source)").PadRight(6)
            $status = ("$($event.status)").PadRight(8)
            $line = '{0,4}  {1}  {2}  {3}  {4}  pane {5}  {6}' -f ($i + 1), $time, $source, $status, $event.project, $event.pane, $event.message
            Write-Host $line
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
        $signature = if (Test-Path -LiteralPath $eventFile) {
            $item = Get-Item -LiteralPath $eventFile
            "$($item.Length):$($item.LastWriteTimeUtc.Ticks)"
        } else { 'missing' }

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
                if ([int]::TryParse($inputBuffer, [ref]$selection) -and $selection -ge 1 -and $selection -le $events.Count) {
                    $event = $events[$selection - 1]
                    if (Test-AgentNotificationTarget -Guard $event.guard) {
                        Start-Process wt.exe -ArgumentList @('-w', $event.window, 'focus-tab', '-t', '0')
                        $notice = "Focused $($event.project); notification came from pane $($event.pane)."
                    } else {
                        $notice = 'That project window is no longer open.'
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
