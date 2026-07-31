Set-StrictMode -Version 2.0

function Get-AgentNotificationStateRoot {
    param([string]$StateRoot)

    if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
        return $StateRoot
    }

    return (Join-Path $env:LOCALAPPDATA 'AgentNotifications')
}

function ConvertTo-AgentNotificationPreview {
    param(
        [AllowNull()]
        [object]$Value,
        [int]$MaximumLength = 160
    )

    if ($null -eq $Value) { return '' }

    $text = "$Value" -replace '[\r\n\t]+', ' ' -replace '\s{2,}', ' '
    $text = $text.Trim()
    if ($text.Length -le $MaximumLength) { return $text }
    return $text.Substring(0, [Math]::Max(0, $MaximumLength - 1)) + [char]0x2026
}

function Get-AgentNotificationProperty {
    param(
        [AllowNull()]
        [object]$InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-AgentNotificationEvent {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,
        [hashtable]$Metadata
    )

    if ($null -eq $Metadata) {
        $Metadata = @{
            Enabled = $env:AI_NOTIFY_ENABLED
            Source  = $env:AI_NOTIFY_SOURCE
            Project = $env:AI_NOTIFY_PROJECT
            Pane    = $env:AI_NOTIFY_PANE
            Window  = $env:AI_NOTIFY_WINDOW
            Guard   = $env:AI_NOTIFY_GUARD
        }
    }

    if ($Metadata.Enabled -ne '1') { return $null }

    $hookName = Get-AgentNotificationProperty -InputObject $InputObject -Name 'hook_event_name'
    $status = $null
    $message = ''

    switch ($hookName) {
        'PermissionRequest' {
            $status = 'approval'
            $toolInput = Get-AgentNotificationProperty -InputObject $InputObject -Name 'tool_input'
            $description = Get-AgentNotificationProperty -InputObject $toolInput -Name 'description'
            $toolName = Get-AgentNotificationProperty -InputObject $InputObject -Name 'tool_name'
            if (-not [string]::IsNullOrWhiteSpace("$description")) {
                $message = $description
            } elseif (-not [string]::IsNullOrWhiteSpace("$toolName")) {
                $message = "$toolName needs approval"
            } else {
                $message = 'Approval required'
            }
        }
        'Notification' {
            $notificationType = Get-AgentNotificationProperty -InputObject $InputObject -Name 'notification_type'
            if ($notificationType -eq 'permission_prompt') {
                $status = 'approval'
            } elseif ($notificationType -in @('idle_prompt', 'elicitation_dialog')) {
                $status = 'input'
            } else {
                return $null
            }
            $message = Get-AgentNotificationProperty -InputObject $InputObject -Name 'message'
        }
        'Stop' {
            $status = 'finished'
            $message = Get-AgentNotificationProperty -InputObject $InputObject -Name 'last_assistant_message'
            if ([string]::IsNullOrWhiteSpace("$message")) {
                $message = 'Turn finished'
            }
        }
        default { return $null }
    }

    $pane = 0
    [void][int]::TryParse("$($Metadata.Pane)", [ref]$pane)

    return [pscustomobject][ordered]@{
        id        = [guid]::NewGuid().ToString('N')
        timestamp = [DateTimeOffset]::Now.ToString('o')
        source    = ConvertTo-AgentNotificationPreview -Value $Metadata.Source -MaximumLength 20
        status    = $status
        project   = ConvertTo-AgentNotificationPreview -Value $Metadata.Project -MaximumLength 80
        pane      = $pane
        window    = ConvertTo-AgentNotificationPreview -Value $Metadata.Window -MaximumLength 100
        guard     = ConvertTo-AgentNotificationPreview -Value $Metadata.Guard -MaximumLength 180
        message   = ConvertTo-AgentNotificationPreview -Value $message -MaximumLength 160
    }
}

function Write-AgentNotificationEvent {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Event,
        [string]$StateRoot
    )

    $root = Get-AgentNotificationStateRoot -StateRoot $StateRoot
    [void](New-Item -ItemType Directory -Path $root -Force)
    $eventFile = Join-Path $root 'events.jsonl'
    $mutex = New-Object System.Threading.Mutex($false, 'Local\AgentNotifications.EventLog')
    $hasLock = $false
    try {
        try {
            $hasLock = $mutex.WaitOne(5000)
        } catch [System.Threading.AbandonedMutexException] {
            $hasLock = $true
        }
        if (-not $hasLock) { throw 'Timed out waiting for the notification event log.' }
        $json = $Event | ConvertTo-Json -Compress -Depth 8
        Add-Content -LiteralPath $eventFile -Value $json -Encoding UTF8
    } finally {
        if ($hasLock) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }

    return $eventFile
}

