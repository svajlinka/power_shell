# Agent Notifications

The `p` command opens or focuses two independent Windows Terminal windows: the project launcher and the notification inbox. Notifications are enabled only for Codex and Claude panes created by that launcher.

## First use

Run this once from a PowerShell session that has loaded `powershell-profile.ps1`:

```powershell
Install-AgentNotifications
```

On the first launcher-created Codex session, run `/hooks` and trust the `PreToolUse`, `PermissionRequest`, and `Stop` hooks from `agent-notifications.config.toml`.

## Control center

- Repeated `p` calls maximize and focus both existing windows instead of opening duplicates, with the Projects window focused last and ready for input. New Notifications, Projects, and four-pane AI chat windows also open maximized.
- Use Up/Down and Enter in the Projects window to launch the highlighted project; the initial highlight is the upper-middle alphabetical row and navigation wraps at either end.
- Entering one or more project numbers still launches those projects directly.
- Selecting an already-open project focuses its existing window instead of launching another one.
- Enter an event number in the Notifications window to focus its original chat.
- Press Enter with an empty selection to open notification `1`, the latest chat.
- Each chat occupies a single row that always shows its latest event. A new notification for the same chat replaces that chat's previous row instead of adding another one.
- Up to 99 chats are shown oldest-to-newest from top to bottom, with the most recently active chat numbered `1` at the bottom.
- Each row contains only its number, local date and time, short project name, and best available chat name.
- Each new event also shows a short native Windows toast with the project and chat name. Its **Open chat** button follows the same exact-chat routing as the inbox and marks the event handled after a successful open.
- Input prompts, approval requests, and finished turns bring the Notifications window to the foreground. If it was closed, the event recreates it maximized.
- Native Codex answer-choice questions are captured as input notifications before Codex waits for your selection.
- Toasts keep the standard notification sound and expire quickly from the screen; Windows controls the precise display timing.
- Codex rows keep the earliest indexed chat title when available, otherwise the conversation's first meaningful request from its rollout transcript or global history. Later prompts copied into global history do not rename existing rows.
- Unhandled notifications are yellow. A notification turns blue after selecting it successfully focuses or resumes its chat.
- If that project window was closed, selecting a new event rebuilds the four-pane layout and resumes its exact Codex or Claude chat in the original pane.
- Older events without a saved session ID fall back to focusing or reopening the project, and each keeps its own row because they cannot be matched to a chat.
- The event log keeps every notification, so the **Open chat** button on an older toast still works after its row has been replaced.
- Type `d` and press Enter to mark every notification handled without deleting it.
- Type `d` followed by an event number, such as `d12`, to mark only that notification handled. Several numbers can be combined as `d10 d12 d11` or `d10 12 11`; unknown numbers are reported and the valid ones are still marked.
- Typing or correcting a selection updates only the input prompt; the notification list is not redrawn until Enter is pressed or its data changes.
- Type `c` and press Enter to clear the notification history.
- Type `q` and press Enter in the Notifications window to close it; the next `p` restores it.
- Close either Projects or Notifications independently; the next `p` restores only the missing window and reuses the other one.
- Run `Test-AgentNotification input`, `Test-AgentNotification approval`, or `Test-AgentNotification finished` to send a test event.

Events are stored in `%LOCALAPPDATA%\AgentNotifications\events.jsonl`. Resolved short chat names are cached in `chat-names.jsonl` in the same folder so notification refreshes and later window launches do not repeatedly scan chat histories. The first launch after upgrading may take longer once while this cache is populated. The `c` command clears both files. Raw hook payloads and transcripts are not stored.

To remove the launcher-specific Codex and Claude configuration and the owned `agentnotify://` URL handler:

```powershell
Install-AgentNotifications -Uninstall
```
