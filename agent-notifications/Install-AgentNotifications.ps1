[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Uninstall,
    [switch]$Force,
    [switch]$SkipProtocolRegistration,
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'AgentNotifications')
)

$ErrorActionPreference = 'Stop'
$receiverPath = Join-Path $PSScriptRoot 'Receive-AgentNotification.ps1'
$codexProfilePath = Join-Path $CodexHome 'agent-notifications.config.toml'
$claudeSettingsPath = Join-Path $StateRoot 'claude-settings.json'
$marker = '# Managed by power_shell/agent-notifications.'
$protocolPath = 'HKCU:\Software\Classes\agentnotify'
$protocolOwnerName = 'AgentNotificationsOwner'
$protocolOwner = 'power_shell/agent-notifications'

if ($Uninstall) {
    foreach ($path in @($codexProfilePath, $claudeSettingsPath)) {
        if (Test-Path -LiteralPath $path) {
            $owned = $path -eq $claudeSettingsPath -or (Get-Content -Raw -LiteralPath $path).StartsWith($marker)
            if ($owned -and $PSCmdlet.ShouldProcess($path, 'Remove agent notification configuration')) {
                Remove-Item -LiteralPath $path -Force
            }
        }
    }
    if (-not $SkipProtocolRegistration -and (Test-Path -LiteralPath $protocolPath)) {
        $registeredOwner = (Get-Item -LiteralPath $protocolPath).GetValue($protocolOwnerName, '')
        if ($registeredOwner -eq $protocolOwner -and
            $PSCmdlet.ShouldProcess($protocolPath, 'Remove agent notification URL protocol')) {
            Remove-Item -LiteralPath $protocolPath -Recurse -Force
        }
    }
    Write-Host 'Agent notification launcher configuration removed.' -ForegroundColor Green
    return
}

foreach ($directory in @($CodexHome, $StateRoot)) {
    if (-not (Test-Path -LiteralPath $directory) -and $PSCmdlet.ShouldProcess($directory, 'Create directory')) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
}

$hookCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $receiverPath
$tomlCommand = $hookCommand.Replace("'", "''")
$codexProfile = @"
$marker

[[hooks.PreToolUse]]
matcher = '^request_user_input$'
[[hooks.PreToolUse.hooks]]
type = "command"
command = '$tomlCommand'
command_windows = '$tomlCommand'
timeout = 5

[[hooks.PermissionRequest]]
[[hooks.PermissionRequest.hooks]]
type = "command"
command = '$tomlCommand'
command_windows = '$tomlCommand'
timeout = 5

[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = '$tomlCommand'
command_windows = '$tomlCommand'
timeout = 5
"@

if ((Test-Path -LiteralPath $codexProfilePath) -and -not $Force) {
    $existing = Get-Content -Raw -LiteralPath $codexProfilePath
    if (-not $existing.StartsWith($marker)) {
        throw "Refusing to overwrite unowned file: $codexProfilePath. Use -Force to replace it."
    }
}
if ($PSCmdlet.ShouldProcess($codexProfilePath, 'Write Codex notification profile')) {
    Set-Content -LiteralPath $codexProfilePath -Value $codexProfile -Encoding UTF8
}

$handler = [ordered]@{
    type = 'command'
    command = $hookCommand
    timeout = 5
}
$claudeSettings = [ordered]@{
    hooks = [ordered]@{
        Notification = @(
            [ordered]@{
                matcher = 'permission_prompt|idle_prompt|elicitation_dialog'
                hooks = @($handler)
            }
        )
        Stop = @(
            [ordered]@{ hooks = @($handler) }
        )
    }
}
if ($PSCmdlet.ShouldProcess($claudeSettingsPath, 'Write Claude notification settings overlay')) {
    $claudeSettings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $claudeSettingsPath -Encoding UTF8
}

if (-not $SkipProtocolRegistration) {
    if (Test-Path -LiteralPath $protocolPath) {
        $registeredOwner = (Get-Item -LiteralPath $protocolPath).GetValue($protocolOwnerName, '')
        if ($registeredOwner -ne $protocolOwner -and -not $Force) {
            throw "Refusing to overwrite unowned URL protocol: $protocolPath. Use -Force to replace it."
        }
    }
    if ($PSCmdlet.ShouldProcess($protocolPath, 'Register agent notification URL protocol')) {
        $commandPath = Join-Path $protocolPath 'shell\open\command'
        [void](New-Item -Path $commandPath -Force)
        Set-Item -LiteralPath $protocolPath -Value 'URL:Agent Notification Protocol'
        Set-ItemProperty -LiteralPath $protocolPath -Name 'URL Protocol' -Value ''
        Set-ItemProperty -LiteralPath $protocolPath -Name $protocolOwnerName -Value $protocolOwner
        $handlerPath = Join-Path $PSScriptRoot 'Open-AgentNotification.ps1'
        $protocolCommand = '"powershell.exe" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Uri "%1" -StateRoot "{1}"' -f $handlerPath, $StateRoot
        Set-Item -LiteralPath $commandPath -Value $protocolCommand
    }
}

Write-Host 'Agent notification launcher configuration installed.' -ForegroundColor Green
Write-Host "Codex profile:   $codexProfilePath"
Write-Host "Claude settings: $claudeSettingsPath"
if (-not $SkipProtocolRegistration) { Write-Host 'Toast action:      agentnotify://open/<event-id>' }
Write-Host 'On the first Codex launch, open /hooks and trust the three profile hooks.' -ForegroundColor Yellow
