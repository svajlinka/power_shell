$script:PowerShellToolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:AgentNotificationsRoot = Join-Path $script:PowerShellToolsRoot 'agent-notifications'

function Get-AgentNotificationConfiguration {
    [pscustomobject]@{
        CodexProfile   = Join-Path $env:USERPROFILE '.codex\agent-notifications.config.toml'
        ClaudeSettings = Join-Path $env:LOCALAPPDATA 'AgentNotifications\claude-settings.json'
        CenterScript   = Join-Path $script:AgentNotificationsRoot 'Show-AgentNotificationCenter.ps1'
        Installer      = Join-Path $script:AgentNotificationsRoot 'Install-AgentNotifications.ps1'
    }
}

function Install-AgentNotifications {
    param([switch]$Uninstall, [switch]$Force)

    $configuration = Get-AgentNotificationConfiguration
    $installerArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $configuration.Installer)
    if ($Uninstall) { $installerArguments += '-Uninstall' }
    if ($Force) { $installerArguments += '-Force' }
    & powershell.exe @installerArguments
}

function Test-NamedMutexExists {
    param([Parameter(Mandatory = $true)][string]$Name)

    try {
        $mutex = [System.Threading.Mutex]::OpenExisting($Name)
        $mutex.Dispose()
        return $true
    } catch {
        return $false
    }
}

function ConvertTo-EncodedPowerShellCommand {
    param([Parameter(Mandatory = $true)][string]$Script)

    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
}

function Get-AgentControlCenterArguments {
    param(
        [Parameter(Mandatory = $true)][bool]$LauncherRunning,
        [Parameter(Mandatory = $true)][bool]$NotificationsRunning
    )

    $configuration = Get-AgentNotificationConfiguration
    $profilePath = Join-Path $script:PowerShellToolsRoot 'powershell-profile.ps1'
    $launcherScript = ". '" + ($profilePath -replace "'", "''") + "'; Show-ProjectLauncher"
    $centerScript = "& '" + ($configuration.CenterScript -replace "'", "''") + "'"
    $launcherEncoded = ConvertTo-EncodedPowerShellCommand -Script $launcherScript
    $centerEncoded = ConvertTo-EncodedPowerShellCommand -Script $centerScript
    $launcherCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $launcherEncoded"
    $centerCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $centerEncoded"

    if ($LauncherRunning -and $NotificationsRunning) {
        return '-w agent-control-center focus-tab -t 0'
    }
    if ($LauncherRunning) {
        return "-w agent-control-center focus-tab -t 0 ; sp -V -s 0.5 --title Notifications $centerCommand ; mf first"
    }
    if ($NotificationsRunning) {
        return "-w agent-control-center focus-tab -t 0 ; sp -V -s 0.5 --title Projects $launcherCommand ; swap-pane left ; mf first"
    }
    return "-w agent-control-center new-tab --title Projects $launcherCommand ; sp -V -s 0.5 --title Notifications $centerCommand ; mf first"
}

function Start-AgentControlCenter {
    $launcherRunning = Test-NamedMutexExists -Name 'Local\AgentNotifications.ProjectLauncher'
    $notificationsRunning = Test-NamedMutexExists -Name 'Local\AgentNotifications.ControlCenter.Notifications'
    $terminalArguments = Get-AgentControlCenterArguments -LauncherRunning $launcherRunning -NotificationsRunning $notificationsRunning
    Start-Process wt.exe -ArgumentList $terminalArguments
    return $true
}

function New-AgentPaneEncodedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][int]$Pane,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$ProfileGuid,
        [Parameter(Mandatory = $true)][string]$Window,
        [Parameter(Mandatory = $true)][string]$WindowGuard,
        [Parameter(Mandatory = $true)][string]$Guard,
        [string[]]$Arguments = @()
    )

    $escaped = (@($Command, $Source, "$Pane", $Project, $ProfileGuid, $Window, $WindowGuard, $Guard) + $Arguments) | ForEach-Object {
        "'" + ("$_" -replace "'", "''") + "'"
    }
    $argumentText = if ($Arguments.Count -gt 0) { ' ' + ($escaped[8..($escaped.Count - 1)] -join ' ') } else { '' }
    $paneScript = @"
