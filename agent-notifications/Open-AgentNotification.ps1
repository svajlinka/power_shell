param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [string]$StateRoot
)

$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'AgentNotifications.psm1') -Force -DisableNameChecking
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'powershell-profile.ps1')

    $eventId = ConvertFrom-AgentNotificationUri -Uri $Uri
    if ([string]::IsNullOrWhiteSpace($eventId)) { return }
    $event = Find-AgentNotificationEventById -EventId $eventId -StateRoot $StateRoot
    if ($null -eq $event) { return }
    [void](Open-AgentNotificationChat -Event $event -StateRoot $StateRoot)
} catch {
    # Toast activation must stay silent when an event is stale or cannot be routed.
}
