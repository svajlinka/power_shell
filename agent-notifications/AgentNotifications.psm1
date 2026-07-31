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
            ProfileGuid = $env:AI_NOTIFY_PROFILE_GUID
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
        'PreToolUse' {
            $toolName = Get-AgentNotificationProperty -InputObject $InputObject -Name 'tool_name'
            if ("$toolName" -ne 'request_user_input') { return $null }

            $status = 'input'
            $toolInput = Get-AgentNotificationProperty -InputObject $InputObject -Name 'tool_input'
            $questions = @(Get-AgentNotificationProperty -InputObject $toolInput -Name 'questions')
            foreach ($question in $questions) {
                $candidate = Get-AgentNotificationProperty -InputObject $question -Name 'question'
                if (-not [string]::IsNullOrWhiteSpace("$candidate")) {
                    $message = $candidate
                    break
                }
            }
            if ([string]::IsNullOrWhiteSpace("$message")) {
                $message = 'Codex is waiting for your input'
            }
        }
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
    $profileGuid = if ($Metadata.ContainsKey('ProfileGuid')) { $Metadata.ProfileGuid } else { '' }
    $sessionId = Get-AgentNotificationProperty -InputObject $InputObject -Name 'session_id'

    return [pscustomobject][ordered]@{
        id        = [guid]::NewGuid().ToString('N')
        timestamp = [DateTimeOffset]::Now.ToString('o')
        source    = ConvertTo-AgentNotificationPreview -Value $Metadata.Source -MaximumLength 20
        status    = $status
        project   = ConvertTo-AgentNotificationPreview -Value $Metadata.Project -MaximumLength 80
        profileGuid = ConvertTo-AgentNotificationPreview -Value $profileGuid -MaximumLength 50
        pane      = $pane
        window    = ConvertTo-AgentNotificationPreview -Value $Metadata.Window -MaximumLength 100
        guard     = ConvertTo-AgentNotificationPreview -Value $Metadata.Guard -MaximumLength 180
        message   = ConvertTo-AgentNotificationPreview -Value $message -MaximumLength 160
        sessionId = ConvertTo-AgentNotificationPreview -Value $sessionId -MaximumLength 100
        handled   = $false
    }
}

function Get-AgentNotificationProjectName {
    param([AllowNull()][object]$Event)

    $project = "$(Get-AgentNotificationProperty -InputObject $Event -Name 'project')".Trim()
    if ([string]::IsNullOrWhiteSpace($project)) { return 'Unknown project' }
    return ($project -replace '\s+\(d\s+.+\)$', '').Trim()
}

