$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'agent-notifications\AgentNotifications.psm1'
$receiverPath = Join-Path $repoRoot 'agent-notifications\Receive-AgentNotification.ps1'
$installerPath = Join-Path $repoRoot 'agent-notifications\Install-AgentNotifications.ps1'
Import-Module $modulePath -Force -DisableNameChecking
. (Join-Path $repoRoot 'powershell-profile.ps1')

$script:Assertions = 0
function Assert-Equal {
    param([object]$Actual, [object]$Expected, [string]$Message)
    $script:Assertions++
    if ("$Actual" -ne "$Expected") {
        throw "$Message. Expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}

function Get-EmbeddedPowerShellScripts {
    param([string]$CommandLine)

    return @([regex]::Matches($CommandLine, '-EncodedCommand\s+([A-Za-z0-9+/=]+)') | ForEach-Object {
        [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($_.Groups[1].Value))
    })
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('agent-notifications-tests-' + [guid]::NewGuid().ToString('N'))
$stateRoot = Join-Path $testRoot 'state'
$codexHome = Join-Path $testRoot 'codex'
$codexIndex = Join-Path $testRoot 'session_index.jsonl'
$codexHistory = Join-Path $testRoot 'codex-history.jsonl'
$claudeHistory = Join-Path $testRoot 'history.jsonl'

try {
    [void](New-Item -ItemType Directory -Path $testRoot -Force)
    $metadata = @{
        Enabled = '1'; Source = 'Codex'; Project = 'sample-project'; Pane = '2'
        ProfileGuid = '{11111111-2222-3333-4444-555555555555}'
        Window = 'agent-project-123'; Guard = 'Local\AgentNotifications.Project.123'
    }
    $approvalPayload = '{"hook_event_name":"PermissionRequest","session_id":"codex-session","tool_name":"Bash","tool_input":{"description":"Run tests\r\nwith approval"}}' | ConvertFrom-Json
    $approval = ConvertTo-AgentNotificationEvent -InputObject $approvalPayload -Metadata $metadata
    Assert-Equal $approval.status 'approval' 'Codex permission status was not normalized'
    Assert-Equal $approval.message 'Run tests with approval' 'Approval preview was not sanitized'
    Assert-Equal $approval.pane 2 'Pane number was not retained'
    Assert-Equal $approval.profileGuid $metadata.ProfileGuid 'Project profile GUID was not retained for reopening'
    Assert-Equal $approval.sessionId 'codex-session' 'Hook session ID was not retained for chat-name lookup'
    Assert-True (-not $approval.handled) 'New notification was unexpectedly marked handled'
    Assert-Equal (Get-AgentNotificationProjectName ([pscustomobject]@{ project = 'power_shell (d C:\Users\example\dev\power_shell)' })) 'power_shell' 'Project path was not removed from the compact name'

    @(
        '{"id":"codex-session","thread_name":"Earlier name"}',
        '{"id":"other-session","thread_name":"Ignore me"}',
        '{"id":"codex-session","thread_name":"Fixa räksmörgåsen"}'
    ) | Set-Content -LiteralPath $codexIndex -Encoding UTF8
    @(
        '{"session_id":"codex-session","text":"History title must not override the index"}',
        '{"session_id":"history-session","text":"/plan"}',
        '{not valid json}',
        '{"session_id":"other-session","text":"Ignore unrelated history"}',
        '{"session_id":"history-session","text":"Första riktiga frågan"}',
        '{"session_id":"history-session","text":"Later request"}'
    ) | Set-Content -LiteralPath $codexHistory -Encoding UTF8
    Assert-Equal (Get-AgentNotificationChatName -Event $approval -CodexSessionIndexPath $codexIndex `
        -CodexHistoryPath $codexHistory -ClaudeHistoryPath $claudeHistory) `
        'Fixa räksmörgåsen' 'Codex chat name was not read as UTF-8 from the latest session index entry'
    $historyEvent = [pscustomobject]@{ source = 'Codex'; sessionId = 'history-session' }
    Assert-Equal (Get-AgentNotificationChatName -Event $historyEvent `
        -CodexSessionIndexPath (Join-Path $testRoot 'missing-index.jsonl') `
        -CodexHistoryPath $codexHistory -ClaudeHistoryPath $claudeHistory) `
        'Första riktiga frågan' 'Unindexed Codex chat did not use its first meaningful history request'

    $profiles = @(
        [pscustomobject]@{ name = 'sample-project'; guid = '{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}'; startingDirectory = 'C:\dev\sample-project' },
        [pscustomobject]@{ name = 'renamed-project'; guid = $metadata.ProfileGuid; startingDirectory = 'C:\dev\renamed-project' }
    )
    $resolvedByGuid = Find-AgentNotificationProjectProfile -Event $approval -Profiles $profiles
    Assert-Equal $resolvedByGuid.name 'renamed-project' 'Closed project was not resolved by stable profile GUID'
    $windowFallbackEvent = [pscustomobject]@{ project = 'truncated'; window = 'agent-project-11111111222233334444555555555555' }
    $resolvedByWindow = Find-AgentNotificationProjectProfile -Event $windowFallbackEvent -Profiles $profiles
    Assert-Equal $resolvedByWindow.name 'renamed-project' 'Existing notification was not resolved from its stable window name'
    $legacyEvent = [pscustomobject]@{ project = 'sample-project' }
    $resolvedByName = Find-AgentNotificationProjectProfile -Event $legacyEvent -Profiles $profiles
    Assert-Equal $resolvedByName.name 'sample-project' 'Legacy notification was not resolved by project name'
    $missingProfile = Find-AgentNotificationProjectProfile -Event ([pscustomobject]@{ project = 'missing-project' }) -Profiles $profiles
    Assert-True ($null -eq $missingProfile) 'Missing project profile unexpectedly resolved'

    $claudePayload = '{"hook_event_name":"Notification","session_id":"claude-session","notification_type":"idle_prompt","message":"Claude is waiting"}' | ConvertFrom-Json
    $metadata.Source = 'Claude'
    $inputEvent = ConvertTo-AgentNotificationEvent -InputObject $claudePayload -Metadata $metadata
    Assert-Equal $inputEvent.status 'input' 'Claude idle prompt was not normalized'
    @(
        '{"display":"/compact","sessionId":"claude-session"}',
        '{"display":"Build the notification center","sessionId":"claude-session"}',
        '{"display":"Later prompt","sessionId":"claude-session"}'
    ) | Set-Content -LiteralPath $claudeHistory -Encoding UTF8
    Assert-Equal (Get-AgentNotificationChatName -Event $inputEvent -CodexSessionIndexPath $codexIndex `
        -CodexHistoryPath $codexHistory -ClaudeHistoryPath $claudeHistory) `
        'Build the notification center' 'Claude chat name did not use the first non-command prompt'
    Assert-Equal (Get-AgentNotificationChatName -Event ([pscustomobject]@{ source = 'Codex' }) `
        -CodexSessionIndexPath $codexIndex -CodexHistoryPath $codexHistory `
        -ClaudeHistoryPath $claudeHistory) 'Codex chat' 'Legacy notification did not receive a safe chat fallback'

    $manyEvents = @(1..35 | ForEach-Object { [pscustomobject]@{ id = "event-$_" } })
    $displayEvents = @(Get-AgentNotificationDisplayEvents -Events $manyEvents)
    Assert-Equal $displayEvents.Count 30 'Notification display was not limited to the latest 30 events'
    Assert-Equal $displayEvents[0].id 'event-6' 'Visible notifications did not start with the oldest retained event'
    Assert-Equal $displayEvents[29].id 'event-35' 'Latest notification was not placed at the bottom'
    $displayEntries = @(Get-AgentNotificationDisplayEntries -Events $manyEvents)
    Assert-Equal $displayEntries[0].number 30 'Top notification did not receive the oldest visible number'
    Assert-Equal $displayEntries[29].number 1 'Latest notification at the bottom was not numbered 1'
    Assert-Equal (Find-AgentNotificationDisplayEvent -Events $manyEvents -Number 1).id 'event-35' 'Selection 1 did not resolve to the latest notification'

    $stopPayload = [pscustomobject]@{
        hook_event_name = 'Stop'
        last_assistant_message = ('x' * 250)
    }
    $finished = ConvertTo-AgentNotificationEvent -InputObject $stopPayload -Metadata $metadata
    Assert-Equal $finished.status 'finished' 'Stop status was not normalized'
    Assert-True ($finished.message.Length -eq 160) 'Final-message preview was not truncated to 160 characters'

    $metadata.Enabled = '0'
    $ignored = ConvertTo-AgentNotificationEvent -InputObject $stopPayload -Metadata $metadata
    Assert-True ($null -eq $ignored) 'Events outside launcher scope were not ignored'
    $metadata.Enabled = '1'

    [void](Write-AgentNotificationEvent -Event $approval -StateRoot $stateRoot)
    [void](Write-AgentNotificationEvent -Event $inputEvent -StateRoot $stateRoot)
    $events = @(Read-AgentNotificationEvents -StateRoot $stateRoot)
    Assert-Equal $events.Count 2 'Event log did not round-trip both events'
    Assert-Equal $events[1].source 'Claude' 'Event log changed event content'
    Assert-True (-not (Test-AgentNotificationHandled -Event $events[0])) 'Unread notification did not render as unhandled'
    Assert-True (Set-AgentNotificationHandled -EventId $approval.id -StateRoot $stateRoot) 'Handled notification was not updated'
    $events = @(Read-AgentNotificationEvents -StateRoot $stateRoot)
    Assert-True (Test-AgentNotificationHandled -Event $events[0]) 'Handled state did not persist after rereading the event log'
    Assert-True (-not (Test-AgentNotificationHandled -Event ([pscustomobject]@{ id = 'legacy' }))) 'Legacy notification without handled state was not treated as unhandled'
    $compactLine = Format-AgentNotificationDisplayLine -Event $events[0] -Number 1 `
        -CodexSessionIndexPath $codexIndex -CodexHistoryPath $codexHistory -ClaudeHistoryPath $claudeHistory
    Assert-True ($compactLine -match '^\s*1\s+\d{2}:\d{2}:\d{2}\s+sample-project\s+Fixa räksmörgåsen$') 'Compact notification row did not contain only number, time, project, and chat name'
    Assert-True ($compactLine -notmatch 'Codex|approval|pane|Run tests|C:\\') 'Compact notification row leaked hidden routing or message details'

    Clear-AgentNotificationEvents -StateRoot $stateRoot
    Assert-Equal @(Read-AgentNotificationEvents -StateRoot $stateRoot).Count 0 'Clear did not empty notification history'

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installerPath -CodexHome $codexHome -StateRoot $stateRoot | Out-Null
    $codexProfile = Join-Path $codexHome 'agent-notifications.config.toml'
    $claudeSettings = Join-Path $stateRoot 'claude-settings.json'
    Assert-True (Test-Path -LiteralPath $codexProfile) 'Installer did not create the Codex profile'
    Assert-True (Test-Path -LiteralPath $claudeSettings) 'Installer did not create Claude settings'
    Assert-True ((Get-Content -Raw -LiteralPath $codexProfile) -match '\[\[hooks\.PermissionRequest\]\]') 'Codex approval hook is missing'
    $parsedClaude = Get-Content -Raw -LiteralPath $claudeSettings | ConvertFrom-Json
    Assert-True ($null -ne $parsedClaude.hooks.Notification) 'Claude notification hook is missing'
    Assert-True ($null -ne $parsedClaude.hooks.Stop) 'Claude stop hook is missing'

    $freshControl = Get-AgentControlCenterArguments -LauncherRunning $false -NotificationsRunning $false
    Assert-True ($freshControl -match 'new-tab --title Projects') 'Fresh control center does not create the launcher pane first'
    Assert-True ($freshControl -match 'sp -V -s 0\.5 --title Notifications') 'Fresh control center does not create an equal notification split'
    $existingControl = Get-AgentControlCenterArguments -LauncherRunning $true -NotificationsRunning $true
    Assert-Equal $existingControl '-w agent-control-center focus-tab -t 0' 'Existing control center is not focused without adding panes'
    $missingNotifications = Get-AgentControlCenterArguments -LauncherRunning $true -NotificationsRunning $false
    Assert-True ($missingNotifications -match '--title Notifications') 'Missing notification pane is not restored'
    Assert-True ($missingNotifications -notmatch '--title Projects') 'Restoring notifications also creates a launcher pane'
    $missingLauncher = Get-AgentControlCenterArguments -LauncherRunning $false -NotificationsRunning $true
    Assert-True ($missingLauncher -match '--title Projects') 'Missing launcher pane is not restored'
    Assert-True ($missingLauncher -match 'swap-pane left') 'Restored launcher pane is not moved to the left column'

    $projectGuid = '{1A5FF801-DEAD-BEEF-8123-0123456789AB}'
    $projectWindow = Get-ProjectWindowName -ProfileGuid $projectGuid
    Assert-Equal $projectWindow 'agent-project-1a5ff801deadbeef81230123456789ab' 'Project window identity is not stable and normalized'
    Assert-Equal (Get-ProjectWindowName -ProfileGuid $projectGuid) $projectWindow 'Repeated project identity generation changed the window name'
    $otherWindow = Get-ProjectWindowName -ProfileGuid '{2A5FF801-DEAD-BEEF-8123-0123456789AB}'
    Assert-True ($otherWindow -ne $projectWindow) 'Different project profiles received the same window name'
    Assert-Equal ((Get-UniqueProjectChoices -Answer '3 1,3 2 1') -join ',') '3,1,2' 'Repeated project choices were not deduplicated in input order'
    Assert-Equal (Get-ProjectDisplayName -ProfilePath 'C:\dev\power_shell' -FallbackName 'fallback') 'power_shell' 'Project title was not derived from its directory'
    Assert-Equal (Get-ProjectDisplayName -ProfilePath 'C:\dev\project with spaces\' -FallbackName 'fallback') 'project with spaces' 'Project title did not handle spaces or a trailing separator'
    Assert-Equal (Get-ProjectDisplayName -ProfilePath 'C:\' -FallbackName 'Fallback Project') 'Fallback Project' 'Project title did not fall back for a root path'
    $invalidGuidFailed = $false
    try { [void](Get-ProjectWindowName -ProfileGuid 'not-a-guid') } catch { $invalidGuidFailed = $true }
    Assert-True $invalidGuidFailed 'Invalid project GUID was accepted'

    $originalConfigurationFunction = (Get-Item -LiteralPath Function:\Get-AgentNotificationConfiguration).ScriptBlock
    $script:CapturedProjectLaunch = $null
    function Get-AgentNotificationConfiguration {
        [pscustomobject]@{
            CodexProfile = $codexProfile
            ClaudeSettings = $claudeSettings
            CenterScript = ''
            Installer = ''
        }
    }
    function Get-Command {
        param([string]$Name)
        [pscustomobject]@{ Source = "C:\tools\$Name" }
    }
    function Start-Process {
        param([string]$FilePath, [object]$ArgumentList)
        $script:CapturedProjectLaunch = [pscustomobject]@{ FilePath = $FilePath; ArgumentList = "$ArgumentList" }
    }
    try {
        Start-ProjectWindow -ProfileName 'project with spaces (d C:\dev\project with spaces)' `
            -ProfileGuid '{4A5FF801-DEAD-BEEF-8123-0123456789AB}' -ProfilePath 'C:\dev\project with spaces'
        $titleMatches = [regex]::Matches($script:CapturedProjectLaunch.ArgumentList, '--title "project with spaces"').Count
        Assert-Equal $titleMatches 4 'Not every project pane received the project-only title'
        Assert-True ($script:CapturedProjectLaunch.ArgumentList -notmatch '--title "\d+ (Codex|Claude)"') 'Agent-number title still overrides the project title'
        $normalScripts = @(Get-EmbeddedPowerShellScripts -CommandLine $script:CapturedProjectLaunch.ArgumentList)
        Assert-Equal $normalScripts.Count 4 'Project launcher did not create four encoded pane commands'
        Assert-True ($normalScripts[0] -match 'AgentNotificationWindowGuard') 'Pane did not retain the shared project-window guard'
        Assert-True ($normalScripts[0] -match 'AgentNotifications\.Pane\.agent-project-[0-9a-f]+\.1') 'First pane did not receive a unique pane guard'
        Assert-True ($normalScripts[3] -match 'AgentNotifications\.Pane\.agent-project-[0-9a-f]+\.4') 'Fourth pane did not receive a unique pane guard'

        Start-ProjectWindow -ProfileName 'project with spaces (d C:\dev\project with spaces)' `
            -ProfileGuid '{4A5FF801-DEAD-BEEF-8123-0123456789AB}' -ProfilePath 'C:\dev\project with spaces' `
            -ResumeSource Codex -ResumePane 2 -ResumeSessionId 'codex-session-id'
        $codexResumeScripts = @(Get-EmbeddedPowerShellScripts -CommandLine $script:CapturedProjectLaunch.ArgumentList)
        Assert-True ($codexResumeScripts[1] -match "'--profile' 'agent-notifications' 'resume' 'codex-session-id'") 'Codex resume command was not placed in its original pane'
        Assert-True ($codexResumeScripts[0] -notmatch "'resume' 'codex-session-id'") 'Codex resume command leaked into another pane'
        Assert-True ($script:CapturedProjectLaunch.ArgumentList -match 'mf first ; mf nextInOrder$') 'Rebuilt project did not focus resumed pane 2'

        Start-ProjectWindow -ProfileName 'project with spaces (d C:\dev\project with spaces)' `
            -ProfileGuid '{4A5FF801-DEAD-BEEF-8123-0123456789AB}' -ProfilePath 'C:\dev\project with spaces' `
            -ResumeSource Claude -ResumePane 4 -ResumeSessionId 'claude-session-id'
        $claudeResumeScripts = @(Get-EmbeddedPowerShellScripts -CommandLine $script:CapturedProjectLaunch.ArgumentList)
        Assert-True ($claudeResumeScripts[3] -match "'--settings' '[^']+' '--resume' 'claude-session-id'") 'Claude resume command was not placed in its original pane'
        Assert-True ($claudeResumeScripts[2] -notmatch "'--resume' 'claude-session-id'") 'Claude resume command leaked into another pane'
        Assert-True (([regex]::Matches($script:CapturedProjectLaunch.ArgumentList, 'mf nextInOrder')).Count -eq 3) 'Rebuilt project did not focus resumed pane 4'
    } finally {
        Set-Item -LiteralPath Function:\Get-AgentNotificationConfiguration -Value $originalConfigurationFunction
        Remove-Item -LiteralPath Function:\Get-Command
        Remove-Item -LiteralPath Function:\Start-Process
    }

    $focusGuardName = 'Local\AgentNotifications.Project.' + $projectWindow
    $focusGuard = New-Object System.Threading.Mutex($false, $focusGuardName)
    $script:CapturedStartProcess = $null
    function Start-Process {
        param([string]$FilePath, [object]$ArgumentList)
        $script:CapturedStartProcess = [pscustomobject]@{ FilePath = $FilePath; ArgumentList = "$ArgumentList" }
    }
    try {
        Start-ProjectWindow -ProfileName 'Existing project' -ProfileGuid $projectGuid -ProfilePath 'C:\dev\existing-project'
        Assert-Equal $script:CapturedStartProcess.FilePath 'wt.exe' 'Existing project did not target Windows Terminal'
        Assert-Equal $script:CapturedStartProcess.ArgumentList "-w $projectWindow focus-tab -t 0" 'Existing project did not emit only the focus command'

        $paneGuardName = Get-AgentPaneGuardName -Window $projectWindow -Pane 2
        $paneGuard = New-Object System.Threading.Mutex($false, $paneGuardName)
        try {
            Start-ProjectWindow -ProfileName 'Existing project' -ProfileGuid $projectGuid -ProfilePath 'C:\dev\existing-project' `
                -ResumeSource Codex -ResumePane 2 -ResumeSessionId 'codex-session-id'
            Assert-Equal $script:CapturedStartProcess.ArgumentList `
                "-w $projectWindow focus-tab -t 0 ; move-focus first ; move-focus nextInOrder" `
                'Existing exact chat did not focus its original pane'
        } finally {
            $paneGuard.Dispose()
        }

        $missingPaneFailed = $false
        try {
            Start-ProjectWindow -ProfileName 'Existing project' -ProfileGuid $projectGuid -ProfilePath 'C:\dev\existing-project' `
                -ResumeSource Codex -ResumePane 2 -ResumeSessionId 'codex-session-id'
        } catch { $missingPaneFailed = $true }
        Assert-True $missingPaneFailed 'Missing original pane did not fail instead of focusing the wrong chat'
    } finally {
        Remove-Item -LiteralPath Function:\Start-Process
        $focusGuard.Dispose()
    }

    $oldEnabled = $env:AI_NOTIFY_ENABLED
    $oldSource = $env:AI_NOTIFY_SOURCE
    $oldProject = $env:AI_NOTIFY_PROJECT
    $oldPane = $env:AI_NOTIFY_PANE
    $oldWindow = $env:AI_NOTIFY_WINDOW
    $oldGuard = $env:AI_NOTIFY_GUARD
    try {
        $env:AI_NOTIFY_ENABLED = '1'
        $env:AI_NOTIFY_SOURCE = 'Codex'
        $env:AI_NOTIFY_PROJECT = 'receiver-test'
        $env:AI_NOTIFY_PANE = '1'
        $env:AI_NOTIFY_WINDOW = 'test-window'
        $env:AI_NOTIFY_GUARD = 'test-guard'
        $receiverPayload = '{"hook_event_name":"Stop","last_assistant_message":"Receiver test"}'
        $receiverOutput = $receiverPayload | & powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -File $receiverPath -StateRoot $stateRoot -NoToast
        Assert-Equal $receiverOutput '{}' 'Receiver did not emit a no-op JSON hook response'
        Assert-Equal @(Read-AgentNotificationEvents -StateRoot $stateRoot).Count 1 'Receiver did not append its event'
    } finally {
        $env:AI_NOTIFY_ENABLED = $oldEnabled
        $env:AI_NOTIFY_SOURCE = $oldSource
        $env:AI_NOTIFY_PROJECT = $oldProject
        $env:AI_NOTIFY_PANE = $oldPane
        $env:AI_NOTIFY_WINDOW = $oldWindow
        $env:AI_NOTIFY_GUARD = $oldGuard
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installerPath -Uninstall -CodexHome $codexHome -StateRoot $stateRoot | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $codexProfile)) 'Uninstall left the Codex profile behind'
    Assert-True (-not (Test-Path -LiteralPath $claudeSettings)) 'Uninstall left Claude settings behind'

    Write-Host "PASS: $script:Assertions assertions" -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