function Read-AgentNotificationEvents {
    param([string]$StateRoot)

    $eventFile = Join-Path (Get-AgentNotificationStateRoot -StateRoot $StateRoot) 'events.jsonl'
    if (-not (Test-Path -LiteralPath $eventFile)) { return @() }

    $events = New-Object System.Collections.Generic.List[object]
    foreach ($line in (Get-Content -LiteralPath $eventFile -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $events.Add(($line | ConvertFrom-Json)) } catch { }
    }
    return $events.ToArray()
}

function Clear-AgentNotificationEvents {
    param([string]$StateRoot)

    $root = Get-AgentNotificationStateRoot -StateRoot $StateRoot
    [void](New-Item -ItemType Directory -Path $root -Force)
    $eventFile = Join-Path $root 'events.jsonl'
    $mutex = New-Object System.Threading.Mutex($false, 'Local\AgentNotifications.EventLog')
    $hasLock = $false
    try {
        try {
            $hasLock = $mutex.WaitOne(5000)
        } catch [System.Threading.AbandonedMutexException] {
            $hasLock = $true
        }
        if (-not $hasLock) { throw 'Timed out waiting for the notification event log.' }
        Set-Content -LiteralPath $eventFile -Value $null -Encoding UTF8
    } finally {
        if ($hasLock) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Show-AgentNotificationToast {
    param([Parameter(Mandatory = $true)][object]$Event)

    $title = "Agent Notifications - $($Event.source) $($Event.status)"
    $body = "$($Event.project) - pane $($Event.pane)"
    if (-not [string]::IsNullOrWhiteSpace("$($Event.message)")) {
        $body += "`n$($Event.message)"
    }

    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $escapedTitle = [System.Security.SecurityElement]::Escape($title)
    $escapedBody = [System.Security.SecurityElement]::Escape($body)
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml("<toast><visual><binding template=`"ToastGeneric`"><text>$escapedTitle</text><text>$escapedBody</text></binding></visual><audio src=`"ms-winsoundevent:Notification.Default`" /></toast>")
    $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
    $appId = (Get-StartApps | Where-Object { $_.Name -eq 'Windows PowerShell' } | Select-Object -First 1 -ExpandProperty AppID)
    if ([string]::IsNullOrWhiteSpace($appId)) { throw 'Windows PowerShell application identity was not found.' }
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
}

function Test-AgentNotificationTarget {
    param([AllowNull()][string]$Guard)

    if ([string]::IsNullOrWhiteSpace($Guard)) { return $false }
    try {
        $mutex = [System.Threading.Mutex]::OpenExisting($Guard)
        $mutex.Dispose()
        return $true
    } catch {
        return $false
    }
}

Export-ModuleMember -Function @(
    'Get-AgentNotificationStateRoot',
    'ConvertTo-AgentNotificationPreview',
    'ConvertTo-AgentNotificationEvent',
    'Write-AgentNotificationEvent',
    'Read-AgentNotificationEvents',
    'Clear-AgentNotificationEvents',
    'Show-AgentNotificationToast',
    'Test-AgentNotificationTarget'
)
