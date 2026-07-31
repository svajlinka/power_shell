# Agent Notifications

The `p` command opens or focuses one Agent Control Center window. Its left pane contains the project launcher and its right pane contains the notification inbox. Notifications are enabled only for Codex and Claude panes created by that launcher.

## First use

Run this once from a PowerShell session that has loaded `powershell-profile.ps1`:

```powershell
Install-AgentNotifications
```

On the first launcher-created Codex session, run `/hooks` and trust the `PermissionRequest` and `Stop` hooks from `agent-notifications.config.toml`.

## Control center

- Repeated `p` calls focus the existing control center instead of opening duplicates.
- Enter a project number in the left pane to launch its four-agent project window.
- Enter an event number in the right pane to focus its project window.
- Press `c` with an empty notification selection to clear the history.
- Press `q` in either pane to close that pane; the next `p` restores any missing pane.
- Close the Agent Control Center window normally to close both panes together.
- Run `Test-AgentNotification approval` or `Test-AgentNotification finished` to send a test event.

Events are stored in `%LOCALAPPDATA%\AgentNotifications\events.jsonl`. Only short previews and launcher routing metadata are retained; raw hook payloads and transcripts are not stored.

To remove the launcher-specific Codex and Claude configuration:

```powershell
Install-AgentNotifications -Uninstall
```
