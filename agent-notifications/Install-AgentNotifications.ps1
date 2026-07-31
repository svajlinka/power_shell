[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Uninstall,
    [switch]$Force,
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'AgentNotifications')
)

$ErrorActionPreference = 'Stop'
$receiverPath = Join-Path $PSScriptRoot 'Receive-AgentNotification.ps1'
$codexProfilePath = Join-Path $CodexHome 'agent-notifications.config.toml'
$claudeSettingsPath = Join-Path $StateRoot 'claude-settings.json'
$marker = '# Managed by power_shell/agent-notifications.'

if ($Uninstall) {
    foreach ($path in @($codexProfilePath, $claudeSettingsPath)) {
        if (Test-Path -LiteralPath $path) {
            $owned = $path -eq $claudeSettingsPath -or (Get-Content -Raw -LiteralPath $path).StartsWith($marker)
            if ($owned -and $PSCmdlet.ShouldProcess($path, 'Remove agent notification configuration')) {
                Remove-Item -LiteralPath $path -Force
            }
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

Write-Host 'Agent notification launcher configuration installed.' -ForegroundColor Green
Write-Host "Codex profile:   $codexProfilePath"
Write-Host "Claude settings: $claudeSettingsPath"
Write-Host 'On the first Codex launch, open /hooks and trust the two profile hooks.' -ForegroundColor Yellow