function Get-AgentNotificationChatName {
    param(
        [Parameter(Mandatory = $true)][object]$Event,
        [string]$CodexSessionIndexPath,
        [string]$CodexHistoryPath,
        [string]$ClaudeHistoryPath
    )

    $source = "$(Get-AgentNotificationProperty -InputObject $Event -Name 'source')".Trim()
    $sessionId = "$(Get-AgentNotificationProperty -InputObject $Event -Name 'sessionId')".Trim()
    if ([string]::IsNullOrWhiteSpace($CodexSessionIndexPath)) {
        $CodexSessionIndexPath = Join-Path $env:USERPROFILE '.codex\session_index.jsonl'
    }
    if ([string]::IsNullOrWhiteSpace($CodexHistoryPath)) {
        $CodexHistoryPath = Join-Path $env:USERPROFILE '.codex\history.jsonl'
    }
    if ([string]::IsNullOrWhiteSpace($ClaudeHistoryPath)) {
        $ClaudeHistoryPath = Join-Path $env:USERPROFILE '.claude\history.jsonl'
    }

    $name = ''
    if (-not [string]::IsNullOrWhiteSpace($sessionId) -and $source -eq 'Codex') {
        if (Test-Path -LiteralPath $CodexSessionIndexPath) {
            foreach ($line in [IO.File]::ReadAllLines($CodexSessionIndexPath, [Text.Encoding]::UTF8)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $record = $line | ConvertFrom-Json
                    if ("$(Get-AgentNotificationProperty $record 'id')" -eq $sessionId) {
                        $candidate = "$(Get-AgentNotificationProperty $record 'thread_name')".Trim()
                        if (-not [string]::IsNullOrWhiteSpace($candidate)) { $name = $candidate }
                    }
                } catch { }
            }
        }
        if ([string]::IsNullOrWhiteSpace($name) -and (Test-Path -LiteralPath $CodexHistoryPath)) {
            foreach ($line in [IO.File]::ReadLines($CodexHistoryPath, [Text.Encoding]::UTF8)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $record = $line | ConvertFrom-Json
                    $candidate = "$(Get-AgentNotificationProperty $record 'text')".Trim()
                    if ("$(Get-AgentNotificationProperty $record 'session_id')" -eq $sessionId -and
                        -not [string]::IsNullOrWhiteSpace($candidate) -and -not $candidate.StartsWith('/')) {
                        $name = $candidate
                        break
                    }
                } catch { }
            }
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($sessionId) -and $source -eq 'Claude' -and (Test-Path -LiteralPath $ClaudeHistoryPath)) {
        foreach ($line in [IO.File]::ReadAllLines($ClaudeHistoryPath, [Text.Encoding]::UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $record = $line | ConvertFrom-Json
                $candidate = "$(Get-AgentNotificationProperty $record 'display')".Trim()
                if ("$(Get-AgentNotificationProperty $record 'sessionId')" -eq $sessionId -and
                    -not [string]::IsNullOrWhiteSpace($candidate) -and -not $candidate.StartsWith('/')) {
                    $name = $candidate
                    break
                }
            } catch { }
        }
    }

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = if ([string]::IsNullOrWhiteSpace($source)) { 'Agent chat' } else { "$source chat" }
    }
    return ConvertTo-AgentNotificationPreview -Value $name -MaximumLength 60
}

function Get-AgentNotificationDisplayEvents {
    param([object[]]$Events, [int]$MaximumCount = 30)

    if ($null -eq $Events -or $Events.Count -eq 0 -or $MaximumCount -le 0) { return @() }
    return @($Events | Select-Object -Last $MaximumCount)
}

function Get-AgentNotificationDisplayEntries {
    param([object[]]$Events, [int]$MaximumCount = 30)

    $visible = @(Get-AgentNotificationDisplayEvents -Events $Events -MaximumCount $MaximumCount)
    $entries = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $visible.Count; $i++) {
        $entries.Add([pscustomobject]@{
            number = $visible.Count - $i
            event  = $visible[$i]
        })
    }
    return $entries.ToArray()
}

function Find-AgentNotificationDisplayEvent {
    param(
        [object[]]$Events,
        [Parameter(Mandatory = $true)][int]$Number,
        [int]$MaximumCount = 30
    )

    $entry = @(Get-AgentNotificationDisplayEntries -Events $Events -MaximumCount $MaximumCount |
        Where-Object { $_.number -eq $Number } | Select-Object -First 1)
    if ($entry.Count -eq 0) { return $null }
    return $entry[0].event
}

function Test-AgentNotificationHandled {
    param([AllowNull()][object]$Event)

    $value = Get-AgentNotificationProperty -InputObject $Event -Name 'handled'
    return ($null -ne $value -and [bool]$value)
}

