# Claude Usage Tray

A Windows tray icon and a small always-on-top overlay that show how much of your Claude subscription limits you have left.

- **Tray icon:** a coloured circle showing the % left on your *tightest* limit. Green is more than 30% left, amber is 10–30%, red is under 10%, and grey means the data is stale or there was an error. Hover over it for every limit.
- **Overlay:** one bar per limit: the 5-hour session, weekly, and per-model weekly (such as "Weekly Fable"). Each bar shows % left and time until it resets. Drag the overlay to move it (its position is saved), and double-click it to refresh.
- **Right-click menu** (tray or overlay): Show overlay, Refresh now, Open claude.ai usage page, Start with Windows, Exit. Left-clicking the tray icon toggles the overlay.

## Switching accounts

There's no public profiles API. Claude Code keeps its login in two places: `~/.claude/.credentials.json` holds the tokens, and the `oauthAccount` block in `~/.claude.json` records which account and org you're signed in to. A **profile** is a snapshot of both, stored in `%APPDATA%\ClaudeUsageTray\profiles\`.

- The tray saves the signed-in account as a profile automatically and keeps its tokens fresh on every poll.
- **Tray → Account:** pick an account to switch to, sign in to another account (this opens a console running `claude auth login`), rename the current account, or open the profiles folder.
- **CLI:**
  ```
  claude-profile                  list (* = active)
  claude-profile use <name>       switch (name, email, or part of either)
  claude-profile login            sign in to another account; the current one is saved first
  claude-profile save [name]      save or refresh the current account
  claude-profile rename <name> <new name>
  claude-profile remove <name>
  ```

After switching, **restart any running Claude Code sessions**. A running session keeps the old login in memory and could write its refreshed tokens back over the switch. Before every switch, the previous `~/.claude.json` is kept as `~/.claude.json.switcher-backup`.

Profile folders contain live login tokens, so treat them like `~/.claude` itself: don't sync or share them.

## Run

Double-click `start-usage-tray.vbs`, or:

```
powershell -NoProfile -STA -ExecutionPolicy Bypass -File ClaudeUsageTray.ps1
```

It needs only Windows PowerShell 5.1, which is built in. There are no other dependencies.

## How it works

It polls `https://api.anthropic.com/api/oauth/usage` every 2 minutes. This is the same data Claude Code's `/usage` shows. It authenticates with the OAuth token Claude Code keeps in `%USERPROFILE%\.claude\.credentials.json` and re-reads the token on every poll. If the token expires, the icon turns grey. Open Claude Code once to refresh the token.

Settings (overlay position, `IntervalSec`, `Opacity`) are stored in `%APPDATA%\ClaudeUsageTray\settings.json`. Errors are logged to `error.log` in the same folder.

Note: this endpoint is not a documented public API, so a future Claude Code release could change it.
