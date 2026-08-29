param(
    [string]$Payload,
    [string]$StateRoot,
    [switch]$NoToast,
    [switch]$NoFocus
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'AgentNotifications.psm1'

try {
    Import-Module $modulePath -Force -DisableNameChecking
    if ([string]::IsNullOrWhiteSpace($Payload)) {
        $Payload = [Console]::In.ReadToEnd()
    }
    if (-not [string]::IsNullOrWhiteSpace($Payload)) {
        $inputObject = $Payload | ConvertFrom-Json
        $event = ConvertTo-AgentNotificationEvent -InputObject $inputObject
        if ($null -ne $event) {
            [void](Write-AgentNotificationEvent -Event $event -StateRoot $StateRoot)
            if (-not $NoFocus) {
                try { [void](Request-AgentNotificationCenterAttention -Event $event) } catch { }
            }
            if (-not $NoToast) {
                try { Show-AgentNotificationToast -Event $event } catch {
                    try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
                }
            }
        }
    }
} catch {
    # Notification failures must never affect the agent lifecycle.
}

# Both Codex and Claude treat an empty JSON object as a successful no-op hook result.
Write-Output '{}'