function Format-AgentNotificationDisplayLine {
    param(
        [Parameter(Mandatory = $true)][object]$Event,
        [Parameter(Mandatory = $true)][int]$Number,
        [string]$CodexSessionIndexPath,
        [string]$CodexHistoryPath,
        [string]$ClaudeHistoryPath
    )

    $timestamp = Get-AgentNotificationProperty -InputObject $Event -Name 'timestamp'
    $time = ([DateTimeOffset]::Parse("$timestamp")).ToLocalTime().ToString('HH:mm:ss')
    $project = Get-AgentNotificationProjectName -Event $Event
    $chat = Get-AgentNotificationChatName -Event $Event -CodexSessionIndexPath $CodexSessionIndexPath `
        -CodexHistoryPath $CodexHistoryPath -ClaudeHistoryPath $ClaudeHistoryPath
    return '{0,3}  {1}  {2}  {3}' -f $Number, $time, $project, $chat
}

function Find-AgentNotificationProjectProfile {
    param(
        [Parameter(Mandatory = $true)][object]$Event,
        [Parameter(Mandatory = $true)][object[]]$Profiles
    )

    $eventGuid = Get-AgentNotificationProperty -InputObject $Event -Name 'profileGuid'
    if ([string]::IsNullOrWhiteSpace("$eventGuid")) {
        $eventWindow = Get-AgentNotificationProperty -InputObject $Event -Name 'window'
        if ("$eventWindow" -match '^agent-project-([0-9a-fA-F]{32})$') {
            $eventGuid = $Matches[1]
        }
    }
    if (-not [string]::IsNullOrWhiteSpace("$eventGuid")) {
        $normalizedEventGuid = "$eventGuid" -replace '[{}-]', ''
        $match = @($Profiles | Where-Object {
            ("$($_.guid)" -replace '[{}-]', '') -eq $normalizedEventGuid
        } | Select-Object -First 1)
        if ($match.Count -gt 0) { return $match[0] }
    }

    $projectName = Get-AgentNotificationProperty -InputObject $Event -Name 'project'
    if (-not [string]::IsNullOrWhiteSpace("$projectName")) {
        $match = @($Profiles | Where-Object { "$($_.name)" -eq "$projectName" } | Select-Object -First 1)
        if ($match.Count -gt 0) { return $match[0] }
    }
    return $null
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

function Find-AgentNotificationEventById {
    param(
        [Parameter(Mandatory = $true)][string]$EventId,
        [string]$StateRoot
    )

    if ($EventId -notmatch '^[0-9a-fA-F]{32}$') { return $null }
    return @(Read-AgentNotificationEvents -StateRoot $StateRoot | Where-Object {
        "$(Get-AgentNotificationProperty -InputObject $_ -Name 'id')" -eq $EventId
    } | Select-Object -First 1)[0]
}

function ConvertFrom-AgentNotificationUri {
    param([Parameter(Mandatory = $true)][string]$Uri)

    try { $parsed = [Uri]$Uri } catch { return $null }
    if (-not $parsed.IsAbsoluteUri -or $parsed.Scheme -cne 'agentnotify' -or
        $parsed.Host -cne 'open' -or -not [string]::IsNullOrEmpty($parsed.Query) -or
        -not [string]::IsNullOrEmpty($parsed.Fragment)) {
        return $null
    }
    if ($parsed.AbsolutePath -notmatch '^/([0-9a-fA-F]{32})$') { return $null }
    return $Matches[1]
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

function Update-AgentNotificationHandledEvents {
    param(
        [AllowNull()][string]$EventId,
        [switch]$All,
        [string]$StateRoot
    )

    $root = Get-AgentNotificationStateRoot -StateRoot $StateRoot
    $eventFile = Join-Path $root 'events.jsonl'
    if (-not (Test-Path -LiteralPath $eventFile)) {
        return [pscustomobject]@{ matched = $false; changedCount = 0 }
    }

    $mutex = New-Object System.Threading.Mutex($false, 'Local\AgentNotifications.EventLog')
    $hasLock = $false
    $matched = $false
    $changedCount = 0
    try {
        try {
            $hasLock = $mutex.WaitOne(5000)
        } catch [System.Threading.AbandonedMutexException] {
            $hasLock = $true
        }
        if (-not $hasLock) { throw 'Timed out waiting for the notification event log.' }

        $output = New-Object System.Collections.Generic.List[string]
        foreach ($line in [IO.File]::ReadAllLines($eventFile, [Text.Encoding]::UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $event = $line | ConvertFrom-Json
                if ($All -or "$(Get-AgentNotificationProperty $event 'id')" -eq $EventId) {
                    $matched = $true
                    if (-not (Test-AgentNotificationHandled -Event $event)) {
                        $event | Add-Member -NotePropertyName handled -NotePropertyValue $true -Force
                        $line = $event | ConvertTo-Json -Compress -Depth 8
                        $changedCount++
                    }
                }
            } catch { }
            $output.Add($line)
        }
        if ($changedCount -gt 0) {
            $temporaryFile = Join-Path $root ('.events-' + [guid]::NewGuid().ToString('N') + '.tmp')
            try {
                [IO.File]::WriteAllLines($temporaryFile, $output.ToArray(), (New-Object Text.UTF8Encoding($false)))
                Move-Item -LiteralPath $temporaryFile -Destination $eventFile -Force
            } finally {
                if (Test-Path -LiteralPath $temporaryFile) { Remove-Item -LiteralPath $temporaryFile -Force }
            }
        }
    } finally {
        if ($hasLock) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
    return [pscustomobject]@{ matched = $matched; changedCount = $changedCount }
}

function Set-AgentNotificationHandled {
    param(
        [Parameter(Mandatory = $true)][string]$EventId,
        [string]$StateRoot
    )

    $result = Update-AgentNotificationHandledEvents -EventId $EventId -StateRoot $StateRoot
    return [bool]$result.matched
}

function Set-AllAgentNotificationsHandled {
    param([string]$StateRoot)

    $result = Update-AgentNotificationHandledEvents -All -StateRoot $StateRoot
    return [int]$result.changedCount
}

function New-AgentNotificationToastXml {
    param(
        [Parameter(Mandatory = $true)][object]$Event,
        [string]$ChatName
    )

    $eventId = "$(Get-AgentNotificationProperty -InputObject $Event -Name 'id')"
    if ($eventId -notmatch '^[0-9a-fA-F]{32}$') { throw 'The notification event ID is invalid.' }
    $project = Get-AgentNotificationProjectName -Event $Event
    $source = "$(Get-AgentNotificationProperty -InputObject $Event -Name 'source')".Trim()
    if ([string]::IsNullOrWhiteSpace($source)) { $source = 'Agent' }
    if ([string]::IsNullOrWhiteSpace($ChatName)) { $ChatName = Get-AgentNotificationChatName -Event $Event }

    $title = "$project - $source"
    $body = ConvertTo-AgentNotificationPreview -Value $ChatName -MaximumLength 60
    $activationUri = "agentnotify://open/$eventId"
    $escapedTitle = [System.Security.SecurityElement]::Escape($title)
    $escapedBody = [System.Security.SecurityElement]::Escape($body)
    $escapedUri = [System.Security.SecurityElement]::Escape($activationUri)
    return "<toast duration=`"short`"><visual><binding template=`"ToastGeneric`"><text>$escapedTitle</text><text>$escapedBody</text></binding></visual><actions><action content=`"Open chat`" arguments=`"$escapedUri`" activationType=`"protocol`" /></actions><audio src=`"ms-winsoundevent:Notification.Default`" /></toast>"
}

function Show-AgentNotificationToast {
    param([Parameter(Mandatory = $true)][object]$Event)

    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml((New-AgentNotificationToastXml -Event $Event))
    $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
    $toast.ExpirationTime = [DateTimeOffset]::Now.AddSeconds(10)
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
    'Get-AgentNotificationProjectName',
    'Get-AgentNotificationChatName',
    'Get-AgentNotificationDisplayEvents',
    'Get-AgentNotificationDisplayEntries',
    'Find-AgentNotificationDisplayEvent',
    'Test-AgentNotificationHandled',
    'Format-AgentNotificationDisplayLine',
    'Find-AgentNotificationProjectProfile',
    'Write-AgentNotificationEvent',
    'Read-AgentNotificationEvents',
    'Find-AgentNotificationEventById',
    'ConvertFrom-AgentNotificationUri',
    'Clear-AgentNotificationEvents',
    'Set-AgentNotificationHandled',
    'Set-AllAgentNotificationsHandled',
    'New-AgentNotificationToastXml',
    'Show-AgentNotificationToast',
    'Test-AgentNotificationTarget'
)
