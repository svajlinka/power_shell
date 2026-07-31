# Agent Notifications

The `p` project launcher starts one notification-center window and enables notifications only for the Codex and Claude panes it creates.

## First use

Run this once from a PowerShell session that has loaded `powershell-profile.ps1`:

```powershell
Install-AgentNotifications
```

On the first launcher-created Codex session, run `/hooks` and trust the `PermissionRequest` and `Stop` hooks from `agent-notifications.config.toml`.

## Notification center

- Enter an event number to focus its project window.
- Press `c` with an empty selection to clear the history.
- Press `q` to close the center. Hooks continue logging events, and the center reopens the next time a project is launched.
- Run `Test-AgentNotification approval` or `Test-AgentNotification finished` to send a test event.

Events are stored in `%LOCALAPPDATA%\AgentNotifications\events.jsonl`. Only short previews and launcher routing metadata are retained; raw hook payloads and transcripts are not stored.

To remove the launcher-specific Codex and Claude configuration:

```powershell
Install-AgentNotifications -Uninstall
```