`$env:AI_NOTIFY_ENABLED = '1'
`$env:AI_NOTIFY_SOURCE = $($escaped[1])
`$env:AI_NOTIFY_PANE = $($escaped[2])
`$env:AI_NOTIFY_PROJECT = $($escaped[3])
`$env:AI_NOTIFY_PROFILE_GUID = $($escaped[4])
`$env:AI_NOTIFY_WINDOW = $($escaped[5])
`$env:AI_NOTIFY_GUARD = $($escaped[7])
`$global:AgentNotificationWindowGuard = New-Object System.Threading.Mutex(`$false, $($escaped[6]))
`$global:AgentNotificationPaneGuard = New-Object System.Threading.Mutex(`$false, $($escaped[7]))
& $($escaped[0])$argumentText
"@
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($paneScript))
}

function Get-ProjectWindowName {
    param([Parameter(Mandatory = $true)][string]$ProfileGuid)

    $normalizedGuid = $ProfileGuid.Trim().Trim('{', '}').Replace('-', '').ToLowerInvariant()
    if ($normalizedGuid -notmatch '^[0-9a-f]{32}$') {
        throw "Invalid Windows Terminal profile GUID: $ProfileGuid"
    }
    return "agent-project-$normalizedGuid"
}

function Get-AgentPaneGuardName {
    param(
        [Parameter(Mandatory = $true)][string]$Window,
        [Parameter(Mandatory = $true)][int]$Pane
    )

    if ($Pane -lt 1) { throw 'Pane number must be at least 1.' }
    return "Local\AgentNotifications.Pane.$Window.$Pane"
}

function Get-AgentPaneFocusArguments {
    param(
        [Parameter(Mandatory = $true)][string]$Window,
        [Parameter(Mandatory = $true)][int]$Pane
    )

    if ($Pane -lt 1) { throw 'Pane number must be at least 1.' }
    $parts = @("-w $Window focus-tab -t 0", 'move-focus first')
    for ($i = 1; $i -lt $Pane; $i++) { $parts += 'move-focus nextInOrder' }
    return ($parts -join ' ; ')
}

function Get-ProjectDisplayName {
    param(
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [Parameter(Mandatory = $true)][string]$FallbackName
    )

    try {
        $trimmedPath = $ProfilePath.Trim().TrimEnd([char[]]@('\', '/'))
        $directoryName = [IO.Path]::GetFileName($trimmedPath)
        if (-not [string]::IsNullOrWhiteSpace($directoryName)) {
            return $directoryName
        }
    } catch { }
    return $FallbackName
}

function Get-UniqueProjectChoices {
    param([AllowEmptyString()][string]$Answer)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    return @($Answer -split '[,\s]+' | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and $seen.Add($_)
    })
}

function Start-ProjectWindow {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [Parameter(Mandatory = $true)][string]$ProfileGuid,
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [string[]]$Commands = @('codex', 'codex', 'claude', 'claude'),  # left to right
        [ValidateSet('', 'Codex', 'Claude')][string]$ResumeSource = '',
        [int]$ResumePane = 0,
        [string]$ResumeSessionId = ''
    )

    $windowName = Get-ProjectWindowName -ProfileGuid $ProfileGuid
    $windowGuardName = 'Local\AgentNotifications.Project.' + $windowName
    $hasResume = -not [string]::IsNullOrWhiteSpace($ResumeSessionId)
    if ($hasResume) {
        if ([string]::IsNullOrWhiteSpace($ResumeSource) -or $ResumePane -lt 1 -or $ResumePane -gt $Commands.Count) {
            throw 'Exact chat resume requires a valid source and original pane number.'
        }
        $expectedSource = if ($Commands[$ResumePane - 1] -eq 'codex') { 'Codex' } else { 'Claude' }
        if ($ResumeSource -ne $expectedSource) {
            throw "The saved $ResumeSource chat does not match pane $ResumePane ($expectedSource)."
        }
    }
    if (Test-NamedMutexExists -Name $windowGuardName) {
        if ($hasResume) {
            $paneGuardName = Get-AgentPaneGuardName -Window $windowName -Pane $ResumePane
            if (-not (Test-NamedMutexExists -Name $paneGuardName)) {
                throw 'The project is open, but the original chat pane is no longer available.'
            }
            Start-Process wt.exe -ArgumentList (Get-AgentPaneFocusArguments -Window $windowName -Pane $ResumePane)
        } else {
            Start-Process wt.exe -ArgumentList "-w $windowName focus-tab -t 0"
        }
        return
    }

    $configuration = Get-AgentNotificationConfiguration
    if (-not (Test-Path -LiteralPath $configuration.CodexProfile) -or
        -not (Test-Path -LiteralPath $configuration.ClaudeSettings)) {
        Write-Warning 'Agent notifications are not installed. Run Install-AgentNotifications and retry.'
        return
    }

    $codexCommand = Get-Command codex.cmd -ErrorAction SilentlyContinue
    $claudeCommand = Get-Command claude.exe -ErrorAction SilentlyContinue
    if ($null -eq $codexCommand -or $null -eq $claudeCommand) {
        Write-Warning 'Cannot find codex.cmd and claude.exe on PATH.'
        return
    }

    $q     = '"{0}"' -f $ProfileName
    $projectTitle = Get-ProjectDisplayName -ProfilePath $ProfilePath -FallbackName $ProfileName
    $quotedTitle = '"{0}"' -f $projectTitle
    $parts = @()

    for ($i = 0; $i -lt $Commands.Count; $i++) {
        $source = if ($Commands[$i] -eq 'codex') { 'Codex' } else { 'Claude' }
        $commandPath = if ($source -eq 'Codex') { $codexCommand.Source } else { $claudeCommand.Source }
        $arguments = if ($source -eq 'Codex') {
            @('--profile', 'agent-notifications')
        } else {
            @('--settings', $configuration.ClaudeSettings)
        }
        if ($hasResume -and ($i + 1) -eq $ResumePane) {
            if ($source -eq 'Codex') {
                $arguments += @('resume', $ResumeSessionId)
            } else {
                $arguments += @('--resume', $ResumeSessionId)
            }
        }
        $paneGuardName = Get-AgentPaneGuardName -Window $windowName -Pane ($i + 1)
        $encoded = New-AgentPaneEncodedCommand -Command $commandPath -Source $source -Pane ($i + 1) `
            -Project $ProfileName -ProfileGuid $ProfileGuid -Window $windowName -WindowGuard $windowGuardName `
            -Guard $paneGuardName -Arguments $arguments
        $shell = "powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"

        if ($i -eq 0) {
            $parts += "-w $windowName new-tab --title $quotedTitle -p $q $shell"
            continue
        }

        # Each sp splits the focused pane, so the fraction must shrink to get equal columns.
        $share = ($Commands.Count - $i) / ($Commands.Count - $i + 1)
        $size  = $share.ToString('0.####', [cultureinfo]::InvariantCulture)
        $parts += "sp -V -s $size --title $quotedTitle -p $q $shell"
    }
    $parts += 'mf first'
    if ($hasResume) {
        for ($i = 1; $i -lt $ResumePane; $i++) { $parts += 'mf nextInOrder' }
    }

    Start-Process wt -ArgumentList ($parts -join ' ; ')
}

function Test-AgentNotification {
    param(
        [ValidateSet('approval', 'finished')]
        [string]$Type = 'finished'
    )

    $receiver = Join-Path $script:AgentNotificationsRoot 'Receive-AgentNotification.ps1'
    $oldValues = @{}
    foreach ($name in @('AI_NOTIFY_ENABLED', 'AI_NOTIFY_SOURCE', 'AI_NOTIFY_PANE', 'AI_NOTIFY_PROJECT', 'AI_NOTIFY_PROFILE_GUID', 'AI_NOTIFY_WINDOW', 'AI_NOTIFY_GUARD')) {
        $oldValues[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    try {
        $env:AI_NOTIFY_ENABLED = '1'
        $env:AI_NOTIFY_SOURCE = 'Test'
        $env:AI_NOTIFY_PANE = '0'
        $env:AI_NOTIFY_PROJECT = 'Notification smoke test'
        $env:AI_NOTIFY_PROFILE_GUID = ''
        $env:AI_NOTIFY_WINDOW = 'agent-control-center'
        $env:AI_NOTIFY_GUARD = 'Local\AgentNotifications.ControlCenter.Notifications'
        $payload = if ($Type -eq 'approval') {
            '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"description":"Test approval required"}}'
        } else {
            '{"hook_event_name":"Stop","last_assistant_message":"Test turn finished successfully"}'
        }
        $payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $receiver | Out-Null
        [void](Start-AgentControlCenter)
    } finally {
        foreach ($name in $oldValues.Keys) {
            [Environment]::SetEnvironmentVariable($name, $oldValues[$name], 'Process')
        }
    }
}

function Get-ProjectProfileName {
    param([string]$Path)

    $folderName = Split-Path $Path -Leaf
    return "$folderName (d $Path)"
}

function Show-ProjectLauncher {
    $created = $false
    $launcherMutex = New-Object System.Threading.Mutex($true, 'Local\AgentNotifications.ProjectLauncher', [ref]$created)
    if (-not $created) {
        $launcherMutex.Dispose()
        return
    }

    try {
    $settingsFile = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"

    if (-not (Test-Path $settingsFile)) {
        Write-Warning "Cannot find Windows Terminal's settings.json"
        return
    }

    while ($true) {
        $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json
        $profiles = $settings.profiles.list
        $allNames = @($profiles | ForEach-Object { $_.name })
        $list     = @($profiles | Where-Object { -not $_.hidden } | Sort-Object -Property name)

        Write-Host ""
        for ($i = 0; $i -lt $list.Count; $i++) {
            "{0,2}. {1}" -f ($i + 1), $list[$i].name
        }
        Write-Host "`n  a = add new   r = remove   q = quit" -ForegroundColor DarkGray

        $answer = Read-Host "`nChoice"

        if ([string]::IsNullOrWhiteSpace($answer)) { continue }
        if ($answer -eq 'q') { return }

        if ($answer -eq 'a') {
            $path = Read-Host "Path (Enter = browse)"

            if ([string]::IsNullOrWhiteSpace($path)) {
                Add-Type -AssemblyName System.Windows.Forms
                $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
                if ($dialog.ShowDialog() -ne 'OK') { continue }
                $path = $dialog.SelectedPath
            }

            $path = $path.Trim().Trim('"').TrimEnd('\')

            if (-not (Test-Path $path)) {
                Write-Warning "Path does not exist: $path"
                continue
            }

            $name = Get-ProjectProfileName -Path $path

            if ($allNames -contains $name) {
                Write-Warning "Profile '$name' already exists."
                continue
            }

            Write-Host ""
            Write-Host "  Name:   $name"
            Write-Host "  Folder: $path"
            $confirm = Read-Host "`nAdd? (y/n)"
            if ($confirm -ne 'y') {
                Write-Host "Cancelled." -ForegroundColor DarkGray
                continue
            }

            Copy-Item $settingsFile "$settingsFile.bak" -Force
            $newProfile = [PSCustomObject]@{
                name                     = $name
                commandline              = "powershell.exe -NoExit -Command claude"
                startingDirectory        = $path
                tabTitle                 = $name
                suppressApplicationTitle = $true
                guid                     = "{$([guid]::NewGuid())}"
            }
            $settings.profiles.list = @($newProfile) + $settings.profiles.list
            $settings | ConvertTo-Json -Depth 20 | Set-Content $settingsFile -Encoding UTF8
            Write-Host "Added '$name'." -ForegroundColor Green
            continue
        }

        if ($answer -eq 'r') {
            $removeAnswer = Read-Host "Numbers to remove (space or comma separated)"
            $choices = @($removeAnswer -split '[,\s]+' | Where-Object { $_ })

            if ($choices.Count -eq 0) {
                Write-Host "Cancelled." -ForegroundColor DarkGray
                continue
            }

            $invalidChoices = @($choices | Where-Object {
                $_ -notmatch '^\d+$' -or [int]$_ -lt 1 -or [int]$_ -gt $list.Count
            })
            if ($invalidChoices.Count -gt 0) {
                Write-Warning "Invalid: $($invalidChoices -join ', ')"
                continue
            }

            $selectedProfiles = @($choices |
                ForEach-Object { $list[[int]$_ - 1] } |
                Sort-Object -Property guid -Unique)

            $nonProjectProfiles = @($selectedProfiles | Where-Object {
                $_.commandline -ne 'powershell.exe -NoExit -Command claude' -or
                [string]::IsNullOrWhiteSpace($_.startingDirectory)
            })
            if ($nonProjectProfiles.Count -gt 0) {
                Write-Warning "Cannot remove non-project profile(s): $($nonProjectProfiles.name -join ', ')"
                continue
            }

            Write-Host ""
            $selectedProfiles | ForEach-Object { Write-Host "  $($_.name)" }
            $confirm = Read-Host "`nRemove these profiles? (y/n)"
            if ($confirm -ne 'y') {
                Write-Host "Cancelled." -ForegroundColor DarkGray
                continue
            }

            $selectedGuids = @($selectedProfiles | ForEach-Object { "$($_.guid)" })
            Copy-Item $settingsFile "$settingsFile.bak" -Force
            $settings.profiles.list = @($settings.profiles.list | Where-Object {
                $selectedGuids -notcontains "$($_.guid)"
            })
            $settings | ConvertTo-Json -Depth 20 | Set-Content $settingsFile -Encoding UTF8
            Write-Host "Removed $($selectedProfiles.Count) profile(s)." -ForegroundColor Green
            continue
        }

        foreach ($choice in (Get-UniqueProjectChoices -Answer $answer)) {
            if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $list.Count) {
                $profile = $list[[int]$choice - 1]
                Start-ProjectWindow -ProfileName $profile.name -ProfileGuid "$($profile.guid)" `
                    -ProfilePath $profile.startingDirectory
                Start-Sleep -Milliseconds 300
            } else {
                Write-Warning "Invalid: $choice"
            }
        }
    }
    } finally {
        $launcherMutex.ReleaseMutex()
        $launcherMutex.Dispose()
    }
}

function projects {
    [void](Start-AgentControlCenter)
}

Set-Alias p projects
