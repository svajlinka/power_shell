$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$profilePath = Join-Path $repoRoot 'powershell-profile.ps1'
$modulePath = Join-Path $repoRoot 'agent-notifications\AgentNotifications.psm1'
$receiverPath = Join-Path $repoRoot 'agent-notifications\Receive-AgentNotification.ps1'
$centerPath = Join-Path $repoRoot 'agent-notifications\Show-AgentNotificationCenter.ps1'
$installerPath = Join-Path $repoRoot 'agent-notifications\Install-AgentNotifications.ps1'
$handlerPath = Join-Path $repoRoot 'agent-notifications\Open-AgentNotification.ps1'
Import-Module $modulePath -Force -DisableNameChecking
. $profilePath

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
$codexSessions = Join-Path $testRoot 'sessions'
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
    $inputPayload = '{"hook_event_name":"PreToolUse","session_id":"codex-session","tool_name":"request_user_input","tool_input":{"questions":[{"question":"Choose the deployment target","options":[{"label":"Production"}]},{"question":"Confirm rollout"}]}}' | ConvertFrom-Json
    $inputEvent = ConvertTo-AgentNotificationEvent -InputObject $inputPayload -Metadata $metadata
    Assert-Equal $inputEvent.status 'input' 'Codex question status was not normalized'
    Assert-Equal $inputEvent.message 'Choose the deployment target' 'Codex question preview did not use the first question'
    Assert-Equal $inputEvent.sessionId 'codex-session' 'Codex question did not retain its session ID'
    $emptyInputPayload = '{"hook_event_name":"PreToolUse","tool_name":"request_user_input","tool_input":{"questions":[]}}' | ConvertFrom-Json
    Assert-Equal (ConvertTo-AgentNotificationEvent -InputObject $emptyInputPayload -Metadata $metadata).message `
        'Codex is waiting for your input' 'Codex question fallback message was not used'
    $unrelatedToolPayload = '{"hook_event_name":"PreToolUse","tool_name":"update_plan","tool_input":{}}' | ConvertFrom-Json
    Assert-True ($null -eq (ConvertTo-AgentNotificationEvent -InputObject $unrelatedToolPayload -Metadata $metadata)) `
        'Unrelated Codex tool call was converted to a notification'
    Assert-Equal (Get-AgentNotificationProjectName ([pscustomobject]@{ project = 'power_shell (d C:\Users\example\dev\power_shell)' })) 'power_shell' 'Project path was not removed from the compact name'
    $correctProjectName = 'T' + [char]0x00E5 + 'gd - Mob - PT27'
    $mojibakeProjectName = 'T' + [char]0x00C3 + [char]0x00A5 + 'gd - Mob - PT27'
    Assert-Equal (Get-AgentNotificationProjectName ([pscustomobject]@{ project = "$mojibakeProjectName (d C:\Users\example\project)" })) `
        $correctProjectName 'Legacy UTF-8 project-name mojibake was not repaired for display'
    Assert-Equal (Get-AgentNotificationProjectName ([pscustomobject]@{ project = "$correctProjectName (d C:\Users\example\project)" })) `
        $correctProjectName 'A correctly decoded project name was changed'
    $toastXml = New-AgentNotificationToastXml -Event $approval -ChatName 'Fix & verify <toast>'
    Assert-True ($toastXml -match '<toast duration="short">') 'Toast was not configured with short native duration'
    Assert-True ($toastXml -match '<text>sample-project - Codex</text>') 'Toast title was not compact project and source context'
    Assert-True ($toastXml -match '<text>Fix &amp; verify &lt;toast&gt;</text>') 'Toast chat name was not XML escaped'
    Assert-True ($toastXml -match ('arguments="agentnotify://open/' + $approval.id + '" activationType="protocol"')) 'Toast is missing its clickable protocol action'
    Assert-True ($toastXml -match 'ms-winsoundevent:Notification.Default') 'Toast sound was removed'
    Assert-True ($toastXml -notmatch 'pane|Run tests|C:\\') 'Toast leaked pane, message, or path details'
    Assert-Equal (ConvertFrom-AgentNotificationUri -Uri ("agentnotify://open/$($approval.id)")) $approval.id 'Valid toast URI did not return its event ID'
    Assert-True ($null -eq (ConvertFrom-AgentNotificationUri -Uri ("https://open/$($approval.id)"))) 'URI parser accepted the wrong scheme'
    Assert-True ($null -eq (ConvertFrom-AgentNotificationUri -Uri ("agentnotify://wrong/$($approval.id)"))) 'URI parser accepted the wrong host'
    Assert-True ($null -eq (ConvertFrom-AgentNotificationUri -Uri 'agentnotify://open/not-an-id')) 'URI parser accepted an invalid event ID'
    Assert-True ($null -eq (ConvertFrom-AgentNotificationUri -Uri ("agentnotify://open/$($approval.id)/"))) 'URI parser accepted a non-canonical path'

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
        '{"session_id":"history-session","text":"Later request"}',
        '{"session_id":"rollout-session","text":"Later request copied to global history"}'
    ) | Set-Content -LiteralPath $codexHistory -Encoding UTF8
    Assert-Equal (Get-AgentNotificationChatName -Event $approval -CodexSessionIndexPath $codexIndex `
        -CodexHistoryPath $codexHistory -ClaudeHistoryPath $claudeHistory) `
        'Earlier name' 'Codex chat name did not keep the earliest indexed title after a later title change'
    $historyEvent = [pscustomobject]@{ source = 'Codex'; sessionId = 'history-session' }
    Assert-Equal (Get-AgentNotificationChatName -Event $historyEvent `
        -CodexSessionIndexPath (Join-Path $testRoot 'missing-index.jsonl') `
        -CodexHistoryPath $codexHistory -ClaudeHistoryPath $claudeHistory) `
        'Första riktiga frågan' 'Unindexed Codex chat did not use its first meaningful history request'
    $rolloutDirectory = Join-Path $codexSessions '2026\08\01'
    [void](New-Item -ItemType Directory -Path $rolloutDirectory -Force)
    @(
        '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Injected workspace instructions"}]}}',
        '{not valid json}',
        '{"type":"event_msg","payload":{"type":"user_message","message":"tell me about this project like 10 bullets"}}',
        '{"type":"event_msg","payload":{"type":"user_message","message":"Later request"}}'
    ) | Set-Content -LiteralPath (Join-Path $rolloutDirectory 'rollout-2026-08-01T00-08-39-rollout-session.jsonl') -Encoding UTF8
    $rolloutEvent = [pscustomobject]@{ source = 'Codex'; sessionId = 'rollout-session' }
    Assert-Equal (Get-AgentNotificationChatName -Event $rolloutEvent `
        -CodexSessionIndexPath (Join-Path $testRoot 'missing-index.jsonl') `
        -CodexHistoryPath $codexHistory -CodexSessionsPath $codexSessions -ClaudeHistoryPath $claudeHistory) `
        'tell me about this project like 10 bullets' 'Codex chat did not prefer the first rollout prompt over a later global-history prompt'

    $chatNameCache = @{}
    $cachedApprovalName = Get-CachedAgentNotificationChatName -Event $approval -Cache $chatNameCache `
        -StateRoot $stateRoot -CodexSessionIndexPath $codexIndex -CodexHistoryPath $codexHistory `
        -CodexSessionsPath $codexSessions -ClaudeHistoryPath $claudeHistory
    Assert-Equal $cachedApprovalName 'Earlier name' 'Chat-name cache did not return the resolved name'
    Assert-Equal $chatNameCache.Count 1 'Chat-name cache did not retain the resolved chat'
    $chatNameCacheFile = Join-Path $stateRoot 'chat-names.jsonl'
    Assert-True (Test-Path -LiteralPath $chatNameCacheFile) 'Chat-name cache was not persisted'
    Add-Content -LiteralPath $chatNameCacheFile -Value '{not valid json}' -Encoding UTF8
    $reloadedChatNames = Read-AgentNotificationChatNameCache -StateRoot $stateRoot
    Assert-Equal $reloadedChatNames[(Get-AgentNotificationChatKey -Event $approval)] 'Earlier name' 'Persisted chat name was not restored'
    $cacheLinesBeforeHit = @(Get-Content -LiteralPath $chatNameCacheFile).Count
    $cachedWithoutSources = Get-CachedAgentNotificationChatName -Event $approval -Cache $reloadedChatNames `
        -StateRoot $stateRoot -CodexSessionIndexPath (Join-Path $testRoot 'missing-index.jsonl') `
        -CodexHistoryPath (Join-Path $testRoot 'missing-history.jsonl') `
        -CodexSessionsPath (Join-Path $testRoot 'missing-sessions') `
        -ClaudeHistoryPath (Join-Path $testRoot 'missing-claude-history.jsonl')
    Assert-Equal $cachedWithoutSources 'Earlier name' 'Persisted cache hit unnecessarily resolved the chat name again'
    Assert-Equal @(Get-Content -LiteralPath $chatNameCacheFile).Count $cacheLinesBeforeHit 'Cache hit appended a duplicate record'
    $cachedHistoryName = Get-CachedAgentNotificationChatName -Event $historyEvent -Cache $reloadedChatNames `
        -StateRoot $stateRoot -CodexSessionIndexPath (Join-Path $testRoot 'missing-index.jsonl') `
        -CodexHistoryPath $codexHistory -CodexSessionsPath $codexSessions -ClaudeHistoryPath $claudeHistory
    Assert-Equal $cachedHistoryName (Get-AgentNotificationChatName -Event $historyEvent `
        -CodexSessionIndexPath (Join-Path $testRoot 'missing-index.jsonl') `
        -CodexHistoryPath $codexHistory -CodexSessionsPath $codexSessions -ClaudeHistoryPath $claudeHistory) `
        'A cache miss did not resolve the new chat'
    Assert-Equal $reloadedChatNames.Count 2 'A cache miss did not add exactly one new chat'

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

    $manyEvents = @(1..120 | ForEach-Object { [pscustomobject]@{ id = "event-$_" } })
    $displayEvents = @(Get-AgentNotificationDisplayEvents -Events $manyEvents)
    Assert-Equal $displayEvents.Count 99 'Notification display was not limited to the latest 99 events'
    Assert-Equal $displayEvents[0].id 'event-22' 'Visible notifications did not start with the oldest retained event'
    Assert-Equal $displayEvents[98].id 'event-120' 'Latest notification was not placed at the bottom'
    $displayEntries = @(Get-AgentNotificationDisplayEntries -Events $manyEvents)
    Assert-Equal $displayEntries[0].number 99 'Top notification did not receive the oldest visible number'
    Assert-Equal $displayEntries[98].number 1 'Latest notification at the bottom was not numbered 1'
    Assert-Equal (Find-AgentNotificationDisplayEvent -Events $manyEvents -Number 1).id 'event-120' 'Selection 1 did not resolve to the latest notification'
    $latestChatKey = Get-AgentNotificationChatKey -Event $displayEntries[98].event
    Assert-Equal (Find-AgentNotificationDisplayIndex -Events $manyEvents -ChatKey $latestChatKey) 98 'Latest notification chat key did not resolve to its display index'
    Assert-Equal (Find-AgentNotificationDisplayIndex -Events $manyEvents -ChatKey 'missing') -1 'Unknown notification chat key resolved to a display index'

    $chatEvents = @(
        [pscustomobject]@{ id = 'a1'; source = 'Codex'; sessionId = 'session-a' },
        [pscustomobject]@{ id = 'b1'; source = 'Claude'; sessionId = 'session-b' },
        [pscustomobject]@{ id = 'a2'; source = 'Codex'; sessionId = 'session-a' },
        [pscustomobject]@{ id = 'c1'; source = 'Claude'; sessionId = 'session-a' },
        [pscustomobject]@{ id = 'a3'; source = 'Codex'; sessionId = 'session-a' }
    )
    $chatDisplay = @(Get-AgentNotificationDisplayEvents -Events $chatEvents)
    Assert-Equal $chatDisplay.Count 3 'Notification list did not collapse to one row per chat'
    Assert-Equal $chatDisplay[0].id 'b1' 'Superseded chat rows did not keep their original chronological position'
    Assert-Equal $chatDisplay[1].id 'c1' 'Chats sharing a session id across sources were merged'
    Assert-Equal $chatDisplay[2].id 'a3' 'Repeated chat did not keep only its latest notification'
    $chatEntries = @(Get-AgentNotificationDisplayEntries -Events $chatEvents)
    Assert-Equal $chatEntries[0].number 3 'Collapsed list did not number the oldest visible chat highest'
    Assert-Equal (Find-AgentNotificationDisplayEvent -Events $chatEvents -Number 1).id 'a3' 'Selection 1 did not resolve to the latest chat notification'

    $sessionlessEvents = @(
        [pscustomobject]@{ id = 't1'; source = 'Test'; sessionId = '' },
        [pscustomobject]@{ id = 't2'; source = 'Test'; sessionId = '' }
    )
    Assert-Equal (@(Get-AgentNotificationDisplayEvents -Events $sessionlessEvents)).Count 2 'Notifications without a session id were collapsed into one row'

    $busyEvents = @(1..120 | ForEach-Object {
        [pscustomobject]@{ id = "busy-$_"; source = 'Codex'; sessionId = "session-$($_ % 5)" }
    })
    $busyDisplay = @(Get-AgentNotificationDisplayEvents -Events $busyEvents)
    Assert-Equal $busyDisplay.Count 5 'Busy chats did not collapse to one row each'
    Assert-Equal $busyDisplay[4].id 'busy-120' 'Latest busy-chat notification was not placed at the bottom'

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
    Assert-Equal (Find-AgentNotificationEventById -EventId $approval.id -StateRoot $stateRoot).source 'Codex' 'Exact event lookup did not find the stored event'
    Assert-True ($null -eq (Find-AgentNotificationEventById -EventId ('f' * 32) -StateRoot $stateRoot)) 'Exact event lookup returned a different event'
    Assert-True (-not (Test-AgentNotificationHandled -Event $events[0])) 'Unread notification did not render as unhandled'
    Assert-True (Set-AgentNotificationHandled -EventId $approval.id -StateRoot $stateRoot) 'Handled notification was not updated'
    $events = @(Read-AgentNotificationEvents -StateRoot $stateRoot)
    Assert-True (Test-AgentNotificationHandled -Event $events[0]) 'Handled state did not persist after rereading the event log'
    Assert-Equal (Set-AllAgentNotificationsHandled -StateRoot $stateRoot) 1 'Done-all did not update every remaining unhandled notification'
    $events = @(Read-AgentNotificationEvents -StateRoot $stateRoot)
    Assert-True (Test-AgentNotificationHandled -Event $events[1]) 'Done-all handled state did not persist'
    Assert-Equal (Set-AllAgentNotificationsHandled -StateRoot $stateRoot) 0 'Done-all rewrote notifications that were already handled'
    Assert-True (-not (Test-AgentNotificationHandled -Event ([pscustomobject]@{ id = 'legacy' }))) 'Legacy notification without handled state was not treated as unhandled'

    Assert-True ($null -eq (ConvertFrom-AgentNotificationDoneCommand -Command '12')) 'A plain selection was parsed as a done command'
    Assert-True ($null -eq (ConvertFrom-AgentNotificationDoneCommand -Command 'c')) 'Clear was parsed as a done command'
    Assert-True ((ConvertFrom-AgentNotificationDoneCommand -Command 'd').all) 'Bare d no longer marks every notification handled'
    $doneOne = ConvertFrom-AgentNotificationDoneCommand -Command 'D12'
    Assert-True (-not $doneOne.all) 'd12 was treated as done-all'
    Assert-Equal ($doneOne.numbers -join ',') '12' 'd12 did not select a single notification'
    Assert-Equal ((ConvertFrom-AgentNotificationDoneCommand -Command 'd10 d12 d11').numbers -join ',') '10,12,11' 'Repeated d prefixes were not parsed as several notifications'
    Assert-Equal ((ConvertFrom-AgentNotificationDoneCommand -Command 'd10 12 11').numbers -join ',') '10,12,11' 'Space-separated numbers were not parsed as several notifications'
    Assert-Equal ((ConvertFrom-AgentNotificationDoneCommand -Command 'd7 d7').numbers -join ',') '7' 'A repeated number was not collapsed into one selection'
    $doneZero = ConvertFrom-AgentNotificationDoneCommand -Command 'd0'
    Assert-True (-not $doneZero.all) 'A numbered done command without a valid number fell back to done-all'
    Assert-Equal $doneZero.numbers.Count 0 'Notification number 0 was accepted'

    $doneRoot = Join-Path $testRoot 'done-state'
    foreach ($n in 1..3) {
        [void](Write-AgentNotificationEvent -StateRoot $doneRoot -Event ([pscustomobject]@{
            id = "done-$n"; source = 'Codex'; sessionId = "done-session-$n"; handled = $false
        }))
    }
    Assert-True (Set-AgentNotificationHandled -EventId @('done-1', 'done-3') -StateRoot $doneRoot) 'Marking several notifications handled did not match any event'
    $doneEvents = @(Read-AgentNotificationEvents -StateRoot $doneRoot)
    Assert-True (Test-AgentNotificationHandled -Event $doneEvents[0]) 'The first selected notification was not marked handled'
    Assert-True (-not (Test-AgentNotificationHandled -Event $doneEvents[1])) 'An unselected notification was marked handled'
    Assert-True (Test-AgentNotificationHandled -Event $doneEvents[2]) 'The second selected notification was not marked handled'
    Assert-True (-not (Set-AgentNotificationHandled -EventId @('missing-1') -StateRoot $doneRoot)) 'Marking an unknown notification handled reported a match'
    $compactLine = Format-AgentNotificationDisplayLine -Event $events[0] -Number 1 `
        -CodexSessionIndexPath $codexIndex -CodexHistoryPath $codexHistory -ClaudeHistoryPath $claudeHistory
    Assert-True ($compactLine -match '^\s*1\s+\d{2}:\d{2}:\d{2}\s+sample-project\s+Earlier name$') 'Compact notification row did not contain only number, time, project, and chat name'
    Assert-True ($compactLine -notmatch 'Codex|approval|pane|Run tests|C:\\') 'Compact notification row leaked hidden routing or message details'

    $centerSource = Get-Content -Raw -LiteralPath $centerPath
    Assert-True ($centerSource -match 'Write-Host \$key\.KeyChar -NoNewline') 'Typing a selection does not update the prompt directly'
    Assert-True ($centerSource -match 'Write-Host "`b `b" -NoNewline') 'Backspace does not update the prompt directly'
    Assert-True ($centerSource -notmatch '\$notice = "(?:Focused|Reopened)') 'Successful chat actions still emit status notices'
    Assert-True ($centerSource -match "---==\[ Agent Notifications \]==---") 'Notification pane is missing its cyan banner title'
    Assert-True ($centerSource -match 'Set-AllAgentNotificationsHandled') 'Notification pane is missing the done-all shortcut'
    Assert-True ($centerSource -match '\[ConsoleKey\]::UpArrow' -and $centerSource -match '\[ConsoleKey\]::DownArrow') 'Notification pane is missing arrow-key navigation'
    Assert-True ($centerSource -match 'Move-ListSelectionIndex') 'Notification pane does not wrap arrow-key selection through the shared helper'
    Assert-True ($centerSource -match 'Position Last') 'Notification selection does not initially target the latest row'
    Assert-True ($centerSource -match 'Up/Down = select') 'Notification help does not advertise arrow-key selection'
    Assert-True ($centerSource -match 'UpArrow[\s\S]+?DownArrow[\s\S]+?\$inputBuffer = ''''') 'Notification arrow navigation does not clear typed input'
    Assert-True ($centerSource -match 'IsNullOrEmpty\(\$inputBuffer\)[\s\S]+?\$displayEntries\[\$selectedNotificationIndex\]\.event') 'Blank notification Enter does not open the highlighted row'
    Assert-True ($centerSource -match 'function Update-CenterSelection[\s\S]+?\[char\]27[\s\S]+?\$escape\[s[\s\S]+?\$escape\[u') 'Notification selection does not use terminal-native in-place row updates'
    Assert-True ($centerSource -notmatch 'SetCursorPosition') 'Notification selection still uses the cursor API that appends duplicate rows in Windows Terminal'
    Assert-True ($centerSource -match 'Update-CenterSelection -Events \$events[\s\S]+?\$needsRender = \$true') 'Arrow navigation does not fall back to a full render when an in-place update is unavailable'
    Assert-True ($centerSource -match 'Get-AgentNotificationDisplayEntries[\s\S]+?Write-CenterEntry -Entry \$entry' -and `
        $centerSource -match 'Format-AgentNotificationDisplayLine -Event \$event -Number \$Entry\.number') `
        'Notification center does not render one collapsed row per chat'
    Assert-True ($centerSource -match 'Read-AgentNotificationChatNameCache') 'Notification center does not preload persisted chat names'
    Assert-True ($centerSource -match 'Get-CachedAgentNotificationChatName') 'Notification center does not reuse cached chat names'
    Assert-True ($centerSource -notmatch '\$key\.Key -eq \[ConsoleKey\]::[DCQ](?:\b|\W)') 'A letter command still executes before Enter'
    Assert-True ($centerSource -match 'ConvertFrom-AgentNotificationDoneCommand[\s\S]+?\$done\.all[\s\S]+?Set-AllAgentNotificationsHandled') 'Done-all is not dispatched by Enter'
    Assert-True ($centerSource -match 'Find-AgentNotificationDisplayEvent -Events \$events -Number \$number[\s\S]+?Set-AgentNotificationHandled -EventId') 'Numbered done commands do not mark their own notifications handled'
    Assert-True ($centerSource -match '\$typed -eq ''d'' -and') 'Typing d before a notification number is not accepted'
    Assert-True ($centerSource -match '\$typed -eq '' '' -and') 'Typing a space between notification numbers is not accepted'
    Assert-True ($centerSource -match '\$command -eq ''c''[\s\S]+?Clear-AgentNotificationEvents') 'Clear is not dispatched by Enter'
    Assert-True ($centerSource -match '\$command -eq ''q''\) \{ break \}') 'Close is not dispatched by Enter'
    $profileSource = Get-Content -Raw -LiteralPath $profilePath
    Assert-True ($profileSource -match "---==\[ Project Launcher \]==---") 'Project launcher is missing its matching cyan banner title'
    Assert-True ($profileSource -match 'Position Middle') 'Project launcher does not initially select its middle row'
    Assert-True ($profileSource -match '\[ConsoleKey\]::UpArrow' -and $profileSource -match '\[ConsoleKey\]::DownArrow') 'Project launcher is missing arrow-key navigation'
    Assert-True ($profileSource -match 'Up/Down = select') 'Project launcher help does not advertise arrow-key selection'
    Assert-True ($profileSource -match 'UpArrow[\s\S]+?DownArrow[\s\S]+?\$inputBuffer = ''''') 'Project arrow navigation does not clear typed input'
    Assert-True ($profileSource -match 'IsNullOrWhiteSpace\(\$inputBuffer\)[\s\S]+?\$answer = "\$\(\$selectedProjectIndex \+ 1\)"') 'Blank project Enter does not open the highlighted row'
    Assert-True ([regex]::Matches($profileSource, '\[IO\.File\]::ReadAllText\(\$settingsFile, \[Text\.Encoding\]::UTF8\)').Count -eq 2) `
        'Windows Terminal settings are not read as UTF-8 in both launcher and chat-reopen paths'
    Assert-True ($centerSource -match 'Open-AgentNotificationChat') 'Notification center does not use shared chat routing'
    $handlerSource = Get-Content -Raw -LiteralPath $handlerPath
    Assert-True ($handlerSource -match 'ConvertFrom-AgentNotificationUri') 'Toast activation handler does not validate its URI'
    Assert-True ($handlerSource -match 'Find-AgentNotificationEventById') 'Toast activation handler does not resolve the exact event'
    Assert-True ($handlerSource -match 'Open-AgentNotificationChat') 'Toast activation handler does not use shared chat routing'

    Clear-AgentNotificationEvents -StateRoot $stateRoot
    Assert-Equal @(Read-AgentNotificationEvents -StateRoot $stateRoot).Count 0 'Clear did not empty notification history'
    Assert-Equal (Read-AgentNotificationChatNameCache -StateRoot $stateRoot).Count 0 'Clear did not empty the chat-name cache'

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installerPath -CodexHome $codexHome -StateRoot $stateRoot -SkipProtocolRegistration | Out-Null
    $codexProfile = Join-Path $codexHome 'agent-notifications.config.toml'
    $claudeSettings = Join-Path $stateRoot 'claude-settings.json'
    Assert-True (Test-Path -LiteralPath $codexProfile) 'Installer did not create the Codex profile'
    Assert-True (Test-Path -LiteralPath $claudeSettings) 'Installer did not create Claude settings'
    $installedCodexProfile = Get-Content -Raw -LiteralPath $codexProfile
    Assert-True ($installedCodexProfile -match '\[\[hooks\.PreToolUse\]\]') 'Codex question hook is missing'
    Assert-True ($installedCodexProfile -match "matcher = '\^request_user_input\$'") 'Codex question hook matcher is missing or too broad'
    Assert-True ($installedCodexProfile -match '\[\[hooks\.PermissionRequest\]\]') 'Codex approval hook is missing'
    Assert-True ($installedCodexProfile -match '\[\[hooks\.Stop\]\]') 'Codex stop hook is missing'
    $parsedClaude = Get-Content -Raw -LiteralPath $claudeSettings | ConvertFrom-Json
    Assert-True ($null -ne $parsedClaude.hooks.Notification) 'Claude notification hook is missing'
    Assert-True ($null -ne $parsedClaude.hooks.Stop) 'Claude stop hook is missing'
    $installerSource = Get-Content -Raw -LiteralPath $installerPath
    Assert-True ($installerSource -match 'HKCU:\\Software\\Classes\\agentnotify') 'Installer does not register the user-scoped toast protocol'
    Assert-True ($installerSource -match 'AgentNotificationsOwner') 'Protocol registration is missing its ownership marker'
    Assert-True ($installerSource -match 'Open-AgentNotification\.ps1') 'Protocol registration does not invoke the activation handler'
    Assert-True ($installerSource -match 'registeredOwner -eq \$protocolOwner') 'Uninstall does not protect unowned protocol registrations'

    $freshControl = Get-AgentControlCenterArguments -LauncherRunning $false -NotificationsRunning $false
    Assert-Equal @($freshControl).Count 2 'Fresh control center does not create two windows'
    Assert-True ($freshControl[0] -match '^-w agent-notification-center new-tab --title Notifications') 'Fresh control center does not create the notification window first'
    Assert-True ($freshControl[1] -match '^-w agent-project-launcher new-tab --title Projects') 'Fresh control center does not create the project window last'
    Assert-True (($freshControl -join ' ') -notmatch '\bsp\b|split-pane|swap-pane') 'Fresh control center still contains pane-splitting commands'
    $existingControl = Get-AgentControlCenterArguments -LauncherRunning $true -NotificationsRunning $true
    Assert-Equal @($existingControl).Count 2 'Existing control center does not focus both windows'
    Assert-Equal $existingControl[0] '-w agent-notification-center focus-tab -t 0' 'Existing notification window is not focused first'
    Assert-Equal $existingControl[1] '-w agent-project-launcher focus-tab -t 0' 'Existing project window is not focused last'
    $missingNotifications = Get-AgentControlCenterArguments -LauncherRunning $true -NotificationsRunning $false
    Assert-True ($missingNotifications[0] -match 'agent-notification-center new-tab --title Notifications') 'Missing notification window is not restored'
    Assert-Equal $missingNotifications[1] '-w agent-project-launcher focus-tab -t 0' 'Restoring notifications does not reuse the project window'
    $missingLauncher = Get-AgentControlCenterArguments -LauncherRunning $false -NotificationsRunning $true
    Assert-Equal $missingLauncher[0] '-w agent-notification-center focus-tab -t 0' 'Restoring the launcher does not reuse the notification window'
    Assert-True ($missingLauncher[1] -match 'agent-project-launcher new-tab --title Projects') 'Missing project window is not restored'

    $projectGuid = '{1A5FF801-DEAD-BEEF-8123-0123456789AB}'
    $projectWindow = Get-ProjectWindowName -ProfileGuid $projectGuid
    Assert-Equal $projectWindow 'agent-project-1a5ff801deadbeef81230123456789ab' 'Project window identity is not stable and normalized'
    Assert-Equal (Get-ProjectWindowName -ProfileGuid $projectGuid) $projectWindow 'Repeated project identity generation changed the window name'
    $otherWindow = Get-ProjectWindowName -ProfileGuid '{2A5FF801-DEAD-BEEF-8123-0123456789AB}'
    Assert-True ($otherWindow -ne $projectWindow) 'Different project profiles received the same window name'
    Assert-Equal ((Get-UniqueProjectChoices -Answer '3 1,3 2 1') -join ',') '3,1,2' 'Repeated project choices were not deduplicated in input order'
    Assert-Equal (Get-InitialListSelectionIndex -Count 0 -Position Middle) -1 'Empty lists received a selectable row'
    Assert-Equal (Get-InitialListSelectionIndex -Count 9 -Position Middle) 4 'Odd project list did not select its middle row'
    Assert-Equal (Get-InitialListSelectionIndex -Count 10 -Position Middle) 4 'Even project list did not select its upper-middle row'
    Assert-Equal (Get-InitialListSelectionIndex -Count 10 -Position Last) 9 'Latest-row selection did not target the final display index'
    Assert-Equal (Move-ListSelectionIndex -Index 0 -Count 4 -Direction -1) 3 'Up did not wrap from the first row to the last'
    Assert-Equal (Move-ListSelectionIndex -Index 3 -Count 4 -Direction 1) 0 'Down did not wrap from the last row to the first'
    Assert-Equal (Move-ListSelectionIndex -Index -1 -Count 4 -Direction 1) 0 'Invalid selection did not recover at the first row'
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
        Assert-True ($normalScripts[0] -match "env:VISUAL = 'notepad\.exe'") 'First Codex pane did not configure Notepad as its prompt editor'
        Assert-True ($normalScripts[1] -match "env:VISUAL = 'notepad\.exe'") 'Second Codex pane did not configure Notepad as its prompt editor'
        Assert-True ($normalScripts[2] -notmatch 'env:VISUAL') 'Notepad prompt editor configuration leaked into the first Claude pane'
        Assert-True ($normalScripts[3] -notmatch 'env:VISUAL') 'Notepad prompt editor configuration leaked into the second Claude pane'

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

    $routingWindow = 'agent-project-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $routingEvent = [pscustomobject][ordered]@{
        id = [guid]::NewGuid().ToString('N'); timestamp = [DateTimeOffset]::Now.ToString('o')
        source = 'Codex'; status = 'finished'; project = 'routing-project'
        profileGuid = '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'; pane = 2
        window = $routingWindow; guard = "Local\AgentNotifications.Pane.$routingWindow.2"
        message = 'done'; sessionId = 'routing-session'; handled = $false
    }
    [void](Write-AgentNotificationEvent -Event $routingEvent -StateRoot $stateRoot)
    $routingPaneGuard = New-Object System.Threading.Mutex($false, $routingEvent.guard)
    $script:CapturedStartProcess = $null
    function Start-Process {
        param([string]$FilePath, [object]$ArgumentList)
        $script:CapturedStartProcess = [pscustomobject]@{ FilePath = $FilePath; ArgumentList = "$ArgumentList" }
    }
    try {
        $routingResult = Open-AgentNotificationChat -Event $routingEvent -StateRoot $stateRoot
        Assert-True $routingResult.Succeeded 'Shared chat routing did not focus an existing exact pane'
        Assert-True ($script:CapturedStartProcess.ArgumentList -match 'move-focus nextInOrder') 'Shared chat routing focused the wrong pane'
        Assert-True (Test-AgentNotificationHandled -Event (Find-AgentNotificationEventById -EventId $routingEvent.id -StateRoot $stateRoot)) 'Successful shared routing did not mark the event handled'
    } finally {
        Remove-Item -LiteralPath Function:\Start-Process
        $routingPaneGuard.Dispose()
    }

    $failedRoutingEvent = $routingEvent.PSObject.Copy()
    $failedRoutingEvent.id = [guid]::NewGuid().ToString('N')
    $failedRoutingEvent.guard = "Local\AgentNotifications.Pane.$routingWindow.3"
    $failedRoutingEvent.handled = $false
    [void](Write-AgentNotificationEvent -Event $failedRoutingEvent -StateRoot $stateRoot)
    $routingWindowGuard = New-Object System.Threading.Mutex($false, "Local\AgentNotifications.Project.$routingWindow")
    try {
        $failedRoutingResult = Open-AgentNotificationChat -Event $failedRoutingEvent -StateRoot $stateRoot
        Assert-True (-not $failedRoutingResult.Succeeded) 'Shared chat routing reported success for a missing original pane'
        Assert-True (-not (Test-AgentNotificationHandled -Event (Find-AgentNotificationEventById -EventId $failedRoutingEvent.id -StateRoot $stateRoot))) 'Failed shared routing marked the event handled'
    } finally {
        $routingWindowGuard.Dispose()
    }

    Clear-AgentNotificationEvents -StateRoot $stateRoot

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
        $receiverPayload = '{"hook_event_name":"PreToolUse","session_id":"receiver-session","tool_name":"request_user_input","tool_input":{"questions":[{"question":"Receiver input test"}]}}'
        $receiverOutput = $receiverPayload | & powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -File $receiverPath -StateRoot $stateRoot -NoToast
        Assert-Equal $receiverOutput '{}' 'Receiver did not emit a no-op JSON hook response'
        Assert-Equal @(Read-AgentNotificationEvents -StateRoot $stateRoot).Count 1 'Receiver did not append its event'
        $receiverEvent = @(Read-AgentNotificationEvents -StateRoot $stateRoot)[0]
        Assert-Equal $receiverEvent.status 'input' 'Receiver did not persist the Codex question as input'
        Assert-Equal $receiverEvent.message 'Receiver input test' 'Receiver did not persist the Codex question preview'
    } finally {
        $env:AI_NOTIFY_ENABLED = $oldEnabled
        $env:AI_NOTIFY_SOURCE = $oldSource
        $env:AI_NOTIFY_PROJECT = $oldProject
        $env:AI_NOTIFY_PANE = $oldPane
        $env:AI_NOTIFY_WINDOW = $oldWindow
        $env:AI_NOTIFY_GUARD = $oldGuard
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installerPath -Uninstall -CodexHome $codexHome -StateRoot $stateRoot -SkipProtocolRegistration | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $codexProfile)) 'Uninstall left the Codex profile behind'
    Assert-True (-not (Test-Path -LiteralPath $claudeSettings)) 'Uninstall left Claude settings behind'

    Write-Host "PASS: $script:Assertions assertions" -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
