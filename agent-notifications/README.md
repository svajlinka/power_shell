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
- Selecting an already-open project focuses its existing window instead of launching another one.
- Enter an event number in the right pane to focus its original chat.
- Press Enter with an empty selection to open notification `1`, the latest chat.
- Notifications are shown oldest-to-newest from top to bottom, with the latest event numbered `1` at the bottom.
- Each row contains only its number, time, short project name, and best available chat name.
- Each new event also shows a short native Windows toast with the project and chat name. Its **Open chat** button follows the same exact-chat routing as the inbox and marks the event handled after a successful open.
- Toasts keep the standard notification sound and expire quickly from the screen; Windows controls the precise display timing.
- Codex rows use the indexed chat title when available, otherwise the conversation's first meaningful request.
- Unhandled notifications are yellow. A notification turns blue after selecting it successfully focuses or resumes its chat.
- If that project window was closed, selecting a new event rebuilds the four-pane layout and resumes its exact Codex or Claude chat in the original pane.
- Older events without a saved session ID fall back to focusing or reopening the project.
- Type `d` and press Enter to mark every notification handled without deleting it.
- Typing or correcting a selection updates only the input prompt; the notification list is not redrawn until Enter is pressed or its data changes.
- Type `c` and press Enter to clear the notification history.
- Type `q` and press Enter in the notification pane to close it; the next `p` restores it.
- Close the Agent Control Center window normally to close both panes together.
- Run `Test-AgentNotification approval` or `Test-AgentNotification finished` to send a test event.

Events are stored in `%LOCALAPPDATA%\AgentNotifications\events.jsonl`. Only short previews and launcher routing metadata are retained; raw hook payloads and transcripts are not stored.

To remove the launcher-specific Codex and Claude configuration and the owned `agentnotify://` URL handler:

```powershell
Install-AgentNotifications -Uninstall
```
