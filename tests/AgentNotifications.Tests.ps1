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

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('agent-notifications-tests-' + [guid]::NewGuid().ToString('N'))
$stateRoot = Join-Path $testRoot 'state'
$codexHome = Join-Path $testRoot 'codex'

try {
    $metadata = @{
        Enabled = '1'; Source = 'Codex'; Project = 'sample-project'; Pane = '2'
        Window = 'agent-project-123'; Guard = 'Local\AgentNotifications.Project.123'
    }
    $approvalPayload = '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"description":"Run tests\r\nwith approval"}}' | ConvertFrom-Json
    $approval = ConvertTo-AgentNotificationEvent -InputObject $approvalPayload -Metadata $metadata
    Assert-Equal $approval.status 'approval' 'Codex permission status was not normalized'
    Assert-Equal $approval.message 'Run tests with approval' 'Approval preview was not sanitized'
    Assert-Equal $approval.pane 2 'Pane number was not retained'

    $claudePayload = '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting"}' | ConvertFrom-Json
    $metadata.Source = 'Claude'
    $inputEvent = ConvertTo-AgentNotificationEvent -InputObject $claudePayload -Metadata $metadata
    Assert-Equal $inputEvent.status 'input' 'Claude idle prompt was not normalized'

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
